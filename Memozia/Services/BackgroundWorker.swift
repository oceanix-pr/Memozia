import Foundation
import SwiftData
import AppKit
import os.log
import Darwin

/// 后台守护进程：主应用退出时续跑用户已发起的未完成任务（转写/总结/分片合并），
/// 队列清空或收到主应用接管请求后自动退出。
///
/// 运行形态：同二进制带 `--background-worker` 参数（复用 --calibrate-diarization 模式），
/// 全部服务（Whisper/LLM/加密/ViewModel）零改动复用，不新建 target。
///
/// 进程协作协议（文件握手，位于存储目录）：
/// - `.background_worker.pid`：worker 存活标记，内容为 PID 文本
/// - `.background_worker_stop`：主应用启动时写入，worker 完成当前单个任务后退出
/// - 单实例守卫读 pid 文件识别 worker，避免主应用被误判为重复实例
enum BackgroundWorker {

    /// PID 会被系统复用；单独保存一个整数不足以证明当前进程仍是我们拉起的 worker。
    /// 启动时间与可执行文件路径共同构成进程身份，避免过期 PID 文件导致 SIGTERM 误伤。
    struct ProcessIdentity: Codable, Equatable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String
    }

    static let launchFlag = "--background-worker"

    private static let logger = Logger(
        subsystem: "app.memozia", category: "BackgroundWorker"
    )

    // MARK: - 协议文件

    private static var pidFileURL: URL {
        AudioRecording.storageDirectory.appendingPathComponent(".background_worker.pid")
    }

    private static var stopFileURL: URL {
        AudioRecording.storageDirectory.appendingPathComponent(".background_worker_stop")
    }

    private static func stopFlagExists() -> Bool {
        FileManager.default.fileExists(atPath: stopFileURL.path)
    }

    @discardableResult
    private static func writePidFile() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let identity = processIdentity(pid: pid),
              let data = try? JSONEncoder().encode(identity) else {
            logger.fault("无法读取 worker 进程身份，拒绝写入不安全的纯 PID 标记")
            return false
        }
        do {
            try data.write(to: pidFileURL, options: .atomic)
            return true
        } catch {
            logger.fault("worker 进程身份写入失败：\(error.localizedDescription)")
            return false
        }
    }

    private static func cleanupPidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private static func readPidFile() -> ProcessIdentity? {
        guard let data = try? Data(contentsOf: pidFileURL) else { return nil }
        // 旧版纯 PID 文件无法抵御 PID 复用，升级后按过期标记清理，不再据此发送信号。
        return try? JSONDecoder().decode(ProcessIdentity.self, from: data)
    }

    private static func isProcessAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// 从内核读取 PID 对应进程的启动时间与可执行文件；任一字段取不到都不信任该 PID。
    private static func processIdentity(pid: pid_t) -> ProcessIdentity? {
        var bsdInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, infoSize) == infoSize else {
            return nil
        }

        // PROC_PIDPATHINFO_MAXSIZE 是 C 表达式宏，Swift 不会导入；其定义为 4 * MAXPATHLEN。
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        // C 字符串按 NUL 截断后以 UTF-8 解码（`String(cString:)` 已废弃）
        let pathBytes = pathBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return ProcessIdentity(
            pid: pid,
            startSeconds: bsdInfo.pbi_start_tvsec,
            startMicroseconds: bsdInfo.pbi_start_tvusec,
            executablePath: URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
                .standardizedFileURL.path
        )
    }

    static func identitiesMatch(recorded: ProcessIdentity, actual: ProcessIdentity) -> Bool {
        recorded == actual
    }

    /// worker PID（仅当 pid 文件存在且进程仍存活时返回）
    static func liveWorkerPID() -> pid_t? {
        guard let recorded = readPidFile(), isProcessAlive(pid: recorded.pid),
              let actual = processIdentity(pid: recorded.pid),
              identitiesMatch(recorded: recorded, actual: actual) else {
            // 顺手清理过期 pid 文件（worker 已自然退出但未及清理的场景）
            try? FileManager.default.removeItem(at: pidFileURL)
            return nil
        }
        return recorded.pid
    }

    static func isWorkerRunning() -> Bool {
        liveWorkerPID() != nil
    }

    // MARK: - 启动入口（主应用 App 初始化阶段调用）

    /// 启动参数命中 `--background-worker` 时执行守护进程主循环并退出；
    /// 未命中为无操作空返回，对正常启动零开销
    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchFlag) else { return }
        run()
    }

    /// 守护进程主循环（不返回）
    private static func run() -> Never {
        ProcessLimits.raiseFileDescriptorLimit()
        // 无 UI 进程：禁止 Dock 图标，避免退出主应用后出现第二个应用图标。
        // run() 仅由 App 结构体初始化（主线程）经 runIfRequested() 同步进入；
        // 沿用 MemoziaApp 的 assumeOnMainThread 模式访问 @MainActor 的 NSApplication
        // （不用 assumeIsolated：macOS 26 上其 executor 断言可能读坏指针崩溃）
        MainActor.assumeOnMainThread {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
        }
        logger.info("后台守护进程启动 PID=\(ProcessInfo.processInfo.processIdentifier)")

        // 启动即见停止标记：主应用已在等待接管（握手竞态窗口），直接让位，
        // 队列留给主应用启动时的兜底续跑
        if stopFlagExists() {
            logger.info("启动时已存在停止标记，守护进程让位退出")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
        guard writePidFile() else {
            logger.error("无法建立安全的 worker 身份握手，保留队列并退出")
            ProcessLimits.exitSkippingStaticDestructors(0)
        }

        // 恢复分片也会移动/删除存储文件，必须先取得与主应用共用的独占权。
        // 否则主应用退出时 AVAssetWriter 还在 finalize，worker 已开始修补/合并同一分片。
        guard DatabaseOwnershipLock.acquire(timeout: 60) else {
            logger.error("未能取得存储独占锁（主应用仍在收尾），分片与队列均保留")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }

        // 阶段 1：分片恢复
        let recovered = recoverCrashedSegments()
        logger.info("分片恢复阶段完成，恢复 \(recovered) 个文件夹")

        // 阶段 2：队列处理
        guard BackgroundTaskQueue.clearInProgress() else {
            logger.error("无法清理后台队列执行标记，为避免重复执行而退出")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
        let hasEntries: Bool
        switch BackgroundTaskQueue.hasEntriesResult() {
        case .success(let value):
            hasEntries = value
        case .failure(let error):
            logger.fault("后台队列不可读，保留现场并退出：\(error.localizedDescription)")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
        guard hasEntries else {
            logger.info("后台任务队列为空，守护进程退出")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }

        guard let container = makeModelContainer() else {
            // 数据库打开失败（如磁盘/权限异常）：保留队列退出，主应用启动时兜底续跑
            logger.error("数据库打开失败，队列保留，守护进程退出")
            cleanupPidFile()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }

        // 队列处理必须由主线程 RunLoop 驱动：startTranscription/generateSummary
        // 内部的 Task { @MainActor } 回调依赖主线程调度，不能用 semaphore 阻塞主线程（死锁）
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let context = ModelContext(container)
            await drainQueue(context: context)
            // 等待最后一项任务的条目镜像落盘后再退出：数据库保存成功通常可下次补写，
            // 但**文件是权威源**，直接 exit(0) 可能丢掉尚未写完的 transcript/summary 镜像。
            // flush 超时会记 fault（留下可恢复线索）而不是无限等待；返回结构化结果，
            // 据此记录哪些目标未落盘（已留恢复标记，下次启动由磁盘对账补写）。
            let mirrorResult = await EntryMirrorStore.shared.flush()
            if !mirrorResult.isComplete {
                logger.warning(
                    "守护进程退出时条目镜像未全部落盘：成功 \(mirrorResult.succeeded)，失败 \(mirrorResult.failed)，未完成目标 \(mirrorResult.remaining.joined(separator: ", "))；将由下次启动的磁盘对账补写"
                )
            }
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.2) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        logger.info("后台任务全部完成，守护进程退出")
        cleanupPidFile()
        try? FileManager.default.removeItem(at: stopFileURL)
        ProcessLimits.exitSkippingStaticDestructors(0)
    }

    // MARK: - 阶段 1：分片恢复

    /// 崩溃分片恢复的等待上限：正常只需数秒；给足冗余但绝不无限等
    private static let recoverSegmentsTimeout: TimeInterval = 180

    /// 扫描存储目录的所有条目文件夹，对含崩溃遗留分片（_mic_tmp_*/_sys_tmp_*）的执行恢复。
    /// 此阶段无 MainActor 依赖，可用 semaphore 阻塞主线程等待
    private static func recoverCrashedSegments() -> Int {
        let sem = DispatchSemaphore(value: 0)
        // Swift 6：Task 闭包与主线程都要访问计数，用 Sendable Box 包装
        final class CountBox: @unchecked Sendable { var count = 0 }
        let box = CountBox()
        Task {
            for dir in entryDirectories() {
                if stopFlagExists() { break }
                if await FileSyncService.recoverCrashedSegmentsIfPresent(in: dir) != nil {
                    box.count += 1
                }
            }
            sem.signal()
        }
        // 有界等待：内部做文件 IO 且可能走 AVAssetExportSession 导出，任一环节挂起时
        // 无界的 `sem.wait()` 会让守护进程永久卡住——而它同时还持有数据库独占锁，
        // 主应用会被迫退化到内存存储。到点即放弃等待并返回 0（不再读 box.count，
        // 避免与仍在运行的 Task 竞争）：分片仍在磁盘上，下轮启动/对账会再次尝试恢复
        guard sem.wait(timeout: .now() + recoverSegmentsTimeout) == .success else {
            logger.error("崩溃分片恢复超时（\(Int(recoverSegmentsTimeout))s），本轮放弃等待；分片保留待下次恢复")
            return 0
        }
        return box.count
    }

    /// 存储目录下的所有条目文件夹（月份目录 yyyy-MM 展开一层 + 旧版平铺兼容）
    private static func entryDirectories() -> [URL] {
        let storageDir = AudioRecording.storageDirectory
        guard let topDirs = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for dir in topDirs {
            guard isDirectory(dir) else { continue }
            if isMonthFolderName(dir.lastPathComponent) {
                let inner = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                result.append(contentsOf: inner.filter { isDirectory($0) })
            } else {
                result.append(dir)
            }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// 月份目录名判定（yyyy-MM），与 FileSyncService 的布局约定一致
    private static func isMonthFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count == 2,
              parts[0].count == 4, parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        else { return false }
        return true
    }

    /// 是否存在未合并的崩溃遗留分片（主应用退出时判断是否需要拉起 worker）。
    /// 合并标记仍活跃（写标记进程存活）的文件夹不算：
    /// 避免在主应用合并尚未结束时拉起 worker 与其争抢分片/输出
    static func hasUnmergedSegments() -> Bool {
        for dir in entryDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            if files.contains(where: {
                $0.lastPathComponent.contains("_mic_tmp")
                    || $0.lastPathComponent.contains("_sys_tmp")
            }), !FileSyncService.mergeMarkerHoldsRecovery(at: dir) {
                return true
            }
        }
        return false
    }

    // MARK: - 阶段 2：队列处理（worker 与主应用兜底续跑共用）

    /// 串行消费后台任务队列直到清空或收到停止信号。
    /// worker 进程与主应用（RootView 启动兜底）共用此逻辑，各自传入自己的 ModelContext
    @MainActor
    static func drainQueue(context: ModelContext) async {
        let recordingVM = RecordingViewModel()
        let quickNoteVM = QuickNoteViewModel()
        // 重置上次崩溃遗留的 .processing 状态（B-6 同款逻辑）
        recordingVM.resetStaleProcessingStates(context: context)

        while !stopFlagExists() {
            let entry: BackgroundTaskEntry
            switch BackgroundTaskQueue.peekFirstReadyResult() {
            case .success(.some(let next)):
                entry = next
            case .success(.none):
                return
            case .failure(let error):
                logger.fault("后台队列读取失败，停止消费：\(error.localizedDescription)")
                return
            }
            guard BackgroundTaskQueue.markInProgress(id: entry.id) else {
                logger.fault("无法落盘任务执行标记，停止消费以避免重复执行")
                return
            }
            logger.info("开始后台任务: \(entry.kind.rawValue) \(entry.folderName)")
            let outcome = await execute(
                entry, context: context, recordingVM: recordingVM, quickNoteVM: quickNoteVM
            )
            switch outcome {
            case .done, .targetMissing:
                // 兜底出队（幂等）：ViewModel 埋点通常已在任务结束时出队，
                // 此处覆盖目标确实不存在等未走埋点路径的条目
                guard BackgroundTaskQueue.removeEntry(id: entry.id) else {
                    logger.fault("后台任务已执行但出队未落盘，立即停止以避免再次执行")
                    return
                }
            case .retryable(let code), .blocked(let code):
                // **保留条目** + 指数退避（超上限进失败区，不静默删除），
                // 并继续处理其它已就绪条目（退避窗口内的这条会被 peekFirstReady 跳过）
                _ = BackgroundTaskQueue.clearInProgress()
                guard BackgroundTaskQueue.recordRetryableFailure(id: entry.id, code: code) else {
                    logger.fault("后台任务失败但退避记录未落盘，停止本轮以避免重复执行: \(entry.kind.rawValue) \(entry.folderName)")
                    return
                }
                logger.fault("后台任务失败，已保留并退避重试: \(entry.kind.rawValue) \(entry.folderName) — \(code.rawValue, privacy: .public)")
            }
        }
        if stopFlagExists() {
            logger.info("收到主应用接管请求，守护进程完成当前任务后退出")
        }
    }

    /// 单次后台任务的执行结果：决定条目能否出队。
    private enum TaskOutcome {
        /// 任务已执行，或用户主动取消：可出队
        case done
        /// 目标条目确实已被删除、且无法重跑：可出队（不算失败）
        case targetMissing
        /// 可重试失败（读库错误 / 网络 / 模型等）：保留条目并按指数退避延后重试
        case retryable(code: BackgroundTaskFailureCode)
        /// 配置阻塞（Keychain 不可用 / 未配置密钥等）：保留条目，等用户修复后重试
        case blocked(code: BackgroundTaskFailureCode)
    }

    /// 执行单个队列条目（复用 ViewModel 现有实现，保证行为与前台完全一致）
    @MainActor
    private static func execute(
        _ entry: BackgroundTaskEntry,
        context: ModelContext,
        recordingVM: RecordingViewModel,
        quickNoteVM: QuickNoteViewModel
    ) async -> TaskOutcome {
        switch entry.kind {
        case .transcription:
            guard let snapshot = entry.sttSnapshot else {
                logger.error("转写任务缺少 STT 快照，跳过: \(entry.folderName)")
                return .targetMissing
            }
            // 远端模式读不到密钥时不得以空凭据发起请求（否则被 401 误报成「Key 无效」）
            if let code = BackgroundTaskKeyGuard.blockReason(
                mode: STTMode(rawValue: snapshot.mode) ?? .local,
                keyReadResult: STTConfigSnapshot.readWhisperAPIKeyResult()
            ) {
                logger.fault("转写任务配置阻塞: \(entry.folderName) — \(code.rawValue, privacy: .public)")
                return .blocked(code: code)
            }
            let recording: AudioRecording?
            do {
                recording = try fetchRecording(folderName: entry.folderName, context: context)
            } catch {
                // 读库错误不等于“条目已删除”：不得据此出队，保留条目下次重试
                logger.fault("后台任务查询录音失败（可重试）: \(entry.folderName) — \(error.localizedDescription)")
                return .retryable(code: .databaseReadFailed)
            }
            guard let recording else {
                logger.warning("未找到录音记录，跳过: \(entry.folderName)")
                return .targetMissing
            }
            // 入队幂等：条目已在队列中，startTranscription 内部埋点不会重复入队；
            // 结束时埋点出队，随后 drainQueue 的兜底出队为空操作
            let task = recordingVM.startTranscription(
                recording: recording,
                sttConfig: snapshot.config,
                context: context
            )
            await task.value
            // 转写失败（模型缺失/网络/密钥等）可重试；其余（完成/取消）出队
            if recording.transcriptionStatus == .failed {
                return .retryable(code: .processingFailed)
            }
            return .done

        case .summary:
            let recording: AudioRecording?
            do {
                recording = try fetchRecording(folderName: entry.folderName, context: context)
            } catch {
                logger.fault("后台任务查询录音失败（可重试）: \(entry.folderName) — \(error.localizedDescription)")
                return .retryable(code: .databaseReadFailed)
            }
            guard let recording else {
                logger.warning("未找到录音记录，跳过: \(entry.folderName)")
                return .targetMissing
            }
            let llmConfig: LLMConfig?
            do {
                llmConfig = try fetchLLMConfig(id: entry.llmConfigID, context: context)
            } catch {
                logger.fault("后台任务查询 LLM 配置失败（可重试）: \(error.localizedDescription)")
                return .retryable(code: .databaseReadFailed)
            }
            guard let llmConfig else {
                logger.error("未找到 LLM 配置，保留待重试: \(entry.folderName)")
                return .blocked(code: .missingLLMConfig)
            }
            let task = recordingVM.generateSummary(
                recording: recording,
                llmConfig: llmConfig,
                context: context,
                asMeeting: entry.isMeeting,
                experience: entry.experience
            )
            // 结论由 ViewModel 给出：只有「本次确实产出并持久化」才算完成，
            // 失败按可重试保留（旧实现无条件视为 completed，网络/模型失败被静默出队）
            switch await task.value {
            case .succeeded: return .done
            case .cancelled: return .done
            case .failed:    return .retryable(code: .processingFailed)
            }

        case .quicknoteSummary:
            let note: QuickNote?
            do {
                note = try fetchQuickNote(folderName: entry.folderName, context: context)
            } catch {
                logger.fault("后台任务查询快捷笔记失败（可重试）: \(entry.folderName) — \(error.localizedDescription)")
                return .retryable(code: .databaseReadFailed)
            }
            guard let note else {
                logger.warning("未找到快捷笔记记录，跳过: \(entry.folderName)")
                return .targetMissing
            }
            let llmConfig: LLMConfig?
            do {
                llmConfig = try fetchLLMConfig(id: entry.llmConfigID, context: context)
            } catch {
                logger.fault("后台任务查询 LLM 配置失败（可重试）: \(error.localizedDescription)")
                return .retryable(code: .databaseReadFailed)
            }
            guard let llmConfig else {
                logger.error("未找到 LLM 配置，保留待重试: \(entry.folderName)")
                return .blocked(code: .missingLLMConfig)
            }
            let task = quickNoteVM.generateSummary(
                for: note,
                llmConfig: llmConfig,
                context: context,
                experience: entry.experience
            )
            // 步骤结论由 ViewModel 落库；此处只等待完成（成功/失败/取消都由 VM 内部处理与出队）
            switch await task.value {
            case .succeeded: return .done
            case .cancelled: return .done
            case .failed:    return .retryable(code: .processingFailed)
            }
        }
    }

    /// 查询录音：**抛错表示数据库读取失败（可重试）**，返回 nil 表示条目确实不存在（可出队）。
    /// 旧实现用 `try? context.fetch` 把读错误吞成“找不到条目”，随后仍移除队列任务——
    /// 数据库瞬时故障会静默丢掉任务。
    @MainActor
    private static func fetchRecording(folderName: String, context: ModelContext) throws -> AudioRecording? {
        let descriptor = FetchDescriptor<AudioRecording>(
            predicate: #Predicate { $0.folderName == folderName }
        )
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func fetchQuickNote(folderName: String, context: ModelContext) throws -> QuickNote? {
        let descriptor = FetchDescriptor<QuickNote>(
            predicate: #Predicate { $0.folderName == folderName }
        )
        return try context.fetch(descriptor).first
    }

    /// LLM 配置解析：条目记录的 ID → active_llm_config_id → 第一个配置
    /// （与 SettingsViewModel.getActiveLLMConfig 的回退语义一致）。
    /// 抛错表示数据库读取失败（可重试）；返回 nil 表示确实没有可用配置（可出队）。
    @MainActor
    private static func fetchLLMConfig(id: UUID?, context: ModelContext) throws -> LLMConfig? {
        if let id {
            let descriptor = FetchDescriptor<LLMConfig>(predicate: #Predicate { $0.id == id })
            if let config = try context.fetch(descriptor).first { return config }
        }
        if let idStr = UserDefaults.standard.string(forKey: "active_llm_config_id"),
           let uuid = UUID(uuidString: idStr) {
            let descriptor = FetchDescriptor<LLMConfig>(predicate: #Predicate { $0.id == uuid })
            if let config = try context.fetch(descriptor).first { return config }
        }
        return try context.fetch(FetchDescriptor<LLMConfig>()).first
    }

    /// worker 专用 ModelContainer（与主应用 `StartupModelContainerFactory.makePersistent` 同款 schema/配置）
    private static func makeModelContainer() -> ModelContainer? {
        WhisperModelSourceStore.applyCurrentAsHubEnvironment()
        let schema = Schema([
            AudioRecording.self,
            TranscriptSegment.self,
            LLMConfig.self,
            QuickNote.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try? ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - 主应用侧接口

    /// 退出路径调用：仍有未完成任务或未合并分片且无 worker 存活时，拉起守护进程续跑
    static func spawnIfNeeded() {
        guard !isWorkerRunning() else { return }
        guard BackgroundTaskQueue.hasEntries() || hasUnmergedSegments() else { return }
        guard let exeURL = Bundle.main.executableURL else {
            logger.warning("无法定位可执行文件，守护进程未拉起")
            return
        }
        let process = Process()
        process.executableURL = exeURL
        process.arguments = [launchFlag]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            logger.info("守护进程已拉起 PID=\(process.processIdentifier)")
        } catch {
            logger.error("守护进程拉起失败: \(error.localizedDescription)")
        }
    }

    /// 启动握手第一步：请求后台守护进程合作式停止并等待它让位（阻塞调用）。
    ///
    /// 语义（与旧 `handshakeAndWaitForWorkerExit` 的等待段一致）：
    /// 1. 无存活 worker：清理可能残留的停止标记（上次握手超时让位的场景）后返回 `.noWorker`；
    /// 2. 有存活 worker：写停止标记请求其收尾，轮询等待其退出（宽限 `grace`）；
    /// 3. 宽限内未退出：发 SIGTERM 促退，再等 `terminateWait`；
    /// 4. 仍未退出：返回 `.stillRunning(pid)`。
    ///
    /// 本函数会 sleep（阻塞），必须由调用方放到脱离主线程的执行器（`Task.detached`）执行，
    /// 否则 worker 拒不退出时会让启动期主线程无窗口。
    /// 是否需要放弃接管**不**由本函数决定：唯一判据是能否取得 `DatabaseOwnershipLock`。
    ///
    /// 终止不丢数据：未完成任务仍留在队列里由主应用兜底续跑，分片是崩溃安全容器，
    /// `.merging` 是 PID 化标记（进程已死即过期）。
    static func requestWorkerStop(
        grace: TimeInterval = 3,
        terminateWait: TimeInterval = 2
    ) -> WorkerStopOutcome {
        guard let pid = liveWorkerPID() else {
            // 无 worker 存活：仍要抢锁——worker 可能刚崩溃/正在退出，
            // 锁要等进程真正结束才由内核释放（由调用方随后以锁为判据判断）
            try? FileManager.default.removeItem(at: stopFileURL)
            return .noWorker
        }
        logger.info("检测到守护进程 PID=\(pid)，请求其收尾退出并等待接管（宽限 \(Int(grace))s）")
        FileManager.default.createFile(atPath: stopFileURL.path, contents: nil)

        if waitForProcessExit(pid: pid, timeout: grace) {
            logger.info("守护进程已在宽限内退出")
            return .exitedDuringGrace
        }

        logger.warning("守护进程宽限内未退出（可能正在跑长任务），请求其终止以交接")
        kill(pid, SIGTERM)
        if waitForProcessExit(pid: pid, timeout: terminateWait) {
            logger.info("守护进程已终止并退出（未完成任务由队列兜底续跑）")
            return .exitedAfterTermination
        }

        logger.fault("守护进程 PID=\(pid) 拒绝退出，等待数据库独占锁释放")
        return .stillRunning(pid: pid)
    }

    /// 轮询等待进程退出（有界）；到点仍未退出返回 false
    private static func waitForProcessExit(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !isProcessAlive(pid: pid)
    }

    /// 启动握手（同步便捷入口）：请求 worker 让位后取得数据库独占锁。
    ///
    /// 以「能否拿到数据库独占锁」作为**唯一**的接管判据（见 `DatabaseOwnershipLock`）：
    /// 旧实现只要 PID 消失就认为接管成功，SIGTERM 无响应时照样打开数据库 ——
    /// 两个进程同时写同一个 SQLite 文件会损坏数据库。
    ///
    /// - Note: 新启动流程（`StartupCoordinator`）把等待与取锁拆成两步并在后台执行；
    ///   本函数保留为同步等价入口（阻塞调用，不得在主线程直接调用）。
    /// - Returns: true = 已取得独占权，可打开可写容器；false = 未取得，调用方**不得**打开可写容器
    @discardableResult
    static func handshakeAndWaitForWorkerExit(grace: TimeInterval = 3, terminateWait: TimeInterval = 2) -> Bool {
        _ = requestWorkerStop(grace: grace, terminateWait: terminateWait)
        guard DatabaseOwnershipLock.acquire(timeout: 1) else {
            logger.fault("未取得数据库独占锁，主应用不打开可写容器")
            return false
        }
        logger.info("取得数据库独占锁，主应用接管")
        finishHandshake()
        return true
    }

    /// 握手收尾：清理本次使用的交接文件（worker 未来得及自清时的兜底）
    private static func finishHandshake() {
        try? FileManager.default.removeItem(at: stopFileURL)
        try? FileManager.default.removeItem(at: pidFileURL)
    }
}

// MARK: - 数据库所有权锁

/// 数据库所有权锁：以 `flock` 表达「谁可以打开可写 SQLite」。
///
/// 旧实现只靠 PID 文件 + 停止标记协调，两端都可能判断错：
/// - 主应用等待超时（worker 不响应 SIGTERM）后照样打开数据库 → 两进程同写同一个库；
/// - worker 启动时（主应用刚发出退出意图、可能还在收尾）也直接开库 → 同样可能重叠。
///
/// `flock` 由内核持有，进程正常退出或崩溃都会自动释放，比 PID 文件可靠；
/// 因此它既能表达「独占」，也能安全地用来**等待**对方让位（轮询即可，不需要信号）。
/// 进程内只持有一把锁：fd 记录在静态变量中长期保持打开，直到进程结束。
enum DatabaseOwnershipLock {

    private static let logger = Logger(subsystem: "app.memozia", category: "DatabaseLock")
    private static let stateLock = NSLock()

    /// 锁文件与数据库同目录：两端都经 AudioRecording.storageDirectory 定位（存储目录可配置）。
    /// internal：供 RuntimeVerification 的 --print-db-lock-path 打印同一路径（单一事实源）
    static var lockFileURL: URL {
        AudioRecording.storageDirectory.appendingPathComponent(".db_ownership.lock")
    }

    /// 已持有的锁文件描述符；必须保持打开，关闭即释放锁。
    ///
    /// `nonisolated(unsafe)`：Swift 6 视可变全局状态为不安全，但这里所有读写都在
    /// `stateLock` 保护下（见 tryAcquire/isHeld），且该 fd 的生命周期与进程一致
    /// （刻意不关闭：关闭即释放锁，锁要一直持有到进程结束）
    nonisolated(unsafe) private static var heldDescriptor: Int32?

    /// 是否已持有数据库独占锁（主应用据此决定能否打开可写容器）
    static var isHeld: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return heldDescriptor != nil
    }

    /// 取得锁失败的原因。旧实现只有 Bool，启动流程把两种情况合并成"被后台进程占用"，
    /// 锁文件根本建不出来（磁盘满/权限/存储目录不可写）时会把用户引向错误排查方向
    enum AcquireFailure: Sendable {
        /// 被其他进程持有（等它退出即可）
        case heldByOtherProcess
        /// 锁文件无法创建/打开（磁盘满、权限、存储目录不可写）
        case lockFileUnavailable(errno: Int32)
    }

    /// 最近一次取得锁失败的原因；nil 表示确实持有锁。读写都在 stateLock 保护下
    nonisolated(unsafe) private static var lastFailure: AcquireFailure?

    /// 最近一次取得锁失败的原因（供启动流程给出准确提示）
    static var lastFailureReason: AcquireFailure? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastFailure
    }

    /// 尝试非阻塞取得独占锁（成功即长期持有）
    private static func tryAcquire() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if heldDescriptor != nil { return true }
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // errno 必须在任何可能覆写它的调用（如 logger）之前取出
            let code = errno
            logger.error("数据库锁文件打开失败（\(lockFileURL.path)），errno=\(code)")
            lastFailure = .lockFileUnavailable(errno: code)
            return false
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            heldDescriptor = fd
            lastFailure = nil
            return true
        }
        close(fd)
        lastFailure = .heldByOtherProcess
        return false
    }

    /// 在 timeout 内轮询等待独占锁（对方正在退出时使用）
    /// - Returns: 是否取得；取得后由本进程持有，直到进程结束
    static func acquire(timeout: TimeInterval, pollInterval: TimeInterval = 0.2) -> Bool {
        if tryAcquire() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            if tryAcquire() { return true }
        }
        return tryAcquire()
    }
}
