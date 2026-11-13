import Foundation
import SwiftData
import Observation
import Darwin
import os.log

/// 启动阶段显式状态机（Sendable）。
///
/// 旧实现把「worker 握手 + 数据库独占锁 + 建可写容器」放在 `App` 结构体的属性初始化器里
/// 主线程同步执行：worker 拒不退出时最坏让应用数秒无窗口、无进度、不可取消（启动假死），
/// 且失败原因被压成一个 Bool + 一次性 alert（无重试）。
///
/// 现在把每一步都显式建模，界面据此展示进度、区分失败类别，并允许失败后重跑：
/// - `.starting`：进程已起来，尚未开始任何阻塞动作；
/// - `.waitingForWorker`：请求后台守护进程合作式停止并等它收尾（flush/checkpoint）；
/// - `.openingDatabase`：取数据库独占锁 → 建可写容器；
/// - `.ready`：已拿到可写容器，可切到主界面；
/// - `.transientReady`：用户二次确认后以临时（内存）模式继续，本次运行不落盘；
/// - `.databaseBusy`：未取得独占锁（区分「被后台进程占用」与「锁文件不可用」）；
/// - `.persistentStoreFailed`：持锁了但持久化容器创建失败。
enum StartupPhase: Sendable, Equatable {
    case starting
    case waitingForWorker
    case openingDatabase
    case ready(ModelContainer)
    case transientReady(ModelContainer)
    case databaseBusy(DatabaseBusyReason)
    case persistentStoreFailed(String)
}

extension StartupPhase {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 可写（落盘）容器：仅 `.ready` 提供
    var persistentContainer: ModelContainer? {
        if case .ready(let container) = self { return container }
        return nil
    }

    /// 临时（内存）容器：仅 `.transientReady` 提供
    var transientContainer: ModelContainer? {
        if case .transientReady(let container) = self { return container }
        return nil
    }

    var busyReason: DatabaseBusyReason? {
        if case .databaseBusy(let reason) = self { return reason }
        return nil
    }

    var failureDescription: String? {
        if case .persistentStoreFailed(let description) = self { return description }
        return nil
    }
}

/// 数据库不可用的原因：两类处置方式完全不同，不能共用模糊提示
enum DatabaseBusyReason: Sendable, Equatable {
    /// 独占锁被其他进程持有（通常是后台守护任务进程尚未让出数据库）
    case heldByOtherProcess(workerPID: pid_t?)
    /// 锁文件本身无法创建/打开：磁盘满、权限不足、存储目录不可写
    case lockFileUnavailable(errno: Int32)
}

/// 请求后台守护进程合作式停止的结果
enum WorkerStopOutcome: Sendable, Equatable {
    /// 没有存活的 worker
    case noWorker
    /// 宽限期内自行退出（完成 flush/checkpoint 后让位）
    case exitedDuringGrace
    /// 宽限期超时，收到 SIGTERM 后退出
    case exitedAfterTermination
    /// 宽限 + SIGTERM 之后仍未退出
    case stillRunning(pid: pid_t)

    var workerPID: pid_t? {
        if case .stillRunning(let pid) = self { return pid }
        return nil
    }
}

/// 尝试取得数据库独占锁的结果（`DatabaseOwnershipLock` 的 Sendable 快照）
enum LockAcquisition: Sendable, Equatable {
    case acquired
    case heldByOtherProcess
    case lockFileUnavailable(errno: Int32)
}

/// 启动协调器依赖：把「worker 握手」「取独占锁」「建容器」抽成可注入的闭包，
/// 便于在测试里构造任意失败/成功组合，而不触碰真实磁盘与真实 worker 进程。
struct StartupDependencies: Sendable {
    /// ① 检测/请求 worker 合作式停止 + ② 等待其 flush/checkpoint 并退出。
    /// 该调用会 sleep（阻塞），由协调器放到 `Task.detached` 执行，绝不占用主线程。
    var requestWorkerStop: @Sendable () -> WorkerStopOutcome
    /// ③ 取得 `DatabaseOwnershipLock`：**唯一**接管判据，不得绕过或放宽
    var acquireDatabaseLock: @Sendable () -> LockAcquisition
    /// ④ 创建可写（落盘）ModelContainer：只允许在确认持锁后调用
    var makePersistentContainer: @Sendable () throws -> ModelContainer
    /// 用户确认「以临时模式继续」时创建的内存容器（不落盘）
    var makeTransientContainer: @Sendable () -> ModelContainer
}

extension StartupDependencies {
    /// 生产实现：与旧启动路径同一套握手/锁/容器语义
    static func live() -> StartupDependencies {
        StartupDependencies(
            requestWorkerStop: {
                BackgroundWorker.requestWorkerStop(grace: 3, terminateWait: 2)
            },
            acquireDatabaseLock: {
                if DatabaseOwnershipLock.acquire(timeout: 1) { return .acquired }
                switch DatabaseOwnershipLock.lastFailureReason {
                case .lockFileUnavailable(let errno):
                    return .lockFileUnavailable(errno: errno)
                default:
                    return .heldByOtherProcess
                }
            },
            makePersistentContainer: {
                try StartupModelContainerFactory.makePersistent()
            },
            makeTransientContainer: {
                StartupModelContainerFactory.makeTransient()
            }
        )
    }
}

/// 启动用 ModelContainer 工厂（主应用侧唯一入口；worker 仍使用自己的容器工厂）
enum StartupModelContainerFactory {
    private static let logger = Logger(subsystem: "app.memozia", category: "AppInit")

    /// 与旧实现一致的 schema
    private static func makeSchema() -> Schema {
        Schema([
            AudioRecording.self,
            TranscriptSegment.self,
            LLMConfig.self,
            QuickNote.self,
        ])
    }

    /// 可写（落盘）容器。
    /// - Important: 只允许在 `DatabaseOwnershipLock` 已被本进程持有时调用；
    ///   未持锁打开可写容器会让两个进程同时写同一个 SQLite 文件而损坏数据库。
    static func makePersistent() throws -> ModelContainer {
        // 设置 HuggingFace 端点环境变量：必须在 HubApi 初始化之前执行
        WhisperModelSourceStore.applyCurrentAsHubEnvironment()
        let schema = makeSchema()
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 可写（落盘）容器，但落在**指定 URL**。
    /// - Important: 仅供 CLI 自检使用隔离目录，避免触碰用户数据库；生产路径仍走 `makePersistent()`。
    static func makePersistent(at url: URL) throws -> ModelContainer {
        let schema = makeSchema()
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// 临时（内存）容器：本次运行不落盘。
    /// 回退链：内存存储失败（极端情况，通常为进程资源耗尽）再退到空 schema 空容器；
    /// 连空容器都建不出来说明进程已无法分配内存，给出带原因的终止而非无上下文的 `try!` trap。
    static func makeTransient() -> ModelContainer {
        let schema = makeSchema()
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        } catch {
            logger.fault("内存 ModelContainer 创建失败，回退空容器: \(error.localizedDescription)")
            do {
                return try ModelContainer(
                    for: Schema([]),
                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("无法创建任何 ModelContainer（含空 schema 内存容器）：\(error.localizedDescription)")
            }
        }
    }
}

/// 启动协调器：把「启动决策」从 `MemoziaApp` 的属性初始化器搬到可观察的异步流程。
///
/// 顺序（与旧语义一致，只是不再阻塞主线程）：
/// 1. 请求后台守护进程合作式停止并等待它 flush/checkpoint 后退出（detached 执行）；
/// 2. 取得 `DatabaseOwnershipLock` —— **唯一**接管判据；
/// 3. 只有确认持锁才创建可写 ModelContainer；
/// 4. 切到主界面（由 `StartupRootView` 注入 `.modelContainer(_:)`）。
///
/// 未持锁时**绝不**创建可写容器，而是进入 `.databaseBusy` 并允许重试或（二次确认后）
/// 以临时模式继续。
@MainActor
@Observable
final class StartupCoordinator {

    private static let logger = Logger(subsystem: "app.memozia", category: "Startup")

    private(set) var phase: StartupPhase = .starting

    private let dependencies: StartupDependencies
    private var isRunning = false
    private var hasCompletedFirstAttempt = false

    init(dependencies: StartupDependencies) {
        self.dependencies = dependencies
    }

    /// 首次出现时启动一次；重复调用为空操作（重试请用 `retry()`）
    func bootstrapIfNeeded() async {
        guard !hasCompletedFirstAttempt else { return }
        await retry()
    }

    /// 重跑 bootstrap：成功即进入主界面（失败界面「重试」入口）
    func retry() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        hasCompletedFirstAttempt = true
        await run()
    }

    /// 用户二次确认后以临时（内存）模式继续：不落盘，界面需持续提示并禁用写操作
    func continueInTransientMode() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let deps = dependencies
        phase = .openingDatabase
        let container = await offMain { deps.makeTransientContainer() }
        Self.logger.notice("用户选择以临时模式继续，本次运行不落盘")
        phase = .transientReady(container)
    }

    private func run() async {
        let deps = dependencies
        phase = .starting
        phase = .waitingForWorker

        let stopOutcome = await offMain { deps.requestWorkerStop() }
        switch stopOutcome {
        case .noWorker:
            Self.logger.info("未检测到后台守护进程，直接进入接管判据")
        case .exitedDuringGrace:
            Self.logger.info("后台守护进程已在宽限内退出")
        case .exitedAfterTermination:
            Self.logger.notice("后台守护进程经 SIGTERM 退出，等待数据库锁释放")
        case .stillRunning(let pid):
            Self.logger.warning("后台守护进程 PID=\(pid) 在终止等待后仍未退出，继续以数据库独占锁为唯一判据")
        }

        phase = .openingDatabase
        let acquisition = await offMain { deps.acquireDatabaseLock() }
        switch acquisition {
        case .acquired:
            break
        case .heldByOtherProcess:
            // 未持锁绝不打开可写容器（两进程同写 SQLite 会损坏数据库）
            Self.logger.fault("未取得数据库独占锁（被其他进程持有），不打开可写容器")
            phase = .databaseBusy(.heldByOtherProcess(workerPID: stopOutcome.workerPID))
            return
        case .lockFileUnavailable(let errno):
            // 与"被占用"分开：真正原因是磁盘/权限，把用户引向活动监视器会误导
            Self.logger.fault("数据库锁文件不可用（errno=\(errno)），不打开可写容器")
            phase = .databaseBusy(.lockFileUnavailable(errno: errno))
            return
        }

        do {
            let container = try await offMainThrowing { try deps.makePersistentContainer() }
            Self.logger.info("已取得独占锁并打开可写容器，启动完成")
            phase = .ready(container)
        } catch is CancellationError {
            // 启动流程被取消（如窗口关闭）不是"持久化失败"：不得误导用户，
            // 并允许下次出现时重新跑一次 bootstrap
            Self.logger.notice("启动流程被取消，回到初始状态等待重跑")
            hasCompletedFirstAttempt = false
            phase = .starting
        } catch {
            Self.logger.fault("持久化容器创建失败：\(error.localizedDescription)")
            phase = .persistentStoreFailed(error.localizedDescription)
        }
    }

    /// 把阻塞调用放到脱离主线程的执行器，避免启动期主线程无窗口
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
