import Foundation
import os.log

/// 看门狗统一日志（超时/放弃等待必须可见，否则又变成“静默挂起”）
private let watchdogLogger = Logger(subsystem: "app.memozia", category: "Watchdog")

// MARK: - 一次性事件盒

/// 一次性事件盒：先交付者恢复等待方，后到者不覆盖结果、也绝不重复恢复。
///
/// 用于「多个异步来源竞争决定同一个等待方结果」的场景（如超时 vs 完成竞跑），
/// 避免 `withCheckedContinuation` 被 resume 两次造成 `EXC_BAD_INSTRUCTION`。
final class OneShotBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var delivered: Value?
    private var isDelivered = false

    /// 挂上等待方。返回非 nil 表示结果已被抢先交付，调用方须立即自行恢复。
    func attach(_ continuation: CheckedContinuation<Value, Never>) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        if isDelivered, let delivered {
            return delivered
        }
        self.continuation = continuation
        return nil
    }

    /// 交付结果：仅首个调用者成功并唤醒等待方，后到者不再覆盖胜出结果。
    /// - Returns: true 表示本次赢得竞跑。
    @discardableResult
    func deliver(_ value: Value) -> Bool {
        lock.lock()
        guard !isDelivered else {
            lock.unlock()
            return false
        }
        isDelivered = true
        delivered = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
        return true
    }
}

// MARK: - 可抛结果的一次性事件盒

/// 一次性「成功或抛出」事件盒：与 `OneShotBox` 同族，用于需要抛错的续体。
/// 多个交付点没有一次性保护时，第二次 `resume` 会直接 `EXC_BAD_INSTRUCTION`。
///
/// 典型场景：`VNImageRequestHandler.perform(_:)` 是同步调用，请求回调往往已在 `perform`
/// 内部跑完并恢复了续体，而 `perform` 自身随后又抛出 → 第二处 `resume` → 崩溃。
///
/// **为什么没有采用 `Result<Value, any Error>` 作为交付载荷**：`Result` 只有在
/// `Success & Failure` 都 `Sendable` 时才 `Sendable`，而 `Failure == any Error` 不满足，
/// `resume(with:)` 又要求 `sending` 结果 → Swift 6 直接报
/// "Sending 'result' risks causing data races"。因此这里把成功/失败分成两条路径，
/// **在交付点就地恢复**（值始终是交付方刚构造、不与其他隔离域共享的局部值），
/// 盒子里只保存 `CheckedContinuation` 本身（它本就是 `Sendable`）。
///
/// 用法约定：`attach` 必须先于任何可能结算的工作启动（各调用点都在创建续体后立刻挂上），
/// 所以不存在"结果早于登记"的竞态；万一违反，`attach` 会以 `precondition` 立即暴露，
/// 而不是留下一个永远无人恢复的续体。
final class OneShotThrowingBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var settled = false

    /// 挂上等待方（必须在启动会被等待的工作之前调用）
    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        precondition(!settled, "OneShotThrowingBox: 结算早于 attach，说明调用点未遵守「先挂续体再启动工作」")
        self.continuation = continuation
    }

    /// 以成功值结算：仅首个调用者会唤醒等待方。返回 `true` 表示本次是首个交付者。
    /// `value` 必须是交付方刚产出、未被其他隔离域共享的局部值（故标 `sending`）。
    @discardableResult
    func succeed(_ value: sending Value) -> Bool {
        lock.lock()
        guard !settled else { lock.unlock(); return false }
        settled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
        return true
    }

    /// 以错误结算：仅首个调用者会唤醒等待方。后到的交付返回 `false` 并自动让位。
    @discardableResult
    func fail(_ error: sending any Error) -> Bool {
        lock.lock()
        guard !settled else { lock.unlock(); return false }
        settled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(throwing: error)
        return true
    }
}

// MARK: - 跨边界错误包装

/// `any Error` 本身不是 `Sendable`，因此不能直接写进 `LockedBox`/盒子类
/// （Swift 6 会按"把非 Sendable 值送入共享并发域"判为数据竞争风险）。
/// 这里用**只读**的 `@unchecked Sendable` 包装完成跨任务交接：
/// 写入方与读出方不会同时触碰同一实例（读出仅发生在看门狗正常返回之后），
/// 且被包的 `Error` 实例（`AVError`/`NSError` 等）按约定不可变。
struct SentError: @unchecked Sendable {
    let value: any Error

    init(_ value: any Error) {
        self.value = value
    }
}

// MARK: - 跨隔离值盒

/// 锁保护的值盒：把「结果留在调用方自己的盒子里」这一既有模式泛化，
/// 使非 Sendable 的运算结果（导出错误、模型实例等）无需跨 Task 边界传递，
/// 只在同一个盒子内交接。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) {
        stored = initial
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - 可真正脱离的超时竞跑器

/// 超时竞跑器：`timeout` 到点即返回，**不等待**仍在挂起的操作。
///
/// 为什么不能继续用 `withThrowingTaskGroup`：结构化并发的 group 在离开作用域前
/// 必须 join 所有子任务。被等的恰恰是不响应协作取消的阻塞操作
/// （WhisperKit 初始化/CoreML 编译、挂起的 `AVAssetExportSession.export(to:as:)`），
/// 于是「超时抛错 → cancelAll → drain」这条路依然永久卡住，看门狗形同虚设。
///
/// 本实现的定时任务是普通 `Task.sleep`（必然结束、可取消），因此不存在收不了尾的子任务；
/// 挂起的操作被尽力取消后成为孤儿，其后续结果被忽略（由调用方的盒子/放弃标记兜住）。
enum RacingWatchdog {

    /// 操作超时（看门狗到点，已放弃等待）
    struct Expired: Error, CustomStringConvertible, Sendable {
        let name: String
        var description: String { "操作「\(name)」超时（看门狗到点，已放弃等待）" }
    }

    /// 竞跑一个「结果写进调用方自备盒子」的操作。
    /// - Parameters:
    ///   - name: 日志/错误中显示的操作名
    ///   - timeout: 最长等待秒数
    ///   - onTimeout: 超时回调（标记放弃、卸载孤儿资源等）
    ///   - onCancel: 调用方取消且取消赢得竞跑时的回调（同样用于标记孤儿资源）
    ///   - operation: 被等的操作；结果自行放进调用方持有的 `LockedBox` 等盒子
    /// - Returns: `true` = 操作在超时前结束；`false` = 超时**或调用方已被取消**
    ///   （调用方可用 `Task.isCancelled` 区分二者）
    static func race(
        name: String,
        timeout: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void = {},
        onCancel: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let box = OneShotBox<Bool>()
        let nanoseconds = UInt64(max(0.001, timeout) * 1_000_000_000)

        let worker = Task {
            await operation()
            box.deliver(true)
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            // 被外部取消（调用方已拿到结果）时不再判定超时
            guard !Task.isCancelled else { return }
            watchdogLogger.error("看门狗到点：「\(name, privacy: .public)」已超过 \(Int(timeout), privacy: .public)s 未完成，放弃等待孤儿任务")
            if box.deliver(false) {
                onTimeout()
            }
        }

        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if let early = box.attach(continuation) {
                    continuation.resume(returning: early)
                }
            }
        } onCancel: {
            // 调用方被取消：按「未完成」立即返回，并把取消转发给被等操作
            worker.cancel()
            timer.cancel()
            if box.deliver(false) {
                onCancel()
            }
        }

        if !finished {
            worker.cancel()
        }
        timer.cancel()
        return finished
    }
}

// MARK: - 跨隔离取消标记

/// 线程安全的取消标记：供跨隔离域共享「是否已请求取消」。
///
/// 典型场景：MainActor 上的服务（如停录收尾）响应用户按钮请求取消，而协作线程池里的
/// 长任务（分片内的流式滤波循环）需要以无隔离方式查询该标记。这里不能用
/// `Task.isCancelled`：被取消的收尾并非由结构化并发持有（取消信号来自用户/超时，
/// 而不是任务树），因此需要一个显式的、可跨隔离读取的标记。
///
/// 语义：只置位、不清除——一次取消对本次收尾始终有效，避免晚到的查询漏判。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - 可取消的异步串行门

/// 可取消的异步串行门：同一时刻只允许一路执行，后续调用排队等待。
///
/// 与被它替换的内联实现（`TranscribeGate` / `AsyncSerialGate`）的差别：
/// 1. 排队等待响应 Task 取消——旧版 `withCheckedContinuation` 不响应取消，
///    持锁者一旦永久挂起，所有排队者一起悬挂，且各自强引用 URL 与回调 → 泄漏；
/// 2. 取消与「执行权交接」竞态时，拿到门后立刻复查取消并让位，不会占着门不走；
/// 3. 单一实现供转写门/推理门/下载门复用，避免同类缺陷在各处重复演化。
actor CancellableGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isActive = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init() {}

    /// 当前是否在执行或有人排队（诊断用）
    var isBusy: Bool { isActive || !waiters.isEmpty }

    /// 获取执行权；成功返回后**必须**调用 `release()`
    func acquire() async throws {
        if !isActive {
            // 先查取消再占门：旧写法先 `isActive = true` 再 `checkCancellation()`，
            // 已取消的调用方会抛错退出但门 已被占下且无人 release → 整条队列永久锁死
            if Task.isCancelled { throw CancellationError() }
            isActive = true
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // 入队前已取消：直接失败，不留悬挂续体
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
        // 取消与执行权交接竞态：门已到手但调用方已被取消 → 立即让位
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// 释放执行权：有排队者则直接交接（保持 isActive），否则置空
    func release() {
        guard !waiters.isEmpty else {
            isActive = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume(returning: ())
        // isActive 保持 true：执行权已交接给下一个 waiter
    }

    /// 在门内执行一段逻辑（整段临界区使用）
    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        // defer 内不能 await：release 是同步方法，可直接交接
        defer { release() }
        return try await body()
    }

    /// 从队列中摘除已取消的等待者（找不到 = 已被交接或已自行恢复，无需处理）
    private func cancelWaiting(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
