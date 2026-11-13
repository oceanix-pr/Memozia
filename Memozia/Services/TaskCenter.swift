import Foundation
import Observation
import os.log

/// 便捷别名：`StepOutcome` 定义在 `TaskCenter` 内（调度器只认这三种结论），
/// 这里提供模块级别名，供 ViewModel / View 直接引用 `StepOutcome` 而不必逐处写 `TaskCenter.StepOutcome`。
typealias StepOutcome = TaskCenter.StepOutcome

// MARK: - 任务种类

/// 全局处理队列中的任务种类。
///
/// 不含录音 / 录屏：它们是实时会话（麦克风、系统音频、屏幕采集），必须立即开始，
/// 排进队列会错过采集时机，因此始终不进本队列。
enum TaskKind: String, Codable, Sendable, CaseIterable {
    case modelDownload
    case transcription
    case visualAnalysis
    case summary
    case title
    case todoExtraction

    /// 资源类：决定并发上限。
    /// 本地推理（转写/画面分析）与下载在物理上必须串行（单实例模型、CPU/显存、下载元数据），
    /// 网络 LLM 请求是 I/O 密集，可并行。
    enum ResourceClass: Sendable, Hashable { case inference, llm, download }

    var resourceClass: ResourceClass {
        switch self {
        case .transcription, .visualAnalysis: return .inference
        case .modelDownload: return .download
        case .summary, .title, .todoExtraction: return .llm
        }
    }

    var displayName: String {
        switch self {
        case .modelDownload:    return String(localized: "下载模型")
        case .transcription:    return String(localized: "转写")
        case .visualAnalysis:   return String(localized: "画面分析")
        case .summary:          return String(localized: "总结")
        case .title:            return String(localized: "润色标题")
        case .todoExtraction:   return String(localized: "拆解待办")
        }
    }

    /// 仅「下载」支持真正的暂停 / 续传（其余任务没有续传游标，暂停等价于取消）
    var canPause: Bool { self == .modelDownload }
}

// MARK: - 稳定错误码

/// 失败原因对应的修复入口。
///
/// 队列面板据此决定展示哪些按钮，而不是把任意 `localizedDescription` 当作最终文案；
/// 错误码 → 文案/入口的映射集中在这里与 `TaskErrorCode`，界面只做渲染。
enum TaskErrorRecovery: Equatable, Sendable {
    /// 打开应用内设置（通常是模型 / 大模型配置相关）
    case appSettings
    /// 打开系统设置的指定面板（权限类问题）
    case systemSettings(urlString: String)
    /// 在 Finder 中显示条目文件夹
    case revealInFinder
}

/// 步骤失败的**稳定错误码**（落库/展示均用它，不依赖本地化文案）。
///
/// 设计取舍：底层只保存这类稳定标识，界面再本地化成用户文案。
/// 旧实现没有失败原因，界面只能把 `error.localizedDescription`（可能是英文、
/// 也可能只是 "The operation couldn't be completed."）原样抛给用户。
enum TaskErrorCode: String, CaseIterable, Sendable {
    /// 本地模型缺失/未就绪（转写、说话人分离、画面分析等本地推理前置条件不满足）
    case missingLocalModel
    /// 输入文件缺失或无法读取（条目文件被移动/删除）
    case inputFileMissing
    /// 磁盘空间不足
    case insufficientDisk
    /// 缺少系统权限（语音识别等系统能力未授权）
    case permissionDenied
    /// 处理超时（看门狗判定执行体挂起）
    case timedOut
    /// 任务被取消
    case cancelled
    /// 其他未归类失败（含云端请求失败：鉴权、配额、网络等，统一引导去检查设置）
    case unknown

    /// 面向用户的失败摘要（本地化）
    var localizedSummary: String {
        switch self {
        case .missingLocalModel: return String(localized: "本地模型未就绪，请先在设置中下载或选择模型。")
        case .inputFileMissing:  return String(localized: "条目文件缺失或无法读取。")
        case .insufficientDisk:  return String(localized: "磁盘空间不足，请清理后重试。")
        case .permissionDenied:  return String(localized: "缺少系统权限，请在系统设置中授权后重试。")
        case .timedOut:          return String(localized: "处理超时，请重试。")
        case .cancelled:         return String(localized: "任务已取消。")
        case .unknown:           return String(localized: "处理失败，请重试；若反复失败请检查设置。")
        }
    }

    /// 是否值得重试。重试本身不会造成破坏（各步骤都是幂等重跑），
    /// 仅「已取消」不再提供重试入口。
    var isRetryable: Bool { self != .cancelled }

    /// 该错误码对应的修复入口（无则为 nil，界面不展示对应按钮）
    var recovery: TaskErrorRecovery? {
        switch self {
        case .missingLocalModel, .unknown: return .appSettings
        case .permissionDenied:
            return .systemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security")
        case .inputFileMissing: return .revealInFinder
        case .insufficientDisk, .timedOut, .cancelled: return nil
        }
    }
}

/// 把任意底层 `Error` 归类为面向用户的稳定文案。
///
/// 分类优先级：
/// 1. 系统网络 / POSIX / Cocoa 域：按已知 code 映射成具体文案（断网、磁盘不足、权限等）。
/// 2. 本应用自定义的 `LocalizedError`（如 `MeetingRecorderError` / `SystemAudioError` /
///    `VideoUnderstandingError`）：直接采用其已本地化的 `errorDescription`。这类错误的域
///    不是上面三种，若不特判会被兜底文案吞成一句无法排查的泛化提示（例如「清理视频」实际
///    因缺少可复用关键帧被拒，却显示成「检查模型配置与网络」）。
/// 3. 其余情况统一回退为 `TaskErrorCode.unknown` 的中性兜底文案。
///
/// 原始技术错误（`localizedDescription` 可能是英文、后端原文或技术性很强的内容）不主动拼进
/// 用户文案，仅写日志——但上面第 2 类是例外：其描述本身就是面向用户、已本地化的。
enum UserFacingError {

    /// 面向用户的本地化摘要（可直接填入错误提示）
    static func summary(for error: Error) -> String {
        if error is CancellationError { return TaskErrorCode.cancelled.localizedSummary }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch URLError.Code(rawValue: ns.code) {
            case .timedOut:
                return TaskErrorCode.timedOut.localizedSummary
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return String(localized: "服务鉴权失败，请在设置中检查 API Key 后重试。")
            default:
                return String(localized: "网络连接不可用或无法连接服务器，请检查网络后重试。")
            }
        case NSPOSIXErrorDomain:
            switch Int32(ns.code) {
            case ENOSPC:
                return TaskErrorCode.insufficientDisk.localizedSummary
            case EROFS:
                return String(localized: "目标磁盘为只读，请更换存储位置。")
            case EACCES, EPERM:
                return TaskErrorCode.permissionDenied.localizedSummary
            default:
                return TaskErrorCode.unknown.localizedSummary
            }
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileWriteOutOfSpaceError:
                return TaskErrorCode.insufficientDisk.localizedSummary
            case NSFileWriteVolumeReadOnlyError:
                return String(localized: "目标磁盘为只读，请更换存储位置。")
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return TaskErrorCode.inputFileMissing.localizedSummary
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return TaskErrorCode.permissionDenied.localizedSummary
            default:
                return TaskErrorCode.unknown.localizedSummary
            }
        default:
            // 本应用自定义的 LocalizedError（MeetingRecorderError / SystemAudioError /
            // VideoUnderstandingError 等）带有已本地化、面向用户的 errorDescription，
            // 直接采用，避免其具体原因被兜底文案抹平。
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return description
            }
            return TaskErrorCode.unknown.localizedSummary
        }
    }

    /// 原始技术错误文本：仅供日志或「详情」展示，不作为主提示
    static func technicalDetail(for error: Error) -> String {
        (error as NSError).localizedDescription
    }
}

/// 执行体未上报稳定错误码时的兜底归类。
///
/// 抽成纯函数是为了可离线回归：调用方给出「主输入是否存在」与「可用磁盘空间」，
/// 归类结果可确定预测；磁盘阈值与录音侧的「剩余 200MB 止损」同源，避免两处口径不一。
enum TaskFailureClassifier {

    /// 低于该可用空间即视为磁盘不足（与录音中磁盘保护阈值一致）
    static let lowDiskThresholdBytes: Int64 = 200 * 1024 * 1024

    /// - Parameters:
    ///   - primaryInputExists: 该步骤的主输入（音频 / 条目文件夹等）是否存在
    ///   - availableDiskBytes: 目标卷可用空间；nil 表示无法读取（不据此判定）
    static func classify(primaryInputExists: Bool, availableDiskBytes: Int64?) -> TaskErrorCode {
        if !primaryInputExists { return .inputFileMissing }
        if let availableDiskBytes, availableDiskBytes < lowDiskThresholdBytes { return .insufficientDisk }
        return .unknown
    }

    /// 读取指定路径所在卷的可用空间（失败返回 nil，不抛错）
    static func availableDiskBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// 步骤与调度器共享的失败信息盒。
///
/// 为什么用引用类型：`Step` 是值类型，执行体是闭包。执行体需要在失败时写下稳定错误码，
/// 而调度器在 `run()` 返回后要读到它。闭包与 `Step` 持有同一个实例即可打通，
/// 无需把 `StepOutcome` 改成带关联值的类型（那会波及全部 ViewModel 返回值与既有测试）。
///
/// 线程约定：只在 MainActor 上读写（步骤执行体与调度器都在 MainActor）。
final class StepFailure {
    /// 由执行体写入的稳定错误码；nil 表示未上报（调度器按 `.unknown` 兜底）
    var code: TaskErrorCode?
    init() {}
}

/// 线程安全的单次置位标记：跨隔离域观察「worker 是否已结束」。
/// 取消处理器是 `@Sendable`，不能用 MainActor 状态，故用锁保护的标记。
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 可等待的资源类门

/// 按资源类限流的可等待门（主线程串行求值，无需加锁）。
///
/// 与 `CancellableGate` 不同：那个门保护的是「同一时刻只允许一个底层推理实例」，
/// 这里保护的是「调度器层面同一资源类同时运行的步骤数」。两者叠加不冲突。
@MainActor
final class AsyncClassGate {
    private let limit: Int
    private var inUse = 0

    /// 等待者：带上 owner（Job id），以便取消时能把它从队列里摘掉
    private final class Waiter {
        let owner: UUID
        let continuation: CheckedContinuation<Bool, Never>
        init(owner: UUID, continuation: CheckedContinuation<Bool, Never>) {
            self.owner = owner
            self.continuation = continuation
        }
    }
    private var waiters: [Waiter] = []

    init(limit: Int) { self.limit = limit }

    /// 获取槽位。
    /// - Returns: true = 已占用槽位（调用方用完后必须 `release()`）；
    ///            false = 等待期间被取消，**未占用**槽位，调用方不得 `release()`
    func acquire(owner: UUID) async -> Bool {
        if inUse < limit {
            inUse += 1
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append(Waiter(owner: owner, continuation: continuation))
        }
    }

    /// 释放并**交接**槽位给下一个等待者（交接时 inUse 不变，避免「先减后加」之间被插队超发）
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            inUse -= 1
        }
    }

    /// 取消某个 owner 的排队：立即以 false 唤醒它，从等待队列摘除。
    /// 旧实现把取消的 Job 留在 waiters 里，直到别的 Job 释放槽位才被"交接"唤醒，
    /// 期间一直占着一个排队位（inference 限流为 1 时会形成幽灵任务链）。
    /// 该 owner 不在等待队列时为 no-op（例如它正在运行，或已不在本资源类排队）。
    func cancelWaiting(owner: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.owner == owner }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }
}

// MARK: - 任务中心

/// 全局处理队列（进程级单例）。
///
/// 职责：把应用内所有「可排队的处理任务」统一到一处调度与展示：
/// - 同时运行的 **Job 上限 3**，其余排队（用户要求）
/// - Job 内部按资源类再限流：本地推理 1、下载 1、网络 LLM 3
/// - Job 由若干**步骤**组成，按顺序执行；「一键处理」即「一个父 Job 内含转写/画面/总结/待办多个子步骤」
///   （不摊平成独立 Job，避免破坏「转写先备模型、总结后自动润色标题」这类既有依赖）
/// - 只做调度：每个步骤的执行体调用既有 ViewModel 方法，不重写业务逻辑
///
/// 不变量：
/// - 所有状态读写都在 MainActor；Job/Step 内的闭包捕获 VM，不跨 actor 传递
/// - 取消要传到 VM 内部任务（步骤自带 `cancel`，调用既有 `cancelXxx` 入口）
/// - 守护进程（独立进程、串行消费 `BackgroundTaskQueue`）不受本对象影响：
///   app 退到后台后任务语义仍由既有握手协议保证
@MainActor
@Observable
final class TaskCenter {

    static let shared = TaskCenter()

    // MARK: 状态类型

    enum JobState: Equatable, Sendable {
        case queued     // 排队中
        case running    // 处理中
        case paused     // 已暂停（仅下载）
        case failed     // 失败
        case done       // 已完成
        case cancelled  // 已取消
    }

    /// 单个步骤的执行结果。调度器只认这三种结论，且**只由执行体判定**。
    ///
    /// 为什么必须强类型：旧实现让步骤返回 `Bool`，而调用方（RootView）用
    /// 「总结非空 / 待办条数非零 / 生成时间戳非空 / 无条件 true」这类**旁证**反推成功。
    /// 这些字段可能来自上一次执行或磁盘残留，会把「本次什么都没产出」误报为成功，
    /// 于是失败的步骤被当成完成、后续依赖步骤继续执行。这里改由执行体显式给出结论。
    enum StepOutcome: Sendable, Equatable {
        /// 本次执行确实产出并已持久化
        case succeeded
        /// 被取消（用户取消 / Job 取消 / 宿主连带取消）
        case cancelled
        /// 失败或看门狗超时
        case failed
    }

    /// 单个可执行步骤。`run` 由调用方提供（内部通常「调用既有 VM 方法并 await 其 Task」），
    /// 直接给出 `StepOutcome`；`cancel` 调用既有的取消入口。
    struct Step: Identifiable {
        let id = UUID()
        let kind: TaskKind
        var state: JobState = .queued
        var progress: Double = 0
        var detail: String?
        /// 执行体：调度器传入**本次执行**的失败信息盒。
        ///
        /// 为什么要带参数：超时/取消后仍在运行的旧执行体（孤儿）持有的是**旧盒实例**，
        /// 而重试会把 `failure` 换成新实例——因此旧代次的写入天然落在旧盒上，
        /// 永远覆盖不了新代次（compare-and-swap 语义），不需要在闭包里手写代次判断。
        let run: @MainActor (StepFailure) async -> StepOutcome
        let cancel: @MainActor () -> Void
        /// 失败原因稳定码：仅在失败/超时时由调度器写入（执行体先写进 `failure`）
        var errorCode: TaskErrorCode? = nil
        /// 本步骤的结束时刻：供队列面板展示「失败时间」
        var finishedAt: Date? = nil
        /// 执行体与调度器共享的失败信息盒（见 `StepFailure`）
        var failure = StepFailure()
    }

    /// 一个父 Job（Job 名取「当前条目标题」）。多步骤按顺序执行。
    struct Job: Identifiable {
        let id = UUID()
        let folderName: String
        let title: String
        var steps: [Step]
        var state: JobState = .queued
        var currentStep: Int = 0
        let createdAt = Date()
        /// 守护进程是否可续跑（当前仅转写 / 总结有文件队列埋点）
        let isDurable: Bool
    }

    // MARK: 属性

    private(set) var jobs: [Job] = []

    /// 同时运行的 Job 上限（其余排队）
    static let maxConcurrentJobs = 3

    private let logger = Logger(subsystem: "app.memozia", category: "TaskCenter")

    private var runningJobIDs: Set<UUID> = []
    private var jobTasks: [UUID: Task<Void, Never>] = [:]

    private let inferenceGate = AsyncClassGate(limit: 1)
    private let downloadGate = AsyncClassGate(limit: 1)
    private let llmGate = AsyncClassGate(limit: 3)

    /// 步骤看门狗时长（按资源类）。可注入：默认实现供 `shared` 使用；
    /// 测试注入更短的超时即可确定性地验证「超时按失败处理」，无需真等十几分钟。
    private let stepTimeoutProvider: (TaskKind) -> TimeInterval

    /// 资源类「停止中」：该资源类有一个超时/取消后仍在运行的孤儿执行体，槽位未释放。
    /// 保留槽位是为了让重试只能排队等待，而不是与旧执行在同资源类上并发
    /// （本地推理的单实例前提不允许两次同时执行）。
    private(set) var stoppingResourceClasses: Set<TaskKind.ResourceClass> = []
    /// 需重启恢复的资源类：孤儿执行体超过宽限期仍未退出（底层不可取消且卡死）
    private(set) var restartRequiredResourceClasses: Set<TaskKind.ResourceClass> = []

    /// 孤儿宽限期：超过它就判定该资源类需重启恢复。可注入以便确定性测试。
    private let orphanGraceProvider: () -> TimeInterval

    /// 内部可注入初始化。`shared` 走默认看门狗时长；测试用独立实例避免污染全局单例状态。
    init(
        stepTimeoutProvider: @escaping (TaskKind) -> TimeInterval = TaskCenter.defaultStepTimeout,
        orphanGraceProvider: @escaping () -> TimeInterval = { 30 }
    ) {
        self.stepTimeoutProvider = stepTimeoutProvider
        self.orphanGraceProvider = orphanGraceProvider
    }

    // MARK: 对外查询

    var runningJobs: [Job] { jobs.filter { $0.state == .running || $0.state == .paused } }
    var queuedJobs: [Job] { jobs.filter { $0.state == .queued } }
    /// 失败任务：保留在队列中直到用户重试或清除，供面板提供「重试 / 打开设置 / 定位文件」
    var failedJobs: [Job] { jobs.filter { $0.state == .failed } }
    var hasActiveWork: Bool { jobs.contains { $0.state == .running || $0.state == .paused || $0.state == .queued } }

    /// 某资源类是否正在等孤儿执行体退出（槽位未释放）
    func isResourceClassStopping(_ cls: TaskKind.ResourceClass) -> Bool {
        stoppingResourceClasses.contains(cls)
    }

    /// 某资源类是否需要重启才能恢复（孤儿长时间未退出）
    func isRestartRequired(for cls: TaskKind.ResourceClass) -> Bool {
        restartRequiredResourceClasses.contains(cls)
    }

    /// 某条目是否已有 Job（用于列表 / 详情判断按钮是否可用）
    func hasJob(folderName: String) -> Bool {
        jobs.contains { $0.folderName == folderName && $0.state != .done && $0.state != .cancelled }
    }

    // MARK: 入队

    /// 入队一个 Job 并尝试调度。
    ///
    /// **入队去重**：若已存在「同 folderName 且步骤种类序列相同」的活动 Job
    /// （queued/running/paused），直接复用该 Job、不重复入队，返回其 id。
    /// 判据只看「目标文件夹 + 步骤种类顺序」这一组业务标识，不看标题/配置——
    /// 同一目标上的同一串处理不会有不同语义；重复入队只会造成并发重复写同一份
    /// 持久化产物（并互相取消对方句柄）。
    @discardableResult
    func enqueue(_ job: Job) -> UUID {
        let kinds = Self.stepKindSequence(job.steps)
        if let existing = jobs.first(where: {
            $0.folderName == job.folderName
                && ($0.state == .queued || $0.state == .running || $0.state == .paused)
                && Self.stepKindSequence($0.steps) == kinds
        }) {
            logger.info("任务去重：已存在同目标同步骤序列的活动 Job，复用而不重复入队（folder=\(job.folderName, privacy: .public)，步骤=\(kinds.map(\.rawValue).joined(separator: ","), privacy: .public)，state=\(String(describing: existing.state), privacy: .public)）")
            return existing.id
        }
        jobs.append(job)
        logger.info("任务入队：\(job.title, privacy: .public) 步骤=\(kinds.map(\.rawValue).joined(separator: ","), privacy: .public)")
        pump()
        return job.id
    }

    /// Job 的去重标识：步骤种类按顺序排列（顺序不同视为不同 Job，如「先总结再待办」与「先待办再总结」）
    private static func stepKindSequence(_ steps: [Step]) -> [TaskKind] { steps.map(\.kind) }

    /// 更新当前执行步骤的展示信息（进度 / 文案），由执行体回调
    func update(jobID: UUID, progress: Double? = nil, detail: String? = nil) {
        guard let jobIdx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let stepIdx = jobs[jobIdx].currentStep
        guard stepIdx < jobs[jobIdx].steps.count else { return }
        if let progress { jobs[jobIdx].steps[stepIdx].progress = progress }
        if let detail { jobs[jobIdx].steps[stepIdx].detail = detail }
    }

    // MARK: 取消 / 暂停 / 继续

    func cancel(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        logger.info("任务取消：\(self.jobs[idx].title, privacy: .public)")
        jobs[idx].state = .cancelled
        // 取消所有步骤的底层任务（含未开始的；既有 cancel 入口幂等，重复调用安全）
        for step in jobs[idx].steps { step.cancel() }
        jobTasks[jobID]?.cancel()
        jobTasks[jobID] = nil
        runningJobIDs.remove(jobID)
        jobs.remove(at: idx)
        cancelGateWaiters(owner: jobID)
        pump()
    }

    /// 摘除某个 Job 在任一资源类门闸上的排队：三个门闸只有正在排队的那个会命中
    private func cancelGateWaiters(owner: UUID) {
        inferenceGate.cancelWaiting(owner: owner)
        downloadGate.cancelWaiting(owner: owner)
        llmGate.cancelWaiting(owner: owner)
    }

    /// 暂停（仅下载可续传）：取消底层下载任务（保留分片），保留 Job 待继续
    func pause(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let stepIdx = jobs[idx].currentStep
        guard stepIdx < jobs[idx].steps.count, jobs[idx].steps[stepIdx].kind.canPause else { return }
        jobs[idx].steps[stepIdx].cancel()
        jobs[idx].steps[stepIdx].state = .paused
        jobs[idx].state = .paused
        jobTasks[jobID]?.cancel()
        jobTasks[jobID] = nil
        runningJobIDs.remove(jobID)
        cancelGateWaiters(owner: jobID)
        logger.info("任务暂停：\(self.jobs[idx].title, privacy: .public)")
        pump()
    }

    /// 继续被暂停的 Job（重新调度当前步骤；下载会从保留的分片续传）
    func resume(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), jobs[idx].state == .paused else { return }
        jobs[idx].state = .queued
        jobs[idx].steps[jobs[idx].currentStep].state = .queued
        pump()
    }

    // MARK: - 失败重试

    /// 失败步骤的索引（失败时 `currentStep` 停在失败步骤上；无法定位时返回 nil）
    func failedStepIndex(jobID: UUID) -> Int? {
        guard let job = jobs.first(where: { $0.id == jobID }), job.state == .failed else { return nil }
        let idx = job.currentStep
        guard idx < job.steps.count, job.steps[idx].state == .failed else { return nil }
        return idx
    }

    /// 重试失败的单个步骤：只清该步骤的失败态并重新排队，已完成的前置步骤不重跑。
    /// 不可重试（取消）的步骤直接忽略，避免用户点了没反应的静默失效。
    func retryStep(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].state == .failed,
              let stepIdx = failedStepIndex(jobID: jobID) else { return }
        guard jobs[idx].steps[stepIdx].errorCode?.isRetryable ?? true else { return }
        resetStep(at: stepIdx, inJobAt: idx)
        jobs[idx].state = .queued
        logger.info("重试失败步骤：\(self.jobs[idx].title, privacy: .public) 步骤=\(self.jobs[idx].steps[stepIdx].kind.rawValue, privacy: .public)")
        pump()
    }

    /// 重新执行整个任务：所有步骤回到排队态并从头开始
    func retryJob(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }), jobs[idx].state == .failed else { return }
        for stepIdx in jobs[idx].steps.indices {
            resetStep(at: stepIdx, inJobAt: idx)
        }
        jobs[idx].currentStep = 0
        jobs[idx].state = .queued
        logger.info("重新执行任务：\(self.jobs[idx].title, privacy: .public)")
        pump()
    }

    /// 把某一步骤恢复成「未执行」：清失败码、失败时间与进度
    private func resetStep(at stepIdx: Int, inJobAt jobIdx: Int) {
        jobs[jobIdx].steps[stepIdx].state = .queued
        jobs[jobIdx].steps[stepIdx].errorCode = nil
        jobs[jobIdx].steps[stepIdx].finishedAt = nil
        // 换上**新的**失败信息盒：迟到孤儿持有的是旧盒，其写入落在旧盒上，
        // 不会污染本次重试记录的失败原因（旧代次不得覆盖新代次）
        jobs[jobIdx].steps[stepIdx].failure = StepFailure()
        jobs[jobIdx].steps[stepIdx].progress = 0
        jobs[jobIdx].steps[stepIdx].detail = nil
    }

    /// 资源类进入「停止中」：插入标记并安排宽限期检查（仅首个进入者安排一次）
    private func markResourceClassStopping(_ cls: TaskKind.ResourceClass) {
        let inserted = stoppingResourceClasses.insert(cls).inserted
        if inserted { scheduleRestartGraceCheck(for: cls) }
    }

    /// 资源类恢复可用：清掉「停止中 / 需重启恢复」
    private func markResourceClassRunningAgain(_ cls: TaskKind.ResourceClass) {
        stoppingResourceClasses.remove(cls)
        restartRequiredResourceClasses.remove(cls)
    }

    /// 宽限期后孤儿仍未退出 → 标记该资源类需重启恢复
    private func scheduleRestartGraceCheck(for cls: TaskKind.ResourceClass) {
        let grace = orphanGraceProvider()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, self.stoppingResourceClasses.contains(cls) else { return }
            self.restartRequiredResourceClasses.insert(cls)
            self.logger.fault(
                "资源类「\(String(describing: cls), privacy: .public)」的孤儿执行体超过宽限期仍未退出，已标记为需重启恢复；期间不释放槽位以防同资源类并发")
        }
    }

    // MARK: 调度

    private func gate(for cls: TaskKind.ResourceClass) -> AsyncClassGate {
        switch cls {
        case .inference: return inferenceGate
        case .download:  return downloadGate
        case .llm:       return llmGate
        }
    }

    func resumeAfterUpdatePreparation() { pump() }

    private func pump() {
        guard !AppUpdateService.shared.isPreparingToInstall else { return }
        while runningJobIDs.count < Self.maxConcurrentJobs,
              let idx = jobs.firstIndex(where: { $0.state == .queued }) {
            startJob(at: idx)
        }
    }

    private func startJob(at index: Int) {
        let id = jobs[index].id
        jobs[index].state = .running
        runningJobIDs.insert(id)
        jobTasks[id] = Task { @MainActor [weak self] in
            await self?.runJob(id: id)
        }
    }

    /// 顺序执行 Job 内的各步骤；每一步先取资源类槽位，再 await 执行体
    private func runJob(id: UUID) async {
        defer { completeJob(id: id) }

        while true {
            guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
            if jobs[idx].state == .cancelled || jobs[idx].state == .paused { return }
            let stepIdx = jobs[idx].currentStep
            guard stepIdx < jobs[idx].steps.count else { return }

            let stepKind = jobs[idx].steps[stepIdx].kind
            let gate = gate(for: stepKind.resourceClass)
            // 排队期间被取消：acquire 返回 false（未占用槽位），直接退出
            guard await gate.acquire(owner: id) else { return }

            // 等待槽位期间可能被取消 / 暂停 / 移出
            guard let idx2 = jobs.firstIndex(where: { $0.id == id }),
                  jobs[idx2].state == .running else {
                gate.release()
                return
            }
            jobs[idx2].steps[stepIdx].state = .running

            let result = await runStepWithWatchdog(jobID: id, stepIndex: stepIdx, kind: stepKind, gate: gate)
            // 槽位由执行体（worker）在自己的结束路径释放——正常完成或孤儿退出都算。
            // 这里**不**释放：超时/取消后孤儿仍在跑时提前放行，会让重试与旧执行在同资源类并发。

            guard let idx3 = jobs.firstIndex(where: { $0.id == id }) else { return }
            if jobs[idx3].state == .cancelled || jobs[idx3].state == .paused { return }

            switch result.outcome {
            case .succeeded:
                jobs[idx3].steps[stepIdx].state = .done
                jobs[idx3].steps[stepIdx].progress = 1
                jobs[idx3].steps[stepIdx].finishedAt = Date()
                jobs[idx3].currentStep += 1
                if jobs[idx3].currentStep >= jobs[idx3].steps.count {
                    jobs[idx3].state = .done
                    return
                }
            case .cancelled:
                // 执行体自报取消（如 VM 内部取消入口被调用）：按取消结算并停止后续步骤
                jobs[idx3].steps[stepIdx].state = .cancelled
                jobs[idx3].steps[stepIdx].errorCode = .cancelled
                jobs[idx3].steps[stepIdx].finishedAt = Date()
                jobs[idx3].state = .cancelled
                return
            case .failed:
                jobs[idx3].steps[stepIdx].state = .failed
                // 失败原因取执行体上报的稳定码；未上报时按「未知」兜底（不落英文原串）
                jobs[idx3].steps[stepIdx].errorCode = jobs[idx3].steps[stepIdx].failure.code ?? .unknown
                jobs[idx3].steps[stepIdx].finishedAt = Date()
                jobs[idx3].state = .failed
                return
            }
        }
    }

    /// 步骤执行的最长等待（超出视为挂起）。取值刻意放宽：只兜「执行体永不返回」，
    /// 不打断慢但在推进的长任务（如 2 小时录音的本地转写 / 说话人分离）。
    nonisolated static func defaultStepTimeout(for kind: TaskKind) -> TimeInterval {
        switch kind.resourceClass {
        case .inference: return 2 * 60 * 60
        case .download:  return 2 * 60 * 60
        case .llm:       return 15 * 60
        }
    }

    /// 看门狗结果：结论 + 资源类槽位是否仍由孤儿执行体持有
    struct WatchdogOutcome {
        let outcome: StepOutcome
        /// true = 超时/取消后执行体仍未退出，槽位由它在退出时释放
        let orphanStillRunning: Bool
    }

    /// 带超时看门狗执行一步。
    ///
    /// 步骤执行体（VM 方法）未必响应取消，可能永久不返回。旧实现在超时后立即释放资源类槽位，
    /// 于是「超时 → 用户重试 → 新执行开始」之后，旧执行迟到返回会与新执行在**同一资源类**
    /// 并发（本地推理是单实例，这是真实的损坏风险）。
    ///
    /// 现在的槽位归属：**无论正常完成还是超时/取消后成为孤儿，槽位都由执行体（worker）
    /// 在自己的结束路径释放**。孤儿未退出时槽位一直被占，重试只能排队等待，
    /// 从而杜绝同资源类并发；超过宽限期仍未退出则标记该资源类「需重启恢复」。
    /// 迟到的结果被一次性盒丢弃，不会二次结算。
    @MainActor
    private func runStepWithWatchdog(
        jobID: UUID, stepIndex: Int, kind: TaskKind, gate: AsyncClassGate
    ) async -> WatchdogOutcome {
        let box = OneShotBox<StepOutcome>()
        let timeout = stepTimeoutProvider(kind)
        let resourceClass = kind.resourceClass
        /// worker 是否已结束（跨隔离域可见）
        let workerFinished = AtomicFlag()
        /// 本次执行使用的失败盒：重试会换上**新实例**，因此迟到孤儿写入旧盒不污染新代次
        let failureBox = jobs.firstIndex(where: { $0.id == jobID })
            .flatMap { i in stepIndex < jobs[i].steps.count ? jobs[i].steps[stepIndex].failure : nil }

        let worker = Task { @MainActor [weak self] in
            defer {
                // 槽位归执行体：正常完成或孤儿退出都从这里释放，并清掉「停止中」标记
                gate.release()
                self?.markResourceClassRunningAgain(resourceClass)
                workerFinished.set()
            }
            guard let self,
                  let i = self.jobs.firstIndex(where: { $0.id == jobID }),
                  stepIndex < self.jobs[i].steps.count else {
                box.deliver(.failed)
                return
            }
            let outcome = await self.jobs[i].steps[stepIndex].run(self.jobs[i].steps[stepIndex].failure)
            box.deliver(outcome)
        }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // 已被结果抢先结算（含调用方取消）时不再判定超时
            guard !Task.isCancelled else { return }
            if box.deliver(.failed) {
                // 打上「超时」稳定码；若期间已重试换了新盒，则写入旧盒、不影响新代次
                failureBox?.code = .timedOut
                self?.markResourceClassStopping(resourceClass)
                self?.logger.error(
                    "任务步骤超时：「\(kind.rawValue, privacy: .public)」超过 \(Int(timeout), privacy: .public)s 未返回；槽位保留给未退出的执行体，避免重试与旧执行并发")
            }
        }

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StepOutcome, Never>) in
                if let early = box.attach(continuation) {
                    continuation.resume(returning: early)
                }
            }
        } onCancel: {
            worker.cancel()
            timer.cancel()
            _ = box.deliver(.cancelled)
        }

        // 超时/取消：尽力取消仍在挂起的孤儿执行体（不响应取消时只能任其成为孤儿，槽位由其持有）
        if outcome != .succeeded { worker.cancel() }
        timer.cancel()

        let orphanStillRunning = !workerFinished.isSet
        if orphanStillRunning {
            // 取消路径到达的孤儿：此处补上「停止中」标记（定时器路径已在定时器内标记）
            markResourceClassStopping(resourceClass)
        }
        return WatchdogOutcome(outcome: outcome, orphanStillRunning: orphanStillRunning)
    }

    private func completeJob(id: UUID) {
        runningJobIDs.remove(id)
        jobTasks[id] = nil
        if let idx = jobs.firstIndex(where: { $0.id == id }), jobs[idx].state == .done {
            // 完成的 Job 短暂保留后自动移除，避免列表堆积
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.removeJob(id: id)
            }
        }
        pump()
    }

    /// 移除已结束（完成 / 失败 / 取消）的 Job
    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// 清空所有已结束的 Job（面板「清除已完成」）
    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    /// 按「目标 + 种类」上报当前运行步骤的进度（下载等长任务的进度回调入口）。
    /// 用目标 + 种类匹配而非 Job ID：Job ID 在构造闭包时尚未生成，无法回传。
    func reportProgress(folderName: String, kind: TaskKind, progress: Double) {
        guard let jobIdx = jobs.firstIndex(where: { $0.state == .running && $0.folderName == folderName }) else { return }
        let stepIdx = jobs[jobIdx].currentStep
        guard stepIdx < jobs[jobIdx].steps.count, jobs[jobIdx].steps[stepIdx].kind == kind else { return }
        jobs[jobIdx].steps[stepIdx].progress = progress
    }

    /// 查询某「目标 + 种类」的运行步骤进度（UI 只读）
    func progress(folderName: String, kind: TaskKind) -> Double? {
        guard let job = jobs.first(where: { $0.folderName == folderName }) else { return nil }
        let stepIdx = job.currentStep
        guard stepIdx < job.steps.count, job.steps[stepIdx].kind == kind else { return nil }
        return job.steps[stepIdx].progress
    }

    /// 是否存在某目标的活动 Job
    func isActive(folderName: String) -> Bool {
        jobs.contains { $0.folderName == folderName && ($0.state == .queued || $0.state == .running || $0.state == .paused) }
    }

    /// 取消某目标下的所有 Job（设置页「取消下载」等无 Job ID 的入口）
    func cancelJobs(folderName: String) {
        for id in jobs.filter({ $0.folderName == folderName }).map(\.id) {
            cancel(jobID: id)
        }
    }
}

// MARK: - 模型下载 Job 工厂

extension TaskCenter {

    /// Whisper 模型下载 Job（唯一支持真正暂停 / 续传的任务）。
    ///
    /// 取消（含「暂停」触发的取消）会传播到被 await 的下载调用；WhisperKit 的下载
    /// 在取消时保留已落盘分片与 `.cache` 元数据，因此「继续」重新调度这一步即从分片续传。
    static func whisperDownloadJob(
        option: WhisperModelOption,
        source: WhisperModelSource,
        modelRootPath: String,
        title: String,
        onProgress: @escaping @MainActor (Double) -> Void,
        onFinished: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> Job {
        let folderKey = "model:\(option.variant)"
        let step = Step(
            kind: .modelDownload,
            run: { _ in
                do {
                    let path = try await WhisperModelDownloader.shared.download(
                        option: option,
                        source: source,
                        modelRootPath: modelRootPath
                    ) { progress in
                        Task { @MainActor in
                            onProgress(progress)
                            TaskCenter.shared.reportProgress(
                                folderName: folderKey, kind: .modelDownload, progress: progress
                            )
                        }
                    }
                    onFinished(.success(path))
                    return .succeeded
                } catch {
                    onFinished(.failure(error))
                    return .failed
                }
            },
            cancel: {
                // 取消由 TaskCenter 取消 Job Task 传播到被 await 的 download；
                // 分片保留，重启这一步即续传
            }
        )
        return Job(folderName: folderKey, title: title, steps: [step], isDurable: false)
    }
}
