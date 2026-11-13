import Foundation
import KeychainAccess
import os.log

/// 后台任务失败的**稳定原因码**：落盘只存码，界面再本地化（不落中文/英文原文）。
enum BackgroundTaskFailureCode: String, Codable, Sendable {
    case databaseReadFailed
    case processingFailed
    case missingLLMConfig
    case keychainUnavailable
    case cloudKeyMissing

    /// 面向用户的失败摘要（本地化）
    var localizedSummary: String {
        switch self {
        case .databaseReadFailed:   return String(localized: "读取本地数据失败，稍后会自动重试。")
        case .processingFailed:     return String(localized: "处理失败（可能是模型或网络问题），稍后会自动重试。")
        case .missingLLMConfig:     return String(localized: "未找到可用的大模型配置，请在设置中检查。")
        case .keychainUnavailable:  return String(localized: "暂时无法读取密钥（钥匙串不可用），稍后会自动重试。")
        case .cloudKeyMissing:      return String(localized: "未配置云端转写密钥，请在设置中填写。")
        }
    }
}

/// 后台任务类型（守护进程与主应用兜底续跑共用）
enum BackgroundTaskKind: String, Codable, Sendable {
    case transcription      // 录音转写（用户点击触发）
    case summary            // 录音总结（用户点击触发）
    case quicknoteSummary   // 快捷笔记总结（用户点击触发）

    /// 面板展示用名称（复用既有本地化键）
    var displayName: String {
        switch self {
        case .transcription:                 return String(localized: "转写")
        case .summary, .quicknoteSummary:    return String(localized: "总结")
        }
    }
}

/// STT 配置快照（Codable，随队列条目落盘，防止用户后续改设置导致 worker 行为不一致）。
/// apiKey 不落盘（明文 JSON 有泄露风险），执行时从 Keychain 实时读取。
struct STTConfigSnapshot: Codable, Sendable {
    var mode: String
    var modelPath: String
    var baseURL: String
    var language: String
    var enableSpeakerDiarization: Bool
    var diarizationModelPath: String
    var enableVoiceprintRecognition: Bool
    var enableDictionaryCorrection: Bool

    init(config: STTConfig) {
        self.mode = config.mode.rawValue
        self.modelPath = config.modelPath
        self.baseURL = config.baseURL
        self.language = config.language
        self.enableSpeakerDiarization = config.enableSpeakerDiarization
        self.diarizationModelPath = config.diarizationModelPath
        self.enableVoiceprintRecognition = config.enableVoiceprintRecognition
        self.enableDictionaryCorrection = config.enableDictionaryCorrection
    }

    /// 还原为 STTConfig（apiKey 从 Keychain 补齐，与 SettingsViewModel 同源）
    var config: STTConfig {
        STTConfig(
            mode: STTMode(rawValue: mode) ?? .local,
            modelPath: modelPath,
            apiKey: Self.readWhisperAPIKey(),
            baseURL: baseURL,
            language: language,
            enableSpeakerDiarization: enableSpeakerDiarization,
            diarizationModelPath: diarizationModelPath,
            enableVoiceprintRecognition: enableVoiceprintRecognition,
            enableDictionaryCorrection: enableDictionaryCorrection
        )
    }

    /// Whisper API Key 的三态读取结果：区分「确实未存」与「Keychain 读失败」。
    /// 旧实现把读失败当成空 Key，仍照发 `Authorization: Bearer `；401 属 4xx 不重试，
    /// 于是用户看到「Key 无效」，而设置里明明配了 Key（锁屏/Keychain 不可用时典型发生）。
    enum APIKeyReadResult: Sendable, Equatable {
        case value(String)
        case absent
        case readFailed(String)

        var isReadFailed: Bool { if case .readFailed = self { true } else { false } }
    }

    /// 三态读取（供 worker 判定「不得以空凭据发起请求」）
    static func readWhisperAPIKeyResult() -> APIKeyReadResult {
        let keychain = Keychain(service: "app.memozia")
            .accessibility(.afterFirstUnlock)
        do {
            if let key = try keychain.get(snapshotStorageKey), !key.isEmpty {
                return .value(key)
            }
            return .absent
        } catch {
            snapshotLogger.error("Keychain 读取 Whisper API Key 失败: \(error.localizedDescription)")
            return .readFailed(error.localizedDescription)
        }
    }

    /// 兼容旧调用：只取可用值，读失败等价于空串。
    /// - Important: **不得**用它判定「能否以空凭据发起请求」；该判定走 `readWhisperAPIKeyResult()`。
    private static func readWhisperAPIKey() -> String {
        if case .value(let key) = readWhisperAPIKeyResult() { return key }
        return ""
    }

    /// Keychain 存储键（与 SettingsViewModel.StorageKey.whisperAPIKey 一致）
    private static let snapshotStorageKey = "whisper_api_key"
    /// 快照还原链路日志
    private static let snapshotLogger = Logger(
        subsystem: "app.memozia", category: "BackgroundTaskQueue"
    )
}

/// 后台任务队列条目
struct BackgroundTaskEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let kind: BackgroundTaskKind
    /// 目标条目文件夹名（yyyyMMddHHmmss[-N]），worker 执行时据此从数据库 fetch
    let folderName: String
    var llmConfigID: UUID?
    var sttSnapshot: STTConfigSnapshot?
    /// 总结模板选择（true=会议总结，false=概要总结）：用户点按钮时随任务入队，
    /// 守护进程续跑不重新判定；旧队列条目缺字段解码为 nil → 条目持久化判定/文本分类兑底
    var isMeeting: Bool?
    /// 发起任务时的体验模式。保存为可选以兼容旧队列；守护进程用它保持
    /// 自动总结与 PII 保护语义，不受入队后模式切换影响。
    var experience: AppExperience?
    let enqueuedAt: Date
    /// 已尝试执行次数（含失败）；旧队列缺字段 → nil
    var attempt: Int? = nil
    /// 下次可重试时间：指数退避。未到点前不取该条目执行；旧队列 → nil（立即可执行）
    var nextRetryAt: Date? = nil
    /// 最近一次失败原因（稳定码，界面本地化后再展示）
    var lastFailureCode: BackgroundTaskFailureCode? = nil

    init(
        kind: BackgroundTaskKind,
        folderName: String,
        llmConfigID: UUID? = nil,
        sttSnapshot: STTConfigSnapshot? = nil,
        isMeeting: Bool? = nil,
        experience: AppExperience? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.folderName = folderName
        self.llmConfigID = llmConfigID
        self.sttSnapshot = sttSnapshot
        self.isMeeting = isMeeting
        self.experience = experience
        self.enqueuedAt = Date()
    }
}

/// 队列文件根结构
struct BackgroundTaskQueueData: Codable, Sendable {
    var tasks: [BackgroundTaskEntry] = []
    /// 正在执行的条目 ID：worker 崩溃后该条目视为待重跑（下次加载时清除标记即可）
    var inProgressID: UUID?
    /// 失败区：不可重试或超过重试上限的任务**保留**在这里（不静默删除），供面板展示与用户重试
    var failedEntries: [BackgroundTaskEntry] = []

    init(
        tasks: [BackgroundTaskEntry] = [],
        inProgressID: UUID? = nil,
        failedEntries: [BackgroundTaskEntry] = []
    ) {
        self.tasks = tasks
        self.inProgressID = inProgressID
        self.failedEntries = failedEntries
    }

    /// 显式解码：`failedEntries` 是后加字段，旧队列文件没有它；
    /// 用合成 `decode` 会因缺字段直接失败，进而被当成「损坏」丢任务。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([BackgroundTaskEntry].self, forKey: .tasks) ?? []
        inProgressID = try container.decodeIfPresent(UUID.self, forKey: .inProgressID)
        failedEntries = try container.decodeIfPresent([BackgroundTaskEntry].self, forKey: .failedEntries) ?? []
    }
}

/// 持久化后台任务队列（主应用与守护进程经同一文件协作）。
///
/// 访问模型：所有方法直接读写磁盘文件（tmp + rename 原子写）。
/// - 单进程内：调用方均在 MainActor（ViewModel 埋点 / drainQueue），天然串行
/// - 跨进程：由 BackgroundWorker 的握手协议保证同一时间只有一方消费队列
enum BackgroundTaskQueue {

    private static let logger = Logger(
        subsystem: "app.memozia", category: "BackgroundTaskQueue"
    )

    /// 临时模式门控：只读时不入队——磁盘队列是权威源，临时模式的出队记录写内存库后会随退出消失，
    /// 提前把队列删空等于丢任务。由应用启动时注入；默认 readWrite（worker/测试不受影响）。
    private static let capabilityLock = NSLock()
    nonisolated(unsafe) private static var _capability: PersistenceCapability = .readWrite

    /// 当前持久化能力（线程安全）
    static var capability: PersistenceCapability {
        capabilityLock.lock(); defer { capabilityLock.unlock() }
        return _capability
    }

    /// 注入持久化能力（应用启动时调用一次）
    static func installCapability(_ capability: PersistenceCapability) {
        capabilityLock.lock(); _capability = capability; capabilityLock.unlock()
    }

    /// 队列文件位置：存储目录（可配置）下，两进程经同一 UserDefaults 解析同一目录
    static var queueFileURL: URL {
        AudioRecording.storageDirectory
            .appendingPathComponent(".background_task_queue.json")
    }

    // MARK: - 读写

    /// 队列文件读取状态：**必须**区分「没有文件」与「损坏/读不出」。
    ///
    /// 旧实现把两者都当空队列返回，而队列的每次变更都是「读-改-写」——
    /// 只要有一次读失败（文件被截断、磁盘瞬时错误、编码格式变更），
    /// 紧接着的写就会把全部待办任务覆盖成「只剩本次改动的那一条」，
    /// 且 `hasEntries()` 也返回 false，守护进程直接退出、主应用也不再兜底续跑。
    private enum QueueFileState {
        case loaded(BackgroundTaskQueueData)
        case absent
        case corrupted(any Error)
    }

    /// 队列文件损坏/不可用时的上报错误（日志与用户提示共用同一描述）
    struct QueueFileError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    enum ReadResult {
        case loaded(BackgroundTaskQueueData)
        case unavailable(QueueFileError)
    }

    private static var backupFileURL: URL {
        queueFileURL.appendingPathExtension("bak")
    }

    private static func readQueueFile(_ url: URL) -> QueueFileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(BackgroundTaskQueueData.self, from: data))
        } catch {
            return .corrupted(error)
        }
    }

    /// 可判定的只读入口：损坏且无备份时绝不伪装成空队列。
    static func readResult() -> ReadResult {
        switch readQueueFile(queueFileURL) {
        case .loaded(let data):
            return .loaded(data)
        case .absent:
            if case .loaded(let backup) = readQueueFile(backupFileURL) {
                return .loaded(backup)
            }
            return .loaded(BackgroundTaskQueueData())
        case .corrupted(let error):
            if case .loaded(let backup) = readQueueFile(backupFileURL) {
                logger.error("后台任务队列主文件损坏，只读路径使用备份")
                return .loaded(backup)
            }
            let queueError = QueueFileError(
                reason: "后台任务队列无法读取且无可用备份：\(error.localizedDescription)"
            )
            logger.fault("\(queueError.reason, privacy: .public)")
            PersistenceReporting.reportSaveFailure(queueError)
            return .unavailable(queueError)
        }
    }

    /// 兼容诊断/测试的便捷读取；消费者必须使用 `readResult()` 判断错误。
    static func loadFromDisk() -> BackgroundTaskQueueData {
        if case .loaded(let data) = readResult() { return data }
        return BackgroundTaskQueueData()
    }

    /// 原子写队列文件（tmp + rename）并刷新 last-known-good 备份。
    /// - Returns: 是否写入成功（调用方据此决定后续动作，失败不再静默）
    @discardableResult
    static func saveToDisk(_ data: BackgroundTaskQueueData) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(data) else {
            logger.fault("后台任务队列编码失败，队列未更新")
            return false
        }
        guard writeAtomically(encoded, to: queueFileURL) else {
            // 队列写不进去会直接影响任务续跑，属关键失败：必须留痕（旧实现只打一行 error）
            PersistenceReporting.reportSaveFailure(
                QueueFileError(reason: "后台任务队列写入失败（\(queueFileURL.path)）")
            )
            return false
        }
        // last-known-good：供损坏恢复使用；备份失败不影响本次队列更新
        if !writeAtomically(encoded, to: backupFileURL) {
            logger.error("后台任务队列备份写入失败（本次队列更新已生效）")
        }
        return true
    }

    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let tmpURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            logger.error("后台任务队列原子写失败（\(url.lastPathComponent)）: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 跨进程文件锁

    /// 跨进程互斥锁：队列文件的读-改-写必须原子，防止主应用入队与 worker 消费
    /// 并发时丢失更新（握手协议只保证消费端互斥，不阻止主应用在 worker 运行中入队）。
    ///
    /// 旧实现有两处静默降级：锁文件打不开时**无锁执行**、且忽略 `flock` 返回值 ——
    /// 两者都让「读-改-写」与另一进程的写入互相覆盖。现在改为有界等待后明确失败
    /// （队列是小 JSON 读写，正常持锁时间为毫秒级；上限只防异常挂死阻塞 MainActor）。
    private static var lockFilePath: String {
        queueFileURL.appendingPathExtension("lock").path
    }

    /// 取跨进程互斥锁（有界等待）
    /// - Returns: 锁文件描述符；nil 表示未取到锁（调用方必须放弃本次改动）
    private static func acquireLock(timeout: TimeInterval = 2) -> Int32? {
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // 锁文件建不出来（磁盘满/权限）是持久性失败，不是本次竞争落空：
            // 每轮入队都会失败，必须显式上报而非只留一条日志
            let reason = "后台任务队列锁文件无法创建（\(lockFilePath)），errno=\(errno)"
            logger.fault("\(reason, privacy: .public)")
            PersistenceReporting.reportSaveFailure(QueueFileError(reason: reason))
            return nil
        }
        // 主线程不得长时间阻塞：正常持锁为毫秒级，但守护进程异常持锁时 2s 轮询会
        // 冻住界面（入队/出队由 ViewModel 在 MainActor 调用）。主线程只允许极短等待，
        // 超时即放弃本次改动（下轮刷新/重启会补上），把长等待留给非主线程路径。
        let onMainThread = Thread.isMainThread
        let effectiveTimeout = onMainThread ? min(timeout, 0.2) : timeout
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if Date() >= deadline {
                logger.fault("后台任务队列锁等待超时（主线程=\(onMainThread, privacy: .public)，上限 \(effectiveTimeout, privacy: .public)s），放弃本次改动")
                close(fd)
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func releaseLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// 在跨进程锁保护下执行队列读-改-写
    ///
    /// - `body` 返回是否发生了改动；未改动则不写盘
    /// - 拿不到锁：不执行、不写盘，返回 false
    /// - 队列文件损坏：隔离损坏文件并以备份/空队列继续（见 `recoverFromCorruption`）
    /// - 写盘失败：返回 false
    /// - Returns: 本次改动是否已成功落盘
    @discardableResult
    private static func mutate(_ body: (inout BackgroundTaskQueueData) -> Bool) -> Bool {
        guard let fd = acquireLock() else { return false }
        defer { releaseLock(fd) }

        var data: BackgroundTaskQueueData
        var recoveredCorruption = false
        switch readQueueFile(queueFileURL) {
        case .loaded(let loaded):
            data = loaded
        case .absent:
            data = BackgroundTaskQueueData()
        case .corrupted(let error):
            guard let recovered = recoverFromCorruption(error) else { return false }
            data = recovered
            recoveredCorruption = true
        }

        // 未改动时视为成功（例如去重后无需入队），但仍可能已产生损坏恢复，故补一次落盘
        if body(&data) { return saveToDisk(data) }
        if recoveredCorruption { return saveToDisk(data) }
        return true
    }

    /// 隔离损坏的队列文件并尽力保留任务：
    /// 备份可用则用备份内容；否则按空队列重建。两种情况都会把损坏文件改名留存并上报用户
    private static func recoverFromCorruption(_ error: any Error) -> BackgroundTaskQueueData? {
        guard case .loaded(let backup) = readQueueFile(backupFileURL) else {
            let reason = "后台任务队列损坏且无可用备份，已保留原文件，本次修改已拒绝：\(error.localizedDescription)"
            logger.fault("\(reason, privacy: .public)")
            PersistenceReporting.reportSaveFailure(QueueFileError(reason: reason))
            return nil
        }
        let quarantineURL = queueFileURL
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: queueFileURL, to: quarantineURL)
        } catch {
            let reason = "后台任务队列损坏且隔离失败，本次修改已拒绝：\(error.localizedDescription)"
            logger.fault("\(reason, privacy: .public)")
            PersistenceReporting.reportSaveFailure(QueueFileError(reason: reason))
            return nil
        }
        let detail = "已从最近一次成功保存的备份恢复 \(backup.tasks.count) 条"
        logger.fault(
            "后台任务队列文件损坏（\(error.localizedDescription)），已隔离为 \(quarantineURL.lastPathComponent)，\(detail)"
        )
        PersistenceReporting.reportSaveFailure(
            QueueFileError(
                reason: "后台任务队列文件损坏，已隔离为 \(quarantineURL.lastPathComponent)；\(detail)"
            )
        )
        return backup
    }

    // MARK: - 队列操作

    /// 入队（幂等：同类型同目标已存在时不重复入队——
    /// 主应用埋点与 worker 复用 ViewModel 执行同一路径时不会产生重复条目）
    /// - Returns: 是否已成功落盘（false 表示队列未被修改）
    @discardableResult
    static func enqueue(_ entry: BackgroundTaskEntry) -> Bool {
        guard capability.allowsContentMutation else {
            logger.error("临时模式下不写入后台任务队列: \(entry.kind.rawValue) \(entry.folderName)")
            return false
        }
        var queueLength = 0
        let saved = mutate { data in
            queueLength = data.tasks.count
            guard !data.tasks.contains(where: {
                $0.kind == entry.kind && $0.folderName == entry.folderName
            }) else { return false }
            data.tasks.append(entry)
            data.tasks.sort { $0.enqueuedAt < $1.enqueuedAt }
            queueLength = data.tasks.count
            return true
        }
        if saved {
            logger.info("后台任务入队: \(entry.kind.rawValue) \(entry.folderName)，队列长度 \(queueLength)")
        } else {
            logger.error("后台任务入队未落盘: \(entry.kind.rawValue) \(entry.folderName)")
        }
        return saved
    }

    /// 出队（按类型+目标移除；任务完成/取消/失败时由 ViewModel 埋点调用）
    /// - Returns: 是否已成功落盘
    @discardableResult
    static func dequeue(kind: BackgroundTaskKind, folderName: String) -> Bool {
        var removed = false
        var remaining = 0
        let saved = mutate { data in
            let before = data.tasks.count
            data.tasks.removeAll { $0.kind == kind && $0.folderName == folderName }
            remaining = data.tasks.count
            guard data.tasks.count != before else { return false }
            removed = true
            // 被移除的若是当前执行中的条目，同步清掉执行标记
            if let inProgress = data.inProgressID,
               !data.tasks.contains(where: { $0.id == inProgress }) {
                data.inProgressID = nil
            }
            return true
        }
        if removed, saved {
            logger.info("后台任务出队: \(kind.rawValue) \(folderName)，队列长度 \(remaining)")
        } else if !saved {
            logger.error("后台任务出队未落盘: \(kind.rawValue) \(folderName)")
        }
        return saved
    }

    /// 队首条目（按入队时间排序）
    static func peekFirst() -> BackgroundTaskEntry? {
        loadFromDisk().tasks.min { $0.enqueuedAt < $1.enqueuedAt }
    }

    static func peekFirstResult() -> Result<BackgroundTaskEntry?, QueueFileError> {
        switch readResult() {
        case .loaded(let data):
            return .success(data.tasks.min { $0.enqueuedAt < $1.enqueuedAt })
        case .unavailable(let error):
            return .failure(error)
        }
    }

    /// 按 ID 移除条目（worker 执行完的兜底出队，幂等）
    /// - Returns: 是否已成功落盘
    @discardableResult
    static func removeEntry(id: UUID) -> Bool {
        mutate { data in
            guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return false }
            data.tasks.remove(at: index)
            if data.inProgressID == id { data.inProgressID = nil }
            return true
        }
    }

    /// 标记条目执行中（崩溃后可据此识别未完成任务；inProgress 条目重跑是安全的：
    /// 转写清旧 segments 重建、总结直接覆盖，均为幂等操作）
    /// - Returns: 是否已成功落盘
    @discardableResult
    static func markInProgress(id: UUID) -> Bool {
        mutate { data in
            guard data.inProgressID != id else { return false }
            data.inProgressID = id
            return true
        }
    }

    /// 清除执行标记（worker 启动时/每轮任务结束后调用）
    /// - Returns: 是否已成功落盘
    @discardableResult
    static func clearInProgress() -> Bool {
        mutate { data in
            guard data.inProgressID != nil else { return false }
            data.inProgressID = nil
            return true
        }
    }

    /// 队列是否非空
    static func hasEntries() -> Bool {
        switch readResult() {
        case .loaded(let data): return !data.tasks.isEmpty
        case .unavailable: return true
        }
    }

    static func hasEntriesResult() -> Result<Bool, QueueFileError> {
        switch readResult() {
        case .loaded(let data): return .success(!data.tasks.isEmpty)
        case .unavailable(let error): return .failure(error)
        }
    }

    // MARK: - 重试退避与失败区（BK-4）

    /// 指数退避策略（纯函数，便于回归测试）
    enum Backoff {
        /// 超过该次数即移入失败区（保留，不静默删除）
        static let maxAttempts = 5
        static let baseSeconds: TimeInterval = 30
        static let capSeconds: TimeInterval = 30 * 60

        /// attempt 从 1 起（首次失败）
        static func delay(forAttempt attempt: Int) -> TimeInterval {
            guard attempt >= 1 else { return 0 }
            return min(baseSeconds * pow(2, Double(attempt - 1)), capSeconds)
        }
    }

    /// 队首「已到可重试时间」的条目：跳过仍处于退避窗口内的条目，
    /// 避免一个毒任务把整条队列堵在队首反复重试。
    static func peekFirstReadyResult(now: Date = Date()) -> Result<BackgroundTaskEntry?, QueueFileError> {
        switch readResult() {
        case .loaded(let data):
            let ready = data.tasks
                .filter { entry in
                    guard let next = entry.nextRetryAt else { return true }
                    return next <= now
                }
                .min { $0.enqueuedAt < $1.enqueuedAt }
            return .success(ready)
        case .unavailable(let error):
            return .failure(error)
        }
    }

    /// 记录一次可重试/配置阻塞失败：attempt+1 并按指数退避设置下次重试时间；
    /// 达到上限则移入失败区。条目始终**保留**（不静默删除）。
    /// - Returns: 是否已成功落盘
    @discardableResult
    static func recordRetryableFailure(id: UUID, code: BackgroundTaskFailureCode, now: Date = Date()) -> Bool {
        mutate { data in
            guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return false }
            var entry = data.tasks[index]
            let attempt = (entry.attempt ?? 0) + 1
            entry.attempt = attempt
            entry.lastFailureCode = code
            if attempt >= Backoff.maxAttempts {
                data.tasks.remove(at: index)
                entry.nextRetryAt = nil
                data.failedEntries.append(entry)
            } else {
                entry.nextRetryAt = now.addingTimeInterval(Backoff.delay(forAttempt: attempt))
                data.tasks[index] = entry
            }
            if data.inProgressID == id { data.inProgressID = nil }
            return true
        }
    }

    /// 失败区条目（供面板展示与「重试 / 丢弃」入口）
    static func failedEntries() -> [BackgroundTaskEntry] {
        loadFromDisk().failedEntries
    }

    /// 把失败区条目移回待办并清零退避（用户点击「重试」）
    @discardableResult
    static func retryFailedEntry(id: UUID) -> Bool {
        mutate { data in
            guard let index = data.failedEntries.firstIndex(where: { $0.id == id }) else { return false }
            var entry = data.failedEntries.remove(at: index)
            entry.attempt = nil
            entry.nextRetryAt = nil
            data.tasks.append(entry)
            data.tasks.sort { $0.enqueuedAt < $1.enqueuedAt }
            return true
        }
    }

    /// 丢弃失败区条目（用户确认不再重试）
    @discardableResult
    static func discardFailedEntry(id: UUID) -> Bool {
        mutate { data in
            let before = data.failedEntries.count
            data.failedEntries.removeAll { $0.id == id }
            return data.failedEntries.count != before
        }
    }
}

/// 远端转写需要密钥时的守卫：Keychain 读失败**不得**以空凭据发起请求，
/// 否则会被 401 误导成「Key 无效」。抽成纯函数便于确定性回归。
enum BackgroundTaskKeyGuard {
    /// - Returns: 需要阻塞时的稳定原因码；nil 表示可继续执行
    static func blockReason(
        mode: STTMode,
        keyReadResult: STTConfigSnapshot.APIKeyReadResult
    ) -> BackgroundTaskFailureCode? {
        guard mode == .cloud else { return nil }
        switch keyReadResult {
        case .value:
            return nil
        case .absent:
            return .cloudKeyMissing
        case .readFailed:
            return .keychainUnavailable
        }
    }
}
