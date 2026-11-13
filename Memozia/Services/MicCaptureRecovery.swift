import Foundation

/// 运行中的采集也要持续有写入。故障只触发一轮恢复，避免每秒重置 15 秒预算。
struct MicCaptureLiveness {
    static let timeout: Duration = .seconds(3)
    private(set) var lastWrite: ContinuousClock.Instant?
    private(set) var recoveryRequested = false

    mutating func wrote(at instant: ContinuousClock.Instant = .now) { lastWrite = instant }
    mutating func recoveryBegan() { recoveryRequested = true }
    mutating func recovered() { recoveryRequested = false }

    mutating func shouldRecover(engineRunning: Bool, recoveryActive: Bool,
                                now: ContinuousClock.Instant = .now) -> Bool {
        guard !recoveryActive, !recoveryRequested, let lastWrite,
              !engineRunning || lastWrite.duration(to: now) >= Self.timeout else { return false }
        recoveryRequested = true
        return true
    }
}

/// 设备切换后的启动与首包确认共用一个预算。只在主线程协调引擎操作，
/// 音频回调用 Attempt 值回传写入确认，不把 AVAudioEngine 带入回调。
@MainActor
final class MicCaptureRecovery {
    struct Attempt: Equatable, Sendable {
        let recoveryID: UUID
        let number: Int
    }

    private let backoff: [Duration]
    private let totalBudget: Duration
    private let packetTimeout: Duration
    private let attempt: (Attempt) -> Bool
    private let onStarted: (Int) -> Void
    private let onPacketTimeout: (Int) -> Void
    private let onFailed: (Int) -> Void
    private let onRecovered: () -> Void
    private let shouldRetry: () -> Bool
    private let onBudgetExhausted: (Int) -> Void
    private var task: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var recoveryID: UUID?
    private var activeAttempt: Attempt?
    private var attemptInvalidated = false
    private(set) var isConfirmed = false
    private(set) var isActive = false

    enum Failure: Error, Equatable { case exhausted, budgetExhausted }

    var maxAttempts: Int { backoff.count + 1 }

    init(
        backoff: [Duration] = [.milliseconds(200), .milliseconds(500), .seconds(1), .seconds(2)],
        totalBudget: Duration = .seconds(15),
        packetTimeout: Duration = .seconds(3),
        attempt: @escaping (Attempt) -> Bool,
        onStarted: @escaping (Int) -> Void,
        onPacketTimeout: @escaping (Int) -> Void,
        onFailed: @escaping (Int) -> Void,
        onRecovered: @escaping () -> Void,
        shouldRetry: @escaping () -> Bool = { true },
        onBudgetExhausted: @escaping (Int) -> Void = { _ in }
    ) {
        self.backoff = backoff
        self.totalBudget = totalBudget
        self.packetTimeout = packetTimeout
        self.attempt = attempt
        self.onStarted = onStarted
        self.onPacketTimeout = onPacketTimeout
        self.onFailed = onFailed
        self.onRecovered = onRecovered
        self.shouldRetry = shouldRetry
        self.onBudgetExhausted = onBudgetExhausted
    }

    /// 立即尝试一次，返回引擎是否启动；真正恢复仍由当前尝试的写入确认决定。
    @discardableResult
    func start() -> Bool {
        cancel()
        return startCycle(id: UUID())
    }

    /// 首次启动也沿用同一预算；先登记续体再启动，避免同步失败遗漏结算。
    /// 取消绑定本轮 ID，旧等待方的迟到取消不能终止下一轮恢复。
    func startAndWait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                cancel()
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                _ = startCycle(id: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.recoveryID == id else { return }
                self?.cancel()
            }
        }
    }

    private func startCycle(id: UUID) -> Bool {
        recoveryID = id
        isActive = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalBudget)
        let started = startAttempt(id: id, number: 1)
        guard recoveryID == id, isActive else { return started }
        task = Task { [weak self] in
            await self?.run(id: id, started: started, deadline: deadline)
        }
        return started
    }

    func cancel() {
        task?.cancel()
        task = nil
        recoveryID = nil
        activeAttempt = nil
        attemptInvalidated = false
        isConfirmed = false
        isActive = false
        let waiting = waiter
        waiter = nil
        waiting?.resume(throwing: CancellationError())
    }

    /// 最后一次首包超时后仍接受同一尝试的迟到写入，让真实恢复自动结算告警。
    /// 新通知、停止、重录或下一次尝试均使旧 token 无效。
    func confirmWrite(_ token: Attempt) {
        guard token == activeAttempt, recoveryID == token.recoveryID, !isConfirmed else { return }
        isConfirmed = true
        isActive = false
        task?.cancel()
        task = nil
        let waiting = waiter
        waiter = nil
        waiting?.resume()
        onRecovered()
    }

    /// 实际设备/格式变化使当前首包等待失效，但不取消启动续体、不重置总预算。
    /// 同一次尝试的重复通知合并；旧 tap 的迟到写入不能确认已失效的尝试。
    @discardableResult
    func invalidateAttempt() -> Bool {
        guard isActive, activeAttempt != nil else { return false }
        activeAttempt = nil
        attemptInvalidated = true
        return true
    }

    /// 写盘等不可重试错误也必须唤醒启动等待方。
    func fail() {
        guard isActive else { return }
        task?.cancel()
        activeAttempt = nil
        finishFailed(number: activeAttemptNumber)
    }

    private var activeAttemptNumber = 1

    private func finishFailed(number: Int, reason: Failure = .exhausted) {
        isActive = false
        task = nil
        let waiting = waiter
        waiter = nil
        waiting?.resume(throwing: reason)
        if case .budgetExhausted = reason { onBudgetExhausted(number) }
        onFailed(number)
    }

    private func startAttempt(id: UUID, number: Int) -> Bool {
        let token = Attempt(recoveryID: id, number: number)
        activeAttemptNumber = number
        attemptInvalidated = false
        activeAttempt = token // 在启动前布防，首包可能早于 engine.start() 返回。
        onStarted(number)
        let started = attempt(token)
        if !started { activeAttempt = nil }
        return started
    }

    private func run(id: UUID, started: Bool, deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        var started = started
        var number = 1
        while recoveryID == id, !Task.isCancelled, !isConfirmed {
            if !started, !shouldRetry() {
                finishFailed(number: number)
                return
            }
            if started, !attemptInvalidated {
                let fullPacketDeadline = clock.now.advanced(by: packetTimeout)
                let packetDeadline = min(fullPacketDeadline, deadline)
                // 写入确认取消此任务；短轮询不阻塞主线程，也不等待硬件回调返回。
                while clock.now < packetDeadline, !Task.isCancelled, !isConfirmed, !attemptInvalidated {
                    do { try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(20)), packetDeadline)) }
                    catch { return }
                }
                guard recoveryID == id, !Task.isCancelled, !isConfirmed else { return }
                if !attemptInvalidated {
                    // 只把完整的首包观察窗口记为首包超时；不能把几毫秒的剩余预算误报成无数据。
                    guard fullPacketDeadline <= deadline else {
                        finishFailed(number: number, reason: .budgetExhausted)
                        return
                    }
                    onPacketTimeout(number)
                }
            }
            guard number < maxAttempts else {
                finishFailed(number: number)
                return // 保留 activeAttempt，允许最终超时后迟到的真实写入解除告警。
            }
            let retryAt = clock.now.advanced(by: backoff[number - 1])
            // 下一次尝试至少预留首包观察窗口；准备硬件的同步调用也计入总预算。
            guard retryAt.advanced(by: packetTimeout) <= deadline else {
                finishFailed(number: number, reason: .budgetExhausted)
                return
            }
            do { try await clock.sleep(until: retryAt) }
            catch { return }
            guard recoveryID == id, !Task.isCancelled, !isConfirmed else { return }
            guard clock.now.advanced(by: packetTimeout) <= deadline else {
                finishFailed(number: number, reason: .budgetExhausted)
                return
            }
            number += 1
            started = startAttempt(id: id, number: number)
        }
    }
}
