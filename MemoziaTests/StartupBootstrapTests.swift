import Foundation
import SwiftData
import Testing
@testable import Memozia

/// 启动接管与数据库降级的决策覆盖。
///
/// 旧实现把「worker 握手 + 数据库独占锁 + 建可写容器」放在 `App` 属性初始化器里主线程同步执行，
/// 失败原因被压成一个 Bool，靠一次性 alert 提示且无法重试。本文件把新的 `StartupCoordinator`
/// 的不变式钉死：
/// 1. 三类失败（被后台进程占用 / 锁文件不可用 / 持久化容器创建失败）必须可区分；
/// 2. **未持锁绝不打开可写容器**（两进程同写 SQLite 会损坏数据库）；
/// 3. 失败后允许重试；临时（内存）模式必须显式触发。
@MainActor
struct StartupBootstrapTests {

    // MARK: - 测试替身

    /// 线程安全的调用记录：断言「停 worker → 取锁 → 建容器」的顺序与容器工厂是否被调用
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ entry: String) {
            lock.lock(); storage.append(entry); lock.unlock()
        }

        var entries: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func contains(_ entry: String) -> Bool { entries.contains(entry) }

        func count(of entry: String) -> Int { entries.filter { $0 == entry }.count }
    }

    /// 递增值盒子：用于「首次失败、重试成功」场景
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private struct DummyStoreError: LocalizedError {
        var errorDescription: String? { "磁盘已满，无法打开数据库" }
    }

    /// 内存容器即够用：本文件只验证协调器的决策与调用顺序，不触碰真实磁盘
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AudioRecording.self,
            TranscriptSegment.self,
            LLMConfig.self,
            QuickNote.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeDependencies(
        log: CallLog,
        container: ModelContainer,
        stop: @escaping @Sendable () -> WorkerStopOutcome,
        lockResult: @escaping @Sendable () -> LockAcquisition
    ) -> StartupDependencies {
        StartupDependencies(
            requestWorkerStop: { log.append("stop"); return stop() },
            acquireDatabaseLock: { log.append("lock"); return lockResult() },
            makePersistentContainer: { log.append("persistentContainer"); return container },
            makeTransientContainer: { log.append("transientContainer"); return container }
        )
    }

    // MARK: - 正常启动

    @Test("无 worker：按「停 worker → 取锁 → 建可写容器」顺序启动成功")
    func noWorkerStartsNormally() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .noWorker },
            lockResult: { .acquired }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.isReady)
        #expect(coordinator.phase.persistentContainer != nil)
        #expect(log.entries == ["stop", "lock", "persistentContainer"])

        // 启动只跑一次：重复调用不得再次执行握手/建容器
        await coordinator.bootstrapIfNeeded()
        #expect(log.entries == ["stop", "lock", "persistentContainer"])
    }

    @Test("worker 在宽限期内自行退出：仍以独占锁为判据并正常启动")
    func workerExitsQuickly() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .exitedDuringGrace },
            lockResult: { .acquired }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.isReady)
        #expect(log.entries == ["stop", "lock", "persistentContainer"])
    }

    @Test("worker 经 SIGTERM 后退出：正常启动")
    func workerExitsAfterTermination() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .exitedAfterTermination },
            lockResult: { .acquired }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.isReady)
        #expect(log.entries == ["stop", "lock", "persistentContainer"])
    }

    // MARK: - 未持锁绝不打开可写容器

    @Test("worker 超时仍未让出锁：进入 databaseBusy，且绝不打开可写容器")
    func workerTimeoutKeepsLockHeld() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .stillRunning(pid: 4242) },
            lockResult: { .heldByOtherProcess }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.busyReason == .heldByOtherProcess(workerPID: 4242))
        #expect(!coordinator.phase.isReady)
        #expect(!log.contains("persistentContainer"), "未持锁不得打开可写容器")
        #expect(!log.contains("transientContainer"), "未显式确认不得进入临时模式")
    }

    @Test("worker 已退出但锁仍被占用：进入 databaseBusy，且绝不打开可写容器")
    func workerGoneButLockStillHeld() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .noWorker },
            lockResult: { .heldByOtherProcess }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.busyReason == .heldByOtherProcess(workerPID: nil))
        #expect(!log.contains("persistentContainer"))
    }

    @Test("锁文件不可用（磁盘/权限）：与「被占用」分开，且绝不打开可写容器")
    func lockFileUnavailableIsDistinguished() async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .noWorker },
            lockResult: { .lockFileUnavailable(errno: 28) }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.busyReason == .lockFileUnavailable(errno: 28))
        #expect(coordinator.phase.busyReason != .heldByOtherProcess(workerPID: nil))
        #expect(!log.contains("persistentContainer"))
    }

    @Test(arguments: [LockAcquisition.heldByOtherProcess, LockAcquisition.lockFileUnavailable(errno: 1)])
    func writableContainerNeverOpensWithoutLock(acquisition: LockAcquisition) async throws {
        let log = CallLog()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: try makeContainer(),
            stop: { .noWorker },
            lockResult: { acquisition }
        ))

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.busyReason != nil)
        #expect(!coordinator.phase.isReady)
        #expect(log.count(of: "persistentContainer") == 0, "未持锁绝不打开可写容器")
    }

    // MARK: - 容器创建失败

    @Test("持锁后持久化容器创建失败：区分于锁失败，并带出错误描述")
    func persistentStoreFailureIsReported() async throws {
        let log = CallLog()
        let container = try makeContainer()
        let dependencies = StartupDependencies(
            requestWorkerStop: { log.append("stop"); return .noWorker },
            acquireDatabaseLock: { log.append("lock"); return .acquired },
            makePersistentContainer: { log.append("persistentContainer"); throw DummyStoreError() },
            makeTransientContainer: { log.append("transientContainer"); return container }
        )
        let coordinator = StartupCoordinator(dependencies: dependencies)

        await coordinator.bootstrapIfNeeded()

        #expect(coordinator.phase.failureDescription == "磁盘已满，无法打开数据库")
        #expect(coordinator.phase.busyReason == nil, "容器失败不得被误报为锁被占用")
        #expect(!coordinator.phase.isReady)
        // 确实是在持锁之后才尝试建容器
        #expect(log.entries == ["stop", "lock", "persistentContainer"])
    }

    // MARK: - 重试与临时模式

    @Test("重试：首次被占用失败，重试后成功进入主界面")
    func retrySucceedsAfterBusy() async throws {
        let log = CallLog()
        let container = try makeContainer()
        let attempts = AttemptCounter()
        let dependencies = StartupDependencies(
            requestWorkerStop: { log.append("stop"); return .noWorker },
            acquireDatabaseLock: {
                log.append("lock")
                return attempts.next() == 1 ? .heldByOtherProcess : .acquired
            },
            makePersistentContainer: { log.append("persistentContainer"); return container },
            makeTransientContainer: { log.append("transientContainer"); return container }
        )
        let coordinator = StartupCoordinator(dependencies: dependencies)

        await coordinator.bootstrapIfNeeded()
        #expect(coordinator.phase.busyReason == .heldByOtherProcess(workerPID: nil))
        #expect(!log.contains("persistentContainer"))

        await coordinator.retry()
        #expect(coordinator.phase.isReady)
        #expect(log.count(of: "persistentContainer") == 1, "只有重试成功那一次才打开可写容器")
    }

    @Test("临时模式：仅在显式调用后进入，且不打开可写容器")
    func transientModeRequiresExplicitCall() async throws {
        let log = CallLog()
        let container = try makeContainer()
        let coordinator = StartupCoordinator(dependencies: makeDependencies(
            log: log,
            container: container,
            stop: { .stillRunning(pid: 99) },
            lockResult: { .heldByOtherProcess }
        ))

        await coordinator.bootstrapIfNeeded()
        #expect(coordinator.phase.transientContainer == nil)

        await coordinator.continueInTransientMode()
        #expect(coordinator.phase.transientContainer != nil)
        #expect(coordinator.phase.persistentContainer == nil)
        #expect(!log.contains("persistentContainer"), "临时模式绝不打开可写容器")
        #expect(log.contains("transientContainer"))
    }
}
