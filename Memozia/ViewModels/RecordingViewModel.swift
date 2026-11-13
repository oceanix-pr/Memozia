import Foundation
import SwiftData
import Observation
#if canImport(Metal)
import Metal
#endif


/// 录音业务逻辑 ViewModel
@MainActor
@Observable
final class RecordingViewModel {

    var selectedRecording: AudioRecording? {
        didSet {
            // 切换选中录音时清空撤销栈，避免撤销操作作用到另一条录音的片段
            if selectedRecording?.id != oldValue?.id {
                editUndoStack.removeAll()
                // 切换条目时按新条目恢复「进行中态 + 流式内容」：后台正在跑的另一条目
                // 不得把它的总结/进行中态显示到当前条目上
                syncSummaryDisplayForSelection()
            }
        }
    }
    var isImporting = false
    var importProgressText: String?
    var isTranscribing = false
    /// 文字转写进度状态（合并进度条的前半程）。
    /// `didSet` 顺带把真实窗口进度喂给估计器并刷新合并值——窗口进度是本阶段唯一的真实信号
    var transcriptionProgress = ProcessingProgressStatus.idle {
        didSet {
            if let fraction = transcriptionProgress.fraction {
                progressEstimator?.reportFraction(Double(fraction))
            }
            refreshMergedProgress()
        }
    }
    /// 说话人区分进度状态；未开启说话人区分时停在 `.idle`（估计器据此决定是否计入该段）
    var diarizationProgress = ProcessingProgressStatus.idle {
        didSet { refreshMergedProgress() }
    }
    /// 两条流水线都结束后的公共阶段文案（如“正在合并并保存…”）
    var transcriptMergeStage = ""

    // MARK: - 单条进度条（转写 + 说话人区分合并展示）

    /// 处理中视图那一条进度条的 0...1 值，由 `TranscriptionProgressEstimator` 推进：
    /// 事前按音频时长估算两段耗时（RTF × 时长）定占比，段内优先用真实窗口进度，
    /// 没有回调的段（分离核心推理、云端上传）按时间蠕动。
    /// 存成可观察属性而非计算属性：蠕动需要定时写入才能驱动 @Observable 刷新
    private(set) var mergedTranscriptionProgress: Float = 0

    /// 本次转写的进度估计器；未开始转写时为 nil（纯内部状态，不参与观察）
    @ObservationIgnored private var progressEstimator: TranscriptionProgressEstimator?
    /// 蠕动节拍：没有回调的阶段只能按时间推进，靠它定期写入可观察值
    @ObservationIgnored private var progressTicker: Task<Void, Never>?

    /// 单条进度条上的阶段文案（为空时视图回退到“正在转写中...”）
    var mergedTranscriptionStage: String {
        Self.mergedStageText(
            transcription: transcriptionProgress,
            diarization: diarizationProgress,
            mergeStage: transcriptMergeStage
        )
    }

    /// 阶段文案选择：优先「正在跑的那条」，两条都结束后用合并态文案。
    /// 转写进行中时不显示分离行的「等待文字转写完成…」，否则与进度条位置自相矛盾
    nonisolated static func mergedStageText(
        transcription: ProcessingProgressStatus,
        diarization: ProcessingProgressStatus,
        mergeStage: String
    ) -> String {
        if transcription.isActive { return transcription.detail }
        if diarization.isActive { return diarization.detail }
        return mergeStage
    }

    /// 把估计器当前值写入可观察属性（事件与蠕动节拍都走这里）
    private func refreshMergedProgress() {
        guard let progressEstimator else { return }
        mergedTranscriptionProgress = Float(progressEstimator.progress())
    }

    /// 启动蠕动节拍。没有它，分离核心推理与云端上传期间没有任何状态变化，
    /// 进度条会整段静止（看起来像卡死）
    private func startProgressTicker() {
        progressTicker?.cancel()
        progressTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshMergedProgress()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopProgressTicker() {
        progressTicker?.cancel()
        progressTicker = nil
    }

    /// 把本次实测耗时写回 RTF 基线（首个样本即采用实测值，之后 EMA），并打一条标定日志。
    /// 只在转写真正跑完时写入：中断/失败的运行会污染基线
    private func recordTranscriptionTiming(
        mode: STTMode,
        modelPath: String,
        audioSeconds: Double
    ) {
        guard let sample = progressEstimator?.calibrationSample() else { return }
        let key = TranscriptionRTFStore.transcriptionKey(mode: mode, modelPath: modelPath)
        let table = TranscriptionRTFStore.shared.record(
            key: key,
            transcriptionSeconds: sample.transcriptionSeconds,
            diarizationSeconds: sample.diarizationSeconds,
            audioSeconds: audioSeconds
        )
        TranscriptionPerfLog.report(
            mode: mode,
            modelName: URL(fileURLWithPath: modelPath).lastPathComponent,
            audioSeconds: audioSeconds,
            transcriptionSeconds: sample.transcriptionSeconds,
            diarizationSeconds: sample.diarizationSeconds,
            profile: table.profile(for: key)
        )
    }

    /// 转写内容版本号：任何片段写路径递增，驱动详情页缓存失效与重建
    private(set) var transcriptVersion = 0
    var isSummarizing = false
    var summaryText = ""
    /// 流式「思考过程」（推理型模型的 reasoning_content）：仅供展示与诊断，
    /// 不写入总结、不入库；为空表示当前模型/服务端没有回传思考内容
    var summaryReasoningText = ""

    /// 画面要点（视频关键帧视觉纪要）是否生成中
    var isGeneratingVisualNotes = false
    /// 进行中的画面要点所属条目文件夹名：全局进行中态必须绑定到具体条目，
    /// 否则切到别的录屏会看到上一条目的进度与文本（跨条目串数据）
    private(set) var visualNotesRecordingFolderName: String?
    /// 流式中的画面要点文本
    var visualNotesText = ""
    /// 流式「思考过程」（推理型模型的 reasoning_content）：仅生成期间展示与诊断，不入库；
    /// 本地视觉模型路径显式关闭思考（reasoning_effort=none），因此本地通常为空
    var visualNotesReasoningText = ""
    /// 流式分段的当前序号（1 起）与总段数：仅供折叠 label 展示进度，不参与结果
    var visualNotesSegmentIndex = 0
    var visualNotesSegmentTotal = 0
    /// 抽帧/请求进度（0...1）：逐帧抽取天然有粒度，比“只转圈”更可信
    var visualNotesProgress: Double = 0
    /// 「清理视频」进行中：仅用于禁用按钮防重复点击（unlink 本身很快）
    var isCleaningUpVideo: Bool { MediaCleanupService.shared.isRunning }
    /// 当前时间分段的起始字符下标：长视频按时间分多段流式追加，
    /// 段内重试只能回退本段已吐的 token，不能清掉前面段已完成的要点
    private var visualSegmentStartOffset = 0
    var errorMessage: String?
    var showError = false

    /// 临时模式只读门控：由 RootView 在启动时注入；默认 readWrite（单测/未注入路径保持可写）
    @ObservationIgnored
    var persistence: PersistenceGuard = .readWrite

    /// 临时模式门控：只读时给出统一提示并返回 true（调用方应立即 return）
    private func rejectWriteIfReadOnly(_ operation: PersistenceOperation) -> Bool {
        guard let blocked = persistence.rejection(for: operation) else { return false }
        showErrorMessage(blocked.message)
        return true
    }

    // 待办相关状态
    var isExtractingTodos = false
    private var todoExtractionProgress: [UUID: TodoExtractionService.Progress] = [:]
    var todoExtractionProgressText: String {
        selectedRecording.flatMap { todoExtractionProgress[$0.id] }?.text ?? String(localized: "AI 拆解中...")
    }
    /// 当前展示的待办文档（按 recording.id 缓存，切换录音时重载）
    var currentTodoDocument: TodoDocument?
    var isWritingTodos = false

    /// F-3: 录音停止后音频合并进行中（用于 UI 反馈合并进度）
    var isMergingAudio = false

    // MARK: - 停录收尾进度（转发 MeetingRecorderService 的可观察状态）
    //
    // 收尾拆成「检查分片 → 回声消除 → 混音导出 → 保存」四阶段；UI 据此显示
    // 当前在做什么、回声消除进度与耗时，并仅对可安全取消的回声消除阶段提供取消入口。

    /// 当前收尾阶段
    var mergePhase: MeetingRecorderService.MergePhase { meetingRecorder.mergePhase }
    /// 回声消除进度：已完成 / 配对总数
    var mergeProgressCompleted: Int { meetingRecorder.mergeProgressCompleted }
    var mergeProgressTotal: Int { meetingRecorder.mergeProgressTotal }
    /// 当前阶段开始时刻（供 UI 显示已耗时）
    var mergeStageStartedAt: Date? { meetingRecorder.mergeStageStartedAt }
    /// 回声消除阶段是否可取消
    var canCancelEchoReduction: Bool { meetingRecorder.canCancelEchoReduction }
    /// 请求取消回声消除阶段（取消后回退原始音轨，不影响录音入库）
    func cancelEchoReduction() { meetingRecorder.requestCancelEchoReduction() }

    /// 停止流程重入保护：磁盘临界止损回调与用户点击可能在同一次停止尚未结束时
    /// 再次触发 stopMeetingRecording。第二次调用的 defer 会清空 onRecordingWarning /
    /// onRequestStopForDiskPressure 等回调，而第一路的合并仍在进行，导致告警与止损被吞
    private var isStoppingRecording = false

    /// 转写镜像写入的串行队列：主线程只做 Sendable 快照，逐段 AES-GCM 解密与提交
    /// 放到这里顺序执行。必须串行——`EntryMirrorStore` 的「最新一份胜出」按提交世代
    /// 判定，若解密耗时不同导致提交乱序，旧内容会被当成最新写盘
    private let transcriptMirrorQueue = DispatchQueue(
        label: "app.memozia.transcriptMirror",
        qos: .utility
    )

    /// 当前采集问题常驻横幅；恢复与保存结果使用非模态一次性反馈。
    var liveRecordingWarning: String?
    var recordingFailureFolder: URL?
    var recordingFeedback: RecordingFeedback?
    var captureReportRequestedFolder: String?
    private var lastRecoveredFeedback: String?

    private var transcriptionTask: Task<Void, Never>?
    /// 正在转写的目标。取消时要**立刻**回写条目状态并出队：
    /// 转写中有「无法即时中断」的窗口（WhisperKit 的协作标志要等下个窗口边界，
    /// 分离的 native process 更是完全不可中断），不能等那段调用返回再收尾
    @ObservationIgnored
    private var activeTranscriptionTarget: (folderName: String, recording: AudioRecording)?
    /// 转写任务代次：每次发起转写递增。任务收尾时用它判定自己是否已被更新的任务取代
    /// （旧任务的 defer 不得改动新任务的共享状态，也不得按「类型+文件夹」出队新任务的队列项）
    private var transcriptionGeneration = 0

    // 按条目 UUID 分字典管理执行句柄：不同条目的同类任务互相独立，
    // 新任务只取消「同一条目」的上一次任务，不会误伤其它条目正在跑的任务。
    @ObservationIgnored private var summaryTasks: [UUID: Task<StepOutcome, Never>] = [:]
    @ObservationIgnored private var titleTasks: [UUID: Task<StepOutcome, Never>] = [:]
    @ObservationIgnored private var todoExtractionTasks: [UUID: Task<StepOutcome, Never>] = [:]
    /// 每个条目的总结执行令牌：旧任务的收尾据此判定是否已被新执行取代
    @ObservationIgnored private var summaryExecutions: [UUID: UUID] = [:]
    @ObservationIgnored private var titleExecutions: [UUID: UUID] = [:]
    @ObservationIgnored private var todoExtractionExecutions: [UUID: UUID] = [:]
    /// 正在拆解待办的条目集合（供切条目时恢复「进行中」态）
    @ObservationIgnored private var extractingTodoIDs: Set<UUID> = []

    private var visualNotesTask: Task<StepOutcome, Never>?
    /// 画面分析第一步（本地抽帧）专属任务：需把帧数回传给视图层弹确认，
    /// 不能复用 Void 型的 visualNotesTask；与要点任务同受 cancelVisualNotes 取消
    private var visualExtractionTask: Task<Int?, Never>?
    /// 画面要点任务代次：每次抽帧/分析递增。任务收尾用它判定自己是否已被更新的任务取代，
    /// 避免旧任务的 defer 复位新任务的进行中态与进行中条目
    private var visualNotesGeneration = 0
    /// 画面分析「意外中断」的自动续跑次数上限。
    ///
    /// 用户点「停止」、删除条目、或被新任务顶替时都会**先递增** `visualNotesGeneration`
    /// （见 `cancelVisualNotes` 与两个 start 入口）；因此收尾时 `generation` 仍等于自己
    /// ⇒ 这次取消没有任何发起方（宿主/运行期导致，如视图或宿主窗口被重建时的连带取消）。
    /// 这种取消以前被 `catch is CancellationError` 静默吞掉，随后 defer 复位进行中态，
    /// 用户看到的就是「分析莫名其妙中断、又变回未分析」。
    /// 检查点只会重发未完成的段，续跑成本低，故给一次自愈机会；再失败就明确告知用户
    private static let visualNotesMaxAutoResumes = 1

    private let whisperLocalService = WhisperLocalService.shared

    // MARK: - 导入录音

    func importAudio(from sourceURL: URL, context: ModelContext) async {
        guard !AppUpdateService.shared.isPreparingToInstall else {
            errorMessage = String(localized: "请稍后重试更新。")
            showError = true
            return
        }
        guard !rejectWriteIfReadOnly(.importMedia) else { return }
        isImporting = true
        defer { isImporting = false }
        var createdFolderURL: URL?
        var insertedRecording: AudioRecording?

        do {
            let ext = sourceURL.pathExtension.lowercased()
            let isVideo = AudioConverter.videoExtensions.contains(ext)
            guard isVideo || AudioConverter.supportedExtensions.contains(ext) else {
                throw ImportError.unsupportedFormat(ext)
            }

            // 统一存到 ~/Documents/Memozia/yyyyMMddHHmmss/ 子文件夹
            // 原子创建独占文件夹名：并发导入同一秒不会共用目录（旧「先查后建」会）
            let now = Date()
            let baseName = AudioRecording.fileName(from: now)
            guard let folderName = AudioRecording.createUniqueFolder(from: now) else {
                throw ImportError.folderCreationFailed
            }
            let folderDir = AudioRecording.resolveFolderURL(forFolderName: folderName)
            createdFolderURL = folderDir

            let storedFileName: String
            let storedExtension: String
            let videoFileName: String?
            let duration: TimeInterval

            if isVideo {
                // 视频导入是「原件复制 + 抽出音轨 m4a」两份占用，GB 级素材先做磁盘预检
                // （与录音 D-1 预检同一风格）：宁可清掉刚建的空文件夹也不写半条记录。
                // 探测与复制一样放在独立 I/O 执行器，慢速外置盘不阻塞主线程
                let sourceBytes = await AudioConverter.fileSize(of: sourceURL)
                let freeBytes = await AudioConverter.availableDiskBytes(at: folderDir)
                let requiredBytes = sourceBytes + 500 * 1024 * 1024
                if let freeBytes, freeBytes < requiredBytes {
                    try? FileManager.default.removeItem(at: folderDir)
                    throw ImportError.insufficientDiskSpace(freeBytes: freeBytes, requiredBytes: requiredBytes)
                }

                // 视频不做“直接丢给转写”：WhisperKit 吃 mp4/mov 未经验证，Whisper API
                // 又按扩展名定 MIME 且有 25MB 上限。先抽成音轨 m4a 作为录音媒体，
                // 原始视频以 `_video` 后缀同文件夹留存（后续画面理解、回放都靠它）
                let retainedVideoName = AudioConverter.retainedVideoName(base: baseName, ext: ext)
                let videoURL = folderDir.appendingPathComponent(retainedVideoName)
                // 大文件复制走独立 I/O 执行器（分块 + 可取消），GB 级视频/跨磁盘不再卡主线程
                try await AudioConverter.copyFileOffMain(from: sourceURL, to: videoURL)

                let audioURL = folderDir.appendingPathComponent("\(baseName).m4a")
                do {
                    _ = try await AudioConverter.extractAudioTrack(from: videoURL, to: audioURL)
                } catch {
                    // 抽轨失败：连原始视频一起回滚，不留「有视频无音轨」的半条记录
                    // （否则磁盘扫描会把它当成可处理录音反复探测，列表中又是一条无法转写的条目）
                    try? FileManager.default.removeItem(at: folderDir)
                    throw error
                }

                storedFileName = "\(baseName).m4a"
                storedExtension = "m4a"
                videoFileName = retainedVideoName
                duration = (try? await AudioConverter.getDuration(of: audioURL)) ?? 0
            } else {
                let name = "\(baseName).\(ext)"
                let destinationURL = folderDir.appendingPathComponent(name)
                // 大文件复制走独立 I/O 执行器（分块 + 可取消）
                try await AudioConverter.copyFileOffMain(from: sourceURL, to: destinationURL)

                storedFileName = name
                storedExtension = ext
                videoFileName = nil
                duration = (try? await AudioConverter.getDuration(of: destinationURL)) ?? 0
            }

            let recording = AudioRecording(
                fileName: sourceURL.deletingPathExtension().lastPathComponent,
                fileExtension: storedExtension,
                duration: duration,
                storedFileName: storedFileName,
                folderName: folderName,
                videoFileName: videoFileName
            )

            context.insert(recording)
            insertedRecording = recording
            // 文件系统是权威源：meta 落盘失败时不提交数据库半条记录。
            guard recording.saveMetaToFolder() else { throw ImportError.metadataWriteFailed }
            try context.save()
            createdFolderURL = nil
            insertedRecording = nil
            selectedRecording = recording

        } catch is CancellationError {
            // 用户取消导入：静默清理半成品（不弹“导入失败”），复制已在分块循环里清理目标
            if let insertedRecording { context.delete(insertedRecording) }
            if let createdFolderURL { try? FileManager.default.removeItem(at: createdFolderURL) }
        } catch {
            if let insertedRecording { context.delete(insertedRecording) }
            if let createdFolderURL { try? FileManager.default.removeItem(at: createdFolderURL) }
            showErrorMessage(String(localized: "导入失败：\(UserFacingError.summary(for: error))"))
        }
    }

    // MARK: - 转写（支持取消）

    func startTranscription(
        recording: AudioRecording,
        sttConfig: STTConfig,
        context: ModelContext
    ) -> Task<Void, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task {} }
        transcriptionTask?.cancel()
        // 递增代次：本次任务拥有唯一代次；旧任务的收尾逻辑据此判定自己已过期，
        // 不得提交结果、不得改动共享状态、也不得按「类型+文件夹」出队（会误清新任务的队列项）
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        let recordingID = recording.id
        // 后台任务队列埋点：用户发起转写时入队（快照 STT 配置，幂等），
        // 主应用退出后守护进程据此续跑；所有结束路径（完成/失败/取消）在 defer 出队
        if !BackgroundTaskQueue.enqueue(BackgroundTaskEntry(
            kind: .transcription,
            folderName: recording.folderName,
            sttSnapshot: STTConfigSnapshot(config: sttConfig)
        )) {
            // 入队未落盘：前台仍可继续，但退出后无法续跑；明确告知而不是静默
            showErrorMessage(String(localized: "任务已在前台开始，但未能写入后台续跑队列；请保持应用开启完成本次任务，退出后需重新发起。"))
        }

        let task = Task { @MainActor in
            isTranscribing = true
            recording.transcriptionStatus = .processing
            activeTranscriptionTarget = (recording.folderName, recording)
            let wantsDiarization = sttConfig.enableSpeakerDiarization
            transcriptionProgress = ProcessingProgressStatus(
                phase: .preparing,
                detail: String(localized: "正在准备…")
            )
            diarizationProgress = wantsDiarization
                ? ProcessingProgressStatus(
                    phase: .preparing,
                    detail: String(localized: "等待文字转写完成…")
                )
                : .idle
            transcriptMergeStage = ""
            defer {
                // 过期任务（已被更新的任务取代）：不得改动新任务的共享状态，
                // 也不得按「类型+文件夹」出队——那会清掉新任务刚入队的队列项。
                // 用 if 收尾而非 guard-return：defer 内不允许 return 跳出
                if self.transcriptionGeneration == generation {
                    isTranscribing = false
                    transcriptMergeStage = ""
                    stopProgressTicker()
                    activeTranscriptionTarget = nil
                    PersistenceReporting.saveOrReport { try context.save() }
                    BackgroundTaskQueue.dequeue(kind: .transcription, folderName: recording.folderName)
                }
            }

            do {
                try Task.checkCancellation()

                let audioURL = recording.fileURL
                try Task.checkCancellation()
                // 音频输入预检：文件缺失/损坏时快速失败，避免引擎层抛出不明确的错误。
                // 时长同时用于进度估算（RTF × 时长）
                let audioSeconds = try await Self.validateAudioInput(at: audioURL)

                // 进度估计器：起点取基线表（按模式 + 本地模型目录名分桶），
                // 首个样本即采用实测值，之后 EMA 收敛到本机真实速度
                let rtfKey = TranscriptionRTFStore.transcriptionKey(
                    mode: sttConfig.mode,
                    modelPath: sttConfig.modelPath
                )
                progressEstimator = TranscriptionProgressEstimator(
                    audioSeconds: audioSeconds,
                    diarizationEnabled: wantsDiarization,
                    profile: TranscriptionRTFStore.shared.profile(for: rtfKey)
                )
                refreshMergedProgress()
                startProgressTicker()

                // 语言码送入引擎前映射为 Whisper 认识的代码（zh-Yue → yue）；
                // 下方繁简归一化仍使用原始设置值，不受映射影响
                let lang = sttConfig.language.isEmpty
                    ? nil
                    : STTConfig.whisperLanguageCode(sttConfig.language)

                // 文字转写与说话人区分改为**串行**：转写跑完再做分离。
                // 二者都只读同一音频文件、本无数据依赖，但并行时会互相争抢 CPU/内存带宽：
                // 转写走 CoreML（ANE/GPU），分离是 ONNX 纯 CPU 推理，同时跑会让两侧都变慢，
                // 长录音还会叠加内存峰值。串行后分离阶段可独享 CPU 线程，总耗时通常更短。
                // 界面上两条流水线合并为一条进度条（见 `mergedProgress`）：分离阶段排在转写之后。
                let engineResults = try await runTranscriptionEngine(
                    sttConfig: sttConfig,
                    audioURL: audioURL,
                    language: lang
                )
                // 转写段结束：进度钉在转写段末尾，后半程交给分离段的时间蠕动
                progressEstimator?.finish(.transcription)
                try Task.checkCancellation()
                let analysis = await runSpeakerAnalysis(
                    sttConfig: sttConfig,
                    audioURL: audioURL,
                    enabled: wantsDiarization
                )

                // 说话人区分已跑完时收口状态（未开启/已跳过/失败时 runSpeakerAnalysis 已自行写入）
                if wantsDiarization, diarizationProgress.phase == .running {
                    diarizationProgress = analysis.segments.isEmpty
                        ? ProcessingProgressStatus(
                            phase: .skipped,
                            detail: String(localized: "本次未标注说话人")
                        )
                        : ProcessingProgressStatus(
                            phase: .completed,
                            fraction: 1,
                            detail: String(localized: "已完成")
                        )
                }
                // 分离段收口：拿到片段才算真跑完，跑空片段等价于本次未做分离，进度直接收到 100%
                if wantsDiarization, !analysis.segments.isEmpty {
                    progressEstimator?.finish(.diarization)
                } else {
                    progressEstimator?.abort(.diarization)
                }
                refreshMergedProgress()
                // 实测耗时回写 RTF 基线并打标定日志（只有完整跑完才写，见方法注释）
                recordTranscriptionTiming(
                    mode: sttConfig.mode,
                    modelPath: sttConfig.modelPath,
                    audioSeconds: audioSeconds
                )

                try Task.checkCancellation()
                transcriptMergeStage = String(localized: "正在合并并保存…")

                // 中文场景下做繁简归一化：简体→繁转简，繁体→简转繁（送入后台加工前先取好参数）
                let targetLanguage = sttConfig.language
                let needsChineseConversion = (targetLanguage == WhisperLanguage.zh.rawValue)
                    || (targetLanguage == WhisperLanguage.zhYue.rawValue)
                let enableDictionaryCorrection = sttConfig.enableDictionaryCorrection

                // 结果先在后台完整准备（贴说话人标签、繁简归一化、词典纠正、逐段加密），
                // **期间不删除、不触碰现有片段**：只有确认可以提交时才替换旧片段。
                // 取消通过 withTaskCancellationHandler 传给这份 detached 加工
                //（detached 不继承取消，故用受锁保护的标志逐段检查，尽快让出）
                let cancelled = LockedBox(false)
                let prepared: [(start: TimeInterval, end: TimeInterval, speaker: String?, encrypted: String)]? =
                    await withTaskCancellationHandler {
                        await Task.detached(priority: .userInitiated) { () -> [(start: TimeInterval, end: TimeInterval, speaker: String?, encrypted: String)]? in
                            let labeled = SpeakerDiarizationService.shared.applySpeakerAnalysis(
                                analysis, to: engineResults
                            )
                            var out: [(start: TimeInterval, end: TimeInterval, speaker: String?, encrypted: String)] = []
                            out.reserveCapacity(labeled.count)
                            for result in labeled {
                                if cancelled.value { return nil }
                                var plainText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if needsChineseConversion {
                                    plainText = await ChineseConverterService.shared.convert(plainText, to: targetLanguage)
                                }
                                // 语音解析词典纠正：拼音匹配替换术语误写（繁简归一化之后执行，
                                // 保证词典术语书写体系与归一化后的文本一致）
                                if enableDictionaryCorrection {
                                    plainText = await TranscriptDictionaryService.shared.correct(plainText)
                                }
                                let encryptedText: String
                                do {
                                    encryptedText = try EncryptionService.encrypt(plainText)
                                } catch {
                                    EncryptionService.reportEncryptionFailure(error, context: "转写片段")
                                    encryptedText = plainText
                                }
                                out.append((result.startTime, result.endTime, result.speaker, encryptedText))
                            }
                            return out
                        }.value
                    } onCancel: {
                        cancelled.value = true
                    }

                guard let prepared else { throw CancellationError() }

                // 提交前重新校验：取消 / 已被更新的任务取代 / 条目已被删除 一律不提交，
                // 避免「正在合并并保存」期间取消或删除条目后，旧结果仍覆盖旧转写
                try Task.checkCancellation()
                guard isTranscriptionCommitValid(generation: generation, recordingID: recordingID, context: context) else {
                    transcriptMergeStage = ""
                    return
                }

                // 确认可提交后才替换旧片段
                recording.segments.forEach { context.delete($0) }

                var newSegments: [TranscriptSegment] = []
                newSegments.reserveCapacity(prepared.count)
                for item in prepared {
                    let seg = TranscriptSegment(
                        startTime: item.start,
                        endTime: item.end,
                        speaker: item.speaker,
                        text: item.encrypted
                    )
                    seg.recording = recording
                    context.insert(seg)
                    newSegments.append(seg)
                }
                recording.segments = newSegments

                recording.transcriptionStatus = .completed
                recording.errorMessage = nil
                transcriptionProgress = ProcessingProgressStatus(
                    phase: .completed,
                    fraction: 1,
                    detail: String(localized: "已完成")
                )
                // 转写内容已变化，持久化的会议判定失效（下次总结按规则重判）
                recording.isMeeting = nil
                recording.meetingJudgedBy = nil
                recording.meetingJudgedAt = nil
                invalidateTranscriptCache(recording)
                try context.save()

                // 将转写记录保存到文件夹
                saveTranscriptToFolder(recording)

            } catch is CancellationError {
                guard isTranscriptionCommitValid(generation: generation, recordingID: recordingID, context: context) else { return }
                recording.transcriptionStatus = .pending
                transcriptionProgress = .idle
                diarizationProgress = .idle
            } catch {
                guard isTranscriptionCommitValid(generation: generation, recordingID: recordingID, context: context) else { return }
                recording.transcriptionStatus = .failed
                let userMessage = UserFacingError.summary(for: error)
                transcriptionProgress = ProcessingProgressStatus(
                    phase: .failed,
                    detail: userMessage
                )
                recording.errorMessage = userMessage
                showErrorMessage(String(localized: "转写失败：\(userMessage)"))
            }
        }
        transcriptionTask = task
        return task
    }

    /// 取消当前转写。
    ///
    /// 为什么不能只发 `task.cancel()`：转写的两段都有「无法即时中断」的窗口——
    /// WhisperKit 靠协作标志（`cancelActiveTranscription`）在下个窗口边界才停，
    /// 而分离的 `diarization.process()` 是单次 native 调用、根本不能中途取消
    /// （见 `SpeakerDiarizationService.diarizeWithSamples` 的注释）。
    /// 只发 cancel 时界面会一直停在「处理中」，用户点取消看不到任何变化，
    /// 直到那段阻塞调用自己返回——这就是「点了取消不管用」的观感来源。
    ///
    /// 所以这里分两步：先**立即**收口界面与会话状态（用户视角即时生效），
    /// 阻塞中的那一路在后台自行结束；它的结果不会再被采纳——
    /// 提交前的 `Task.checkCancellation()` 与脱敏/合并阶段的取消标志都会拦住它。
    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        // 外部取消标志：转写进度回调未必运行在任务上下文，Task.cancel 之外的兜底
        whisperLocalService.cancelActiveTranscription()

        // —— 立即收口（不等阻塞调用返回）——
        stopProgressTicker()
        progressEstimator = nil
        isTranscribing = false
        transcriptMergeStage = ""
        transcriptionProgress = .idle
        diarizationProgress = .idle
        mergedTranscriptionProgress = 0
        if let target = activeTranscriptionTarget,
           !target.recording.isDeleted,
           target.recording.transcriptionStatus == .processing {
            target.recording.transcriptionStatus = .pending
            // 被取消的任务不得留在后台队列里：否则主应用退出后守护进程会把它接着跑完
            //（任务自身的 defer 可能还卡在上面那段 native 调用里，迟迟执行不到）
            BackgroundTaskQueue.dequeue(kind: .transcription, folderName: target.folderName)
        }
        activeTranscriptionTarget = nil
    }

    /// 转写结果提交前校验：任务未被更新的任务取代，且目标条目仍存在于数据库。
    /// 供「结果已在后台加工完成、准备写库」与失败/取消状态回写前调用；
    /// 数据库读取失败也判为不可提交（宁可丢弃本次结果，也不在半失效状态下覆盖旧转写）。
    private func isTranscriptionCommitValid(generation: Int, recordingID: UUID, context: ModelContext) -> Bool {
        guard transcriptionGeneration == generation else { return false }
        // 只判存在性：用 fetchCount 而非 fetch，避免把整行（含总结/转写大文本列）物化出来。
        // （FileSyncService 的磁盘对账走批量版本 persistedFolderNames，逐条查询在 10k 条目下过贵）
        let descriptor = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == recordingID })
        guard let count = try? context.fetchCount(descriptor) else { return false }
        return count > 0
    }

    /// 单文件文字转写流水线：按模式分流。
    ///
    /// 三个引擎统一只报**原始 0...1 进度**，区间映射不再在引擎与 ViewModel 之间重复叠加：
    /// - 本地 WhisperKit：窗口数占比
    /// - 系统语音识别：已识别片段结束时间 ÷ 音频时长
    /// - 云端 Whisper API：无进度回调，`fraction` 保持 nil（UI 显示不定进度）
    private func runTranscriptionEngine(
        sttConfig: STTConfig,
        audioURL: URL,
        language: String?
    ) async throws -> [TranscriptionResult] {
        switch sttConfig.mode {
        case .local:
            transcriptionProgress = ProcessingProgressStatus(
                phase: .preparing,
                detail: String(localized: "正在加载本地模型…")
            )
            let loadStartedAt = Date()
            try await whisperLocalService.loadModel(fromPath: sttConfig.modelPath)
            // 模型加载（含首次 ANE 编译）与会话长度无关：既不该计入 RTF 基线，
            // 将来也该拆成独立的固定开销段，故单独打点
            TranscriptionPerfLog.reportModelLoad(
                mode: .local,
                modelName: URL(fileURLWithPath: sttConfig.modelPath).lastPathComponent,
                seconds: Date().timeIntervalSince(loadStartedAt)
            )
            try Task.checkCancellation()
            transcriptionProgress = ProcessingProgressStatus(
                phase: .running,
                fraction: 0,
                detail: String(localized: "正在语音识别…")
            )
            // 只从纯解码开始计时：加载/准备与音频时长无关，计进去会让基线失真
            progressEstimator?.begin(.transcription)
            let results = try await whisperLocalService.transcribe(
                audioURL: audioURL,
                language: language
            ) { progress in
                Task { @MainActor in
                    self.transcriptionProgress = ProcessingProgressStatus(
                        phase: .running,
                        fraction: progress,
                        detail: String(localized: "正在语音识别…")
                    )
                }
            }
            transcriptionProgress = ProcessingProgressStatus(
                phase: .completed,
                fraction: 1,
                detail: String(localized: "已完成")
            )
            return results

        case .cloud:
            // 云端接口没有上传/处理进度回调：显示不定进度，不伪造百分比
            transcriptionProgress = ProcessingProgressStatus(
                phase: .running,
                detail: String(localized: "正在上传并识别…")
            )
            let apiService = WhisperAPIService(
                apiKey: sttConfig.apiKey,
                baseURL: sttConfig.baseURL,
                language: language
            )
            // 云端没有窗口进度回调：该段只能靠蠕动，计时用于标定本机网络/服务端实际速度
            progressEstimator?.begin(.transcription)
            let results = try await apiService.transcribe(audioURL: audioURL)
            transcriptionProgress = ProcessingProgressStatus(
                phase: .completed,
                fraction: 1,
                detail: String(localized: "已完成")
            )
            return results

        case .system:
            // 语言值原样传入：系统语音识别按 locale 解析，空值即跟随系统语言。
            // 语言模型首次安装阶段没有进度回调，故先置不定进度
            transcriptionProgress = ProcessingProgressStatus(
                phase: .running,
                detail: String(localized: "正在使用系统语音识别…")
            )
            progressEstimator?.begin(.transcription)
            let results = try await SystemTranscription.transcribe(
                audioURL: audioURL,
                language: sttConfig.language
            ) { progress in
                Task { @MainActor in
                    self.transcriptionProgress = ProcessingProgressStatus(
                        phase: .running,
                        fraction: progress,
                        detail: String(localized: "正在使用系统语音识别…")
                    )
                }
            }
            transcriptionProgress = ProcessingProgressStatus(
                phase: .completed,
                fraction: 1,
                detail: String(localized: "已完成")
            )
            return results
        }
    }

    /// 单文件说话人区分流水线：模型准备（首次自动下载）→ 分析。
    ///
    /// 任何失败都降级为「本次不做说话人区分」并写入 `.skipped`，绝不阻断文字转写
    /// （与批量转写口径一致）。核心推理没有进度回调，因此进行中阶段为不定进度。
    private func runSpeakerAnalysis(
        sttConfig: STTConfig,
        audioURL: URL,
        enabled: Bool
    ) async -> SpeakerAnalysis {
        guard enabled else { return .empty }
        let modelPath = sttConfig.diarizationModelPath
        diarizationProgress = ProcessingProgressStatus(
            phase: .preparing,
            detail: String(localized: "正在准备说话人区分组件…")
        )

        if !SpeakerDiarizationService.isModelReady(modelPath: modelPath) {
            do {
                try await SpeakerDiarizationService.shared.ensureModelsReady(
                    modelPath: modelPath
                ) { progress in
                    Task { @MainActor in
                        self.diarizationProgress = ProcessingProgressStatus(
                            phase: .preparing,
                            fraction: Float(progress),
                            detail: String(localized: "正在准备说话人区分组件…")
                        )
                    }
                }
            } catch is CancellationError {
                diarizationProgress = ProcessingProgressStatus(
                    phase: .skipped,
                    detail: String(localized: "已取消")
                )
                return .empty
            } catch {
                if !diarizationAutoDownloadNoticeSent {
                    diarizationAutoDownloadNoticeSent = true
                    showErrorMessage(String(
                        format: String(localized: "说话人区分组件下载失败，本次转写将不做说话人区分：%@"),
                        error.localizedDescription
                    ))
                }
                diarizationProgress = ProcessingProgressStatus(
                    phase: .skipped,
                    detail: String(localized: "组件下载失败，已跳过")
                )
                return .empty
            }
            guard SpeakerDiarizationService.isModelReady(modelPath: modelPath) else {
                diarizationProgress = ProcessingProgressStatus(
                    phase: .skipped,
                    detail: String(localized: "模型未就绪，已跳过")
                )
                return .empty
            }
        }

        diarizationProgress = ProcessingProgressStatus(
            phase: .running,
            detail: String(localized: "正在区分说话人…")
        )
        // 只计纯推理：上面的模型检查/下载耗时与音频时长无关，计进去会污染基线与蠕动刻度
        progressEstimator?.begin(.diarization)
        do {
            return try await SpeakerDiarizationService.shared.analyzeSpeakers(
                audioURL: audioURL,
                modelPath: modelPath,
                enableVoiceprintRecognition: sttConfig.enableVoiceprintRecognition
            ) { stage, fraction in
                // 长录音分段模式下的逐段进度：展示「第 x/y 段」。
                // 取消语义：单段 native 推理无法即时中断，取消将在当前段结束后生效
                Task { @MainActor in
                    self.diarizationProgress = ProcessingProgressStatus(
                        phase: .running,
                        fraction: fraction,
                        detail: stage
                    )
                }
            }
        } catch is CancellationError {
            diarizationProgress = ProcessingProgressStatus(
                phase: .skipped,
                detail: String(localized: "已取消")
            )
            return .empty
        } catch {
            FileSyncService.logWarning("说话人分离失败（已跳过，不影响转写）: \(error.localizedDescription)")
            diarizationProgress = ProcessingProgressStatus(
                phase: .skipped,
                detail: String(localized: "已跳过")
            )
            return .empty
        }
    }

    // MARK: - 批量转写


    /// 分离模型自动下载失败的提示只发一次：批量转写会对每条录音重复准备，
    /// 逐条弹窗会刷屏（与 `PersistenceReporting` 的「只提示一次」同口径）
    private var diarizationAutoDownloadNoticeSent = false

    /// 说话人分离是否可用。分离模型改为**首次使用时自动准备**：缺失就当场下载。
    ///
    /// 失败**不阻断转写**：提示一次后降级为「本次不做说话人分离」，
    /// 已完成的转写结果照常保存（分离只是标注增强）。
    /// - Parameter onStage: 下载进度回调（0.0~1.0）。下载层按 URLSession 字节数算的是
    ///   `Double`，在这里收口转换成 `Float`，避免每个调用方各自 `Float(...)`
    /// - Returns: 模型是否可用
    private func ensureDiarizationModelAvailable(
        sttConfig: STTConfig,
        onStage: (@Sendable (Float) -> Void)? = nil
    ) async -> Bool {
        guard sttConfig.enableSpeakerDiarization else { return false }
        if SpeakerDiarizationService.isModelReady(modelPath: sttConfig.diarizationModelPath) {
            return true
        }

        do {
            try await SpeakerDiarizationService.shared.ensureModelsReady(
                modelPath: sttConfig.diarizationModelPath
            ) { progress in
                onStage?(Float(progress))
            }
        } catch is CancellationError {
            return false
        } catch {
            if !diarizationAutoDownloadNoticeSent {
                diarizationAutoDownloadNoticeSent = true
                showErrorMessage(String(format: String(localized: "说话人区分组件下载失败，本次转写将不做说话人区分：%@"), UserFacingError.summary(for: error)))
            }
            return false
        }
        return SpeakerDiarizationService.isModelReady(modelPath: sttConfig.diarizationModelPath)
    }

    /// 批处理循环的统一终止判据。取消必须压过“仍有未提交项”，否则在途任务清空后
    /// 会因 nextIndex 仍小于 total 而在 MainActor 上无限空转。
    nonisolated static func shouldContinueBatchLoop(
        nextIndex: Int,
        total: Int,
        activeTasks: Int,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && (nextIndex < total || activeTasks > 0)
    }

    /// 获取系统可用显存（MB）
    private func getAvailableGPUMemoryMB() -> Int {
        #if canImport(Metal) && os(macOS)
        if let device = MTLCreateSystemDefaultDevice() {
            let totalMB = Int(device.recommendedMaxWorkingSetSize) / (1024 * 1024)
            let reserved = max(totalMB / 3, 2048)
            return max(totalMB - reserved, 1024)
        }
        #endif
        let physicalMemMB = Int(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
        return max(physicalMemMB / 2, 1024)
    }

    /// 根据模型文件夹实际体积估算最大并发转写数（枚举在后台执行，避免卡主线程）
    func calculateMaxConcurrency(modelPath: String) async -> Int {
        let availableMB = getAvailableGPUMemoryMB()
        let modelMB = await WhisperLocalService.estimateModelMemoryMB(at: modelPath)
        let concurrency = availableMB / modelMB
        return max(1, min(concurrency, 4))
    }

    /// 转写输入预检：文件存在且可读（时长 > 0），在引擎层之前快速失败。
    /// 返回音频时长（秒）供进度估算使用，避免调用方再探测一次。
    /// 单条与批量转写共用，nonisolated 以便在并发任务闭包中调用。
    @discardableResult
    private nonisolated static func validateAudioInput(at url: URL) async throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionInputError.audioFileMissing
        }
        let duration = (try? await AudioConverter.getDuration(of: url)) ?? 0
        guard duration > 0 else {
            throw TranscriptionInputError.audioUnreadable
        }
        return duration
    }

    // MARK: - 总结（支持取消）

    /// 生成总结（支持取消/后台续跑）
    /// - Parameter asMeeting: 用户选择的总结模板（true=会议总结，false=概要总结），
    ///   由总结页双按钮显式传入，不再走自动判定 LLM 往返；
    ///   nil=未指定（旧队列条目续跑）→ 条目持久化判定 → 转写文本分类兑底（保守会议）
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当本次执行确实产出总结并已落库/落盘
    @discardableResult
    func generateSummary(
        recording: AudioRecording,
        llmConfig: LLMConfig,
        context: ModelContext,
        asMeeting: Bool? = nil,
        experience: AppExperience? = nil
    ) -> Task<StepOutcome, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task { .failed } }
        let recordingID = recording.id
        let folderName = recording.folderName
        // 只取消「同一条目」的上一次总结：不同条目各自持有独立句柄，互不干扰
        summaryTasks[recordingID]?.cancel()
        let executionToken = UUID()
        summaryExecutions[recordingID] = executionToken

        let taskExperience = experience ?? AppExperiencePreference.resolved()
        // 后台任务队列埋点：用户发起总结时入队（幂等，携带模板选择），守护进程据此续跑
        if !BackgroundTaskQueue.enqueue(BackgroundTaskEntry(
            kind: .summary,
            folderName: folderName,
            llmConfigID: llmConfig.id,
            isMeeting: asMeeting,
            experience: taskExperience
        )) {
            showErrorMessage(String(localized: "任务已在前台开始，但未能写入后台续跑队列；请保持应用开启完成本次任务，退出后需重新发起。"))
        }

        let state = SummaryStreamState(folderName: folderName)
        summaryStreams[recordingID] = state
        summarizingRecordingIDs.insert(recordingID)
        if isSelected(recordingID) {
            isSummarizing = true
            summaryText = ""
            summaryReasoningText = ""
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            let outcome = await self.performSummary(
                recording: recording,
                recordingID: recordingID,
                llmConfig: llmConfig,
                context: context,
                asMeeting: asMeeting,
                experience: taskExperience,
                state: state
            )
            self.finishSummaryExecution(
                recordingID: recordingID,
                executionToken: executionToken,
                state: state
            )
            return outcome
        }
        summaryTasks[recordingID] = task
        return task
    }

    /// 总结执行体。流式缓冲与 PII 映射全部封装在 `state` 内按条目隔离，
    /// 只有当前展示条目才写入共享 UI 状态；持久化始终按各自条目写入。
    private func performSummary(
        recording: AudioRecording,
        recordingID: UUID,
        llmConfig: LLMConfig,
        context: ModelContext,
        asMeeting: Bool?,
        experience: AppExperience,
        state: SummaryStreamState
    ) async -> StepOutcome {
        do { try SummaryHistory.preserve(recording.summary, in: recording.folderURL) }
        catch {
            showErrorMessage(String(localized: "无法保存总结历史，已保留原内容并停止替换。"))
            return .failed
        }
        // 用带说话人与时间戳的 Markdown（而非纯文本 fullTranscript），
        // 保证声纹识别/手动标记的姓名进入总结 prompt。
        // 提示词使用单独的来源版 Markdown，不改变复制/编辑时的干净渲染缓存。
        let segmentData = recording.segments
            .sorted { $0.startTime < $1.startTime }
            .map { segment in
                TranscriptMarkdownBuilder.SegmentData(
                    timeRange: segment.formattedTimeRange,
                    startTime: segment.startTime,
                    speaker: segment.speaker,
                    encryptedText: segment.text
                )
            }
        let transcript: String
        do {
            let work = Task.detached(priority: .userInitiated) { try SummarySources.markdown(from: segmentData) }
            transcript = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
        } catch is CancellationError { return .cancelled }
        catch {
            showErrorMessage(String(localized: "无法读取转写原文，已停止生成总结。"))
            return .failed
        }
        guard !transcript.isEmpty else {
            showErrorMessage(String(localized: "转写内容为空，请先完成转写"))
            return .failed
        }

        do {
            let snapshot = try LLMConfigSnapshot(config: llmConfig)

            // PII 去标识化：端点策略与总开关共同决定，与模型类型无关。
            // 发送前替换为占位符，流式返回时按映射实时还原
            // （开关与 SettingsViewModel.Keys.enablePIIScrub 同源，本 VM 未持有 settingsVM，直读 UserDefaults）。
            // 映射只写入本次执行的 state，不再落到实例级共享字段（避免并发串数据）
            let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
            let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
                savedValue: savedPIIValue,
                experience: experience
            )
            let didScrubPII = piiEnabled && snapshot.shouldScrubText
            let promptTranscript: String
            if didScrubPII {
                let scrubbed = PIIScrubService.scrub(transcript)
                state.scrubMapping = scrubbed.mapping
                promptTranscript = scrubbed.scrubbed
            } else {
                promptTranscript = transcript
            }

            // 模板选择：双按钮显式传入（manual）；未指定时（旧队列条目续跑、批量入口）
            // 用条目持久化判定，再无则转写文本分类兑底（保守会议，与旧自动行为一致）；
            // 结果回写持久化字段，供画面要点注入、待办拆解与跨重启复用
            let isMeetingHint: Bool
            if let chosen = asMeeting {
                isMeetingHint = chosen
                recording.meetingJudgedBy = "manual"
            } else if let persisted = recording.isMeeting {
                isMeetingHint = persisted
            } else {
                isMeetingHint = (try? await LLMService.detectMeeting(
                    transcript: promptTranscript, config: snapshot)) ?? true
                recording.meetingJudgedBy = "transcript"
            }
            recording.isMeeting = isMeetingHint
            recording.meetingJudgedAt = Date()
            PersistenceReporting.saveOrReport { try context.save() }

            // 视频条目若已有「画面要点」，作为同时间轴佐证注入总结（会议→视听对照，
            // 非会议→内容大纲模板）；尚未分析画面时**不**自动抽帧上云，
            // 维持「未经确认不发送画面」的既有隐私边界，页签顺序即天然引导
            let visualForSummary = recording.decryptedVisualSummary

            let result = try await LLMService.generateSummary(
                transcript: promptTranscript,
                config: snapshot,
                isMeetingHint: isMeetingHint,
                visualContext: visualForSummary.isEmpty ? nil : visualForSummary,
                piiScrubbed: didScrubPII,
                onToken: { token in
                    Task { @MainActor in
                        self.appendSummaryToken(token, recordingID: recordingID)
                    }
                },
                onReasoning: { token in
                    // 思考内容与正文分开展示：推理型模型在 8k 预算下可能把预算全用在
                    // 思考上，把它显示出来才能解释「为什么正文是空的」
                    Task { @MainActor in
                        self.appendSummaryReasoningToken(token, recordingID: recordingID)
                    }
                },
                onAttemptStart: {
                    // 重试前清空本次执行的流式缓冲，避免新旧 token 重复拼接
                    Task { @MainActor in
                        self.resetSummaryStream(recordingID: recordingID)
                    }
                }
            )

            // D-3: 检查 LLM 返回空内容
            guard !result.isEmpty else {
                showErrorMessage(String(localized: "总结生成失败：LLM 返回了空内容。请检查模型配置或稍后重试。"))
                return .failed
            }

            // 保存前还原占位符为真实信息（附带还原诊断日志）
            let restored = PIIScrubService.restoreWithDiagnostics(
                result, mapping: state.scrubMapping ?? .empty)

            // 加密保存总结（加密失败时回退到明文并记录日志）
            do {
                recording.summary = try EncryptionService.encrypt(restored)
            } catch {
                EncryptionService.reportEncryptionFailure(error, context: "总结")
                recording.summary = restored
            }
            recording.summaryGeneratedAt = Date()

            // 将总结保存到文件夹
            saveSummaryToFolder(recording)

            // 总结完成后自动生成标题并更新列表标题（失败仅日志，不影响总结本身）
            await autoAssignRecordingTitle(
                recording,
                from: restored,
                config: snapshot,
                context: context,
                experience: experience
            )

            return .succeeded

        } catch is CancellationError {
            // 用户取消 / Job 取消：静默处理，结果按取消结算
            return .cancelled
        } catch {
            // C-3: 网络中断时保存已生成的部分总结（先冲刷节流缓冲，拿到完整已生成内容）
            flushSummaryText(recordingID: recordingID, state: state)
            if !state.displayText.isEmpty {
                do {
                    recording.summary = try EncryptionService.encrypt(state.displayText)
                } catch {
                    EncryptionService.reportEncryptionFailure(error, context: "部分总结")
                    recording.summary = state.displayText
                }
                recording.summaryGeneratedAt = Date()
                saveSummaryToFolder(recording)
                // 部分总结同样自动生成标题（与完整总结路径一致）；快照重建失败仅跳过标题更新
                if let snapshot = try? LLMConfigSnapshot(config: llmConfig) {
                    await autoAssignRecordingTitle(
                        recording,
                        from: state.displayText,
                        config: snapshot,
                        context: context,
                        experience: experience
                    )
                }
                showErrorMessage(String(format: String(localized: "总结生成中断，已保存已生成的部分内容。\n错误详情：%@\n可重新点击「生成总结」获取完整内容。"), UserFacingError.summary(for: error)))
            } else {
                showErrorMessage(String(localized: "总结生成失败：\(UserFacingError.summary(for: error))"))
            }
            // 只保存了部分内容，本次并未完整产出：按失败结算，避免后续依赖步骤误以为成功
            return .failed
        }
    }

    /// 总结执行收尾：仅当仍是「本次执行」时才复位共享 UI 态与句柄。
    /// 旧执行被新执行取代时直接返回——出队与状态复位交给新执行，避免误清新执行的句柄。
    private func finishSummaryExecution(
        recordingID: UUID,
        executionToken: UUID,
        state: SummaryStreamState
    ) {
        guard summaryExecutions[recordingID] == executionToken else { return }
        // 结束路径兜底刷新，保证节流窗口内的尾部 token 完整上屏
        flushSummaryText(recordingID: recordingID, state: state)
        flushSummaryReasoningText(recordingID: recordingID, state: state)
        summaryExecutions[recordingID] = nil
        summaryTasks[recordingID] = nil
        summaryStreams[recordingID] = nil
        summarizingRecordingIDs.remove(recordingID)
        if isSelected(recordingID) {
            isSummarizing = false
            // 思考过程仅生成期间可见：收尾即清空，正文与已保存总结不受影响
            summaryReasoningText = ""
        }
        BackgroundTaskQueue.dequeue(kind: .summary, folderName: state.folderName)
    }

    /// 取消指定条目的总结（队列「取消」/ 删除条目入口，只影响该条目的句柄）
    func cancelSummary(recordingID: UUID) {
        summaryTasks[recordingID]?.cancel()
        summaryTasks[recordingID] = nil
        summaryExecutions[recordingID] = nil
        if let state = summaryStreams[recordingID] {
            // 被取消任务的收尾已被执行令牌守卫挡住，这里负责对应的后台队列出队埋点
            BackgroundTaskQueue.dequeue(kind: .summary, folderName: state.folderName)
            summaryStreams[recordingID] = nil
        }
        summarizingRecordingIDs.remove(recordingID)
        if isSelected(recordingID) {
            isSummarizing = false
            summaryText = ""
            summaryReasoningText = ""
        }
    }

    /// 兼容旧入口：取消当前展示条目的总结
    func cancelSummary() {
        guard let id = selectedRecording?.id else { return }
        cancelSummary(recordingID: id)
    }

    // MARK: - 画面要点（仅适用于导入过原始视频的条目）

    func cancelVisualNotes() {
        // 主动取消留痕：与「无发起方的意外中断」区分开，便于按日志定位中断来源
        FileSyncService.logWarning(
            "画面分析被主动取消（用户停止/删除条目，folder=\(visualNotesRecordingFolderName ?? "-")，generation=\(visualNotesGeneration)）"
        )
        visualNotesGeneration += 1
        visualNotesTask?.cancel()
        visualNotesTask = nil
        visualExtractionTask?.cancel()
        visualExtractionTask = nil
        isGeneratingVisualNotes = false
        visualNotesRecordingFolderName = nil
        visualNotesReasoningText = ""
        visualNotesReasoningRawBuffer = ""
    }

    /// 进行中的画面要点是否属于该条目：`isGeneratingVisualNotes` 是全应用共享的瞬态态，
    /// 视图必须按条目过滤，否则切到别的录屏也会命中进行中分支并渲染上一条目的文本
    func isGeneratingVisualNotes(for recording: AudioRecording) -> Bool {
        isGeneratingVisualNotes && visualNotesRecordingFolderName == recording.folderName
    }

    /// 从条目留存的原始视频抽关键帧并生成「画面要点」。
    ///
    /// 帧来源是同文件夹的 `{base}_video.{ext}`，音轨与画面同源，
    /// 因此产出的 mm:ss 与转写片段的时间戳是**同一时间轴**，可直接对读。
    ///
    /// 与转写/总结不同：不进 BackgroundTaskQueue——守护进程没有抽帧能力，
    /// 跟进程续跑要整搬 AVFoundation 链路；主应用退出时本任务会中止，不伪称可后台续跑。
    func generateVisualNotes(
        recording: AudioRecording,
        llmConfig: LLMConfig,
        context: ModelContext,
        autoResumeAttempt: Int = 0
    ) -> Task<StepOutcome, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task { .failed } }
        visualNotesTask?.cancel()
        visualNotesGeneration += 1
        let generation = visualNotesGeneration

        let task: Task<StepOutcome, Never> = Task { @MainActor in
            // 原件可能已被「清理视频」删掉：有可复用帧缓存时照常分析，
            // 无原件且无缓存时由 `loadOrExtractFrames` 抛错并提示，不在这里提前拒绝
            let videoURL = recording.videoFileURL.flatMap { url in
                FileManager.default.fileExists(atPath: url.path) ? url : nil
            }

            isGeneratingVisualNotes = true
            visualNotesRecordingFolderName = recording.folderName
            visualNotesText = ""
            visualNotesRawBuffer = ""
            visualNotesLastFlushTime = 0
            visualNotesReasoningText = ""
            visualNotesReasoningRawBuffer = ""
            visualNotesReasoningLastFlushTime = 0
            visualReasoningSegmentStartOffset = 0
            visualNotesSegmentIndex = 0
            visualNotesSegmentTotal = 0
            visualNotesProgress = 0.02
            defer {
                // 已被更新任务取代时不得复位新任务的进行中态与进行中条目
                if generation == self.visualNotesGeneration {
                    isGeneratingVisualNotes = false
                    visualNotesRecordingFolderName = nil
                    visualNotesProgress = 0
                    // 思考过程仅生成期间可见：收尾即清空
                    visualNotesReasoningText = ""
                    visualNotesReasoningRawBuffer = ""
                }
            }

            do {
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                let framesDirectoryURL = recording.framesDirectoryURL
                let frames = try await VideoUnderstandingService.loadOrExtractFrames(
                    videoURL: videoURL,
                    framesDirectoryURL: framesDirectoryURL
                ) { progress in
                    Task { @MainActor in
                        // 抽帧阶段占进度条前段（与旧 analyze 同一映射），后续由要点请求接管
                        self.visualNotesProgress = 0.02 + progress * 0.4
                    }
                }
                visualNotesProgress = 0.5
                // 折叠标题要显示「第 k/N 段」：N 与分片规则同源，直接复用 visualChunks 的结果，
                // 这样首段开始吐字时 N 就是已知的，标题不会出现 0/N
                visualNotesSegmentTotal = LLMService.visualChunks(
                    from: frames,
                    perRequest: LLMService.maxFramesPerVisualRequest
                ).count

                let checkpointDirectoryURL = recording.visualAnalysisCheckpointDirectoryURL
                let checkpoint = await VideoUnderstandingService.prepareVisualAnalysisCheckpoint(
                    frames: frames,
                    config: snapshot,
                    directoryURL: checkpointDirectoryURL,
                    framesPerSegment: LLMService.maxFramesPerVisualRequest
                )

                let generation = try await LLMService.generateVisualNotes(
                    frames: frames,
                    config: snapshot,
                    completedSegments: checkpoint.completedSegments,
                    onToken: { token in
                        Task { @MainActor in
                            self.appendVisualNotesToken(token)
                        }
                    },
                    onReasoning: { token in
                        Task { @MainActor in
                            self.appendVisualNotesReasoningToken(token)
                        }
                    },
                    onSegmentStart: { segment, attempt in
                        Task { @MainActor in
                            // 0-based 段号转 1 起显示：折叠 label 里的「第 k/N 段」
                            self.visualNotesSegmentIndex = segment + 1
                            if attempt > 1 {
                                // 同段重试：回退到本段起点，去掉上次留下的半截 token
                                self.visualNotesRawBuffer = String(
                                    self.visualNotesRawBuffer.prefix(self.visualSegmentStartOffset)
                                )
                                self.visualNotesReasoningRawBuffer = String(
                                    self.visualNotesReasoningRawBuffer.prefix(
                                        self.visualReasoningSegmentStartOffset)
                                )
                            } else {
                                // 新段首次 attempt：段间补一个换行，再记下本段起点
                                if segment > 0 {
                                    self.visualNotesRawBuffer += "\n"
                                    self.visualNotesReasoningRawBuffer += "\n"
                                }
                                self.visualSegmentStartOffset = self.visualNotesRawBuffer.count
                                self.visualReasoningSegmentStartOffset =
                                    self.visualNotesReasoningRawBuffer.count
                            }
                            // 段边界立即上屏，保证重试回退后显示内容与缓冲一致
                            self.flushVisualNotesText()
                            self.flushVisualNotesReasoningText()
                        }
                    },
                    onSegmentProgress: { done, total in
                        Task { @MainActor in
                            // 请求阶段占进度条后段（0.5→0.95），逐段推进而不是停在 0.5 转圈
                            self.visualNotesSegmentTotal = total
                            let ratio = Double(done) / Double(max(total, 1))
                            self.visualNotesProgress = 0.5 + ratio * 0.45
                        }
                    },
                    onSegmentComplete: { segment, _, text in
                        await VideoUnderstandingService.persistVisualAnalysisSegment(
                            text,
                            segment: segment,
                            checkpoint: checkpoint,
                            directoryURL: checkpointDirectoryURL
                        )
                    }
                )
                let result = generation.text

                guard !result.isEmpty else {
                    showErrorMessage("画面要点生成失败：模型返回了空内容，请检查模型配置或稍后重试")
                    return .failed
                }
                visualNotesText = result
                visualNotesRawBuffer = result

                // 加密入库（失败时回退明文并留痕，与总结同策略）
                do {
                    recording.visualSummary = try EncryptionService.encrypt(result)
                } catch {
                    EncryptionService.reportEncryptionFailure(error, context: "画面要点")
                    recording.visualSummary = result
                }
                recording.visualSummaryGeneratedAt = Date()
                let databaseSaved = PersistenceReporting.saveOrReport { try context.save() }
                let mirrorSaved = await saveVisualSummaryToFolder(recording)

                if generation.allSegmentsCompleted, databaseSaved, mirrorSaved {
                    await VideoUnderstandingService.clearVisualAnalysisCheckpoint(
                        checkpoint,
                        directoryURL: checkpointDirectoryURL
                    )
                }

                // 成功仅当本次确实产出画面要点且已入库 + 已落盘镜像；否则按失败结算
                return (databaseSaved && mirrorSaved) ? .succeeded : .failed

            } catch is CancellationError {
                // 主动取消（用户点「停止」/删除条目/被新任务顶替）都会先递增 generation，静默即可
                guard generation == self.visualNotesGeneration else { return .cancelled }
                // 没有任何发起方却被取消（宿主/运行期导致，例如视图或宿主窗口被重建时的连带取消）：
                // 以前这里静默吞掉，用户只会看到「分析莫名其妙中断、又变回未分析」，且没有任何提示。
                // 现改为留痕 + 从检查点自愈续跑一次（检查点只重发未完成的段，成本低）
                FileSyncService.logWarning(
                    "画面要点任务被意外取消（无发起方，folder=\(recording.folderName)，generation=\(generation)，attempt=\(autoResumeAttempt)）"
                )
                if autoResumeAttempt < Self.visualNotesMaxAutoResumes {
                    FileSyncService.logWarning("画面要点自动从检查点续跑（第 \(autoResumeAttempt + 1) 次）")
                    _ = self.generateVisualNotes(
                        recording: recording,
                        llmConfig: llmConfig,
                        context: context,
                        autoResumeAttempt: autoResumeAttempt + 1
                    )
                } else {
                    self.showErrorMessage(String(localized: "画面分析被意外中断，请重试（已完成的部分会保留）。"))
                }
                return .cancelled
            } catch {
                showErrorMessage(String(localized: "画面要点生成失败：\(UserFacingError.summary(for: error))"))
                return .failed
            }
        }
        visualNotesTask = task
        return task
    }

    /// 画面分析第一步：本地抽取关键帧（**不上传云端**），成功返回帧数。
    /// 帧落盘 <folder>/frames/ 缓存，第二步分析直接复用不重扫；完成后由视图层
    /// 弹确认是否进入画面分析（进一步收紧“未经确认不发送画面”的隐私语义）。
    /// 与画面要点共用 visualNotesTask/取消通道与进行中态；进度映射到 0.02–0.47，
    /// 全程停在“正在抽取并筛选关键帧…”文案（>0.5 是“请模型读画面”，不属于本阶段）
    func extractVisualFrames(recording: AudioRecording, autoResumeAttempt: Int = 0) -> Task<Int?, Never> {
        visualExtractionTask?.cancel()
        visualNotesGeneration += 1
        let generation = visualNotesGeneration

        let task = Task { @MainActor () -> Int? in
            guard let videoURL = recording.videoFileURL,
                  FileManager.default.fileExists(atPath: videoURL.path) else {
                showErrorMessage("该条目没有留存的原始视频，无法抽取关键帧（重新导入视频即可保留原件）")
                return nil
            }
            isGeneratingVisualNotes = true
            visualNotesRecordingFolderName = recording.folderName
            // 抽帧阶段不产出文本：清掉上一条目残留的要点，避免进行中分支显示到别人的结果
            visualNotesText = ""
            visualNotesReasoningText = ""
            visualNotesProgress = 0.02
            defer {
                // 已被更新任务取代时不得复位新任务的进行中态与进行中条目
                if generation == self.visualNotesGeneration {
                    isGeneratingVisualNotes = false
                    visualNotesRecordingFolderName = nil
                    visualNotesProgress = 0
                }
            }
            do {
                let frames = try await VideoUnderstandingService.loadOrExtractFrames(
                    videoURL: videoURL,
                    framesDirectoryURL: recording.framesDirectoryURL
                ) { progress in
                    Task { @MainActor in
                        self.visualNotesProgress = 0.02 + progress * 0.45
                    }
                }
                return frames.count
            } catch is CancellationError {
                // 与要点任务同一判据：generation 仍等于自己 ⇒ 没有任何发起方，是意外中断
                guard generation == self.visualNotesGeneration else { return nil }
                FileSyncService.logWarning(
                    "抽帧任务被意外取消（无发起方，folder=\(recording.folderName)，generation=\(generation)，attempt=\(autoResumeAttempt)）"
                )
                if autoResumeAttempt < Self.visualNotesMaxAutoResumes {
                    FileSyncService.logWarning("抽帧自动续跑（第 \(autoResumeAttempt + 1) 次）")
                    _ = self.extractVisualFrames(
                        recording: recording,
                        autoResumeAttempt: autoResumeAttempt + 1
                    )
                } else {
                    self.showErrorMessage(String(localized: "画面分析被意外中断，请重试（已完成的部分会保留）。"))
                }
                return nil
            } catch {
                showErrorMessage(String(localized: "关键帧抽取失败：\(UserFacingError.summary(for: error))"))
                return nil
            }
        }
        visualExtractionTask = task
        return task
    }

    /// 「清理视频」：**只删原始视频文件本身**，关键帧（`frames/`）、画面要点（`visual.md`）、
    /// 分析检查点、音频与转写全部保留。
    ///
    /// 为什么敢删掉唯一能重抽帧的原件：前置条件由 `cleanupOriginalVideo` 强制——
    /// 必须已有可复用的帧缓存，否则直接拒绝。删后画面页签靠 `frames/` 与 `visual.md`
    /// 继续可用（见 `AudioRecording.hasVisualArtifacts`）。
    ///
    /// `videoFileName` 随磁盘事实置空，不让模型长期指向一个已不存在的文件；
    /// 删文件失败向上报错，不假装已清理。
    func cleanupVideo(recording: AudioRecording, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.deleteEntry) else { return }
        guard let request = MediaCleanupRequest(kind: .video, items: [.recording(recording)]) else {
            showErrorMessage("该条目没有留存的原始视频可清理。")
            return
        }
        Task { @MainActor in
            do {
                let result = try await MediaCleanupService.shared.cleanup(request, context: context, persistence: persistence)
                if !result.failures.isEmpty { showErrorMessage(result.message) }
            } catch {
                showErrorMessage(UserFacingError.summary(for: error))
            }
        }
    }

    /// 从总结自动生成标题并更新列表标题，格式“年月日时分 标题”（与默认命名同一时间格式约定）。
    /// 仅当标题仍为默认名（录音“会议录音 xxx”或录屏“录屏 xxx”）时生效，
    /// 避免覆盖用户手动重命名；写入后同步 meta.json 与数据库，自动保存
    private func autoAssignRecordingTitle(
        _ recording: AudioRecording,
        from content: String,
        config: LLMConfigSnapshot,
        context: ModelContext,
        experience: AppExperience
    ) async {
        let defaultPrefixes = [
            String(format: String(localized: "会议录音 %@"), ""),
            String(format: String(localized: "录屏 %@"), "")
        ].map { $0.trimmingCharacters(in: .whitespaces) }
        guard defaultPrefixes.contains(where: { recording.fileName.hasPrefix($0) }) else { return }

        // 失败时记录真实错误原因（try? 吞错会导致失败零感知无法定位）
        let title: String
        do {
            title = try await generatePrivacySafeTitle(
                from: content,
                config: config,
                experience: experience
            )
        } catch {
            FileSyncService.logWarning(
                "自动标题生成失败，保留原标题 (\(recording.folderName)): \(error.localizedDescription)")
            return
        }
        guard !title.isEmpty else { return }

        recording.fileName = "\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) \(title)"
        recording.saveMetaToFolder()
        do {
            try await saveContextWithRetry(context)
        } catch {
            FileSyncService.logWarning("自动标题保存失败: \(error.localizedDescription)")
        }
    }

    /// 润色标题（右键入口）：用大模型从总结与待办事项提取不超过 10 字的主旨，
    /// 更新列表标题为“年月日时分 主旨”。用户显式操作，直接覆盖当前标题（含手动命名）；
    /// 无总结也无待办时提示先执行其一
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当生成了非空标题并已落库
    @discardableResult
    func polishRecordingTitle(_ recording: AudioRecording, llmConfig: LLMConfig, context: ModelContext) -> Task<StepOutcome, Never> {
        let recordingID = recording.id
        // 只取消「同一条目」的上一次标题润色
        titleTasks[recordingID]?.cancel()
        let executionToken = UUID()
        titleExecutions[recordingID] = executionToken
        let taskExperience = AppExperiencePreference.resolved()
        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            defer {
                // 仅当仍是本次执行时才清理句柄，避免旧执行误清新执行的句柄
                if self.titleExecutions[recordingID] == executionToken {
                    self.titleExecutions[recordingID] = nil
                    self.titleTasks[recordingID] = nil
                }
            }
            do {
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                var sources: [String] = []
                let summary = recording.decryptedSummary
                if !summary.isEmpty { sources.append(summary) }
                let todoTitles = TodoDocument.load(from: recording.folderURL)?
                    .items.map(\.title).joined(separator: "\n") ?? ""
                if !todoTitles.isEmpty { sources.append(todoTitles) }
                guard !sources.isEmpty else {
                    self.showErrorMessage("请先生成总结或拆解待办，再润色标题。")
                    return .failed
                }

                let title = try await self.generatePrivacySafeTitle(
                    from: sources.joined(separator: "\n\n"),
                    config: snapshot,
                    experience: taskExperience
                )
                guard !title.isEmpty else {
                    self.showErrorMessage("润色标题失败：大模型返回了空内容，请重试。")
                    return .failed
                }

                recording.fileName = "\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) \(title)"
                recording.saveMetaToFolder()
                try await self.saveContextWithRetry(context)
                return .succeeded
            } catch is CancellationError {
                // 用户取消，静默处理
                return .cancelled
            } catch {
                self.showErrorMessage(String(localized: "润色标题失败：\(UserFacingError.summary(for: error))"))
                return .failed
            }
        }
        titleTasks[recordingID] = task
        return task
    }

    /// 取消指定条目的标题润色（队列「取消」入口，只影响该条目的句柄）
    func cancelTitle(recordingID: UUID) {
        titleTasks[recordingID]?.cancel()
        titleTasks[recordingID] = nil
        titleExecutions[recordingID] = nil
    }

    /// 兼容旧入口：取消当前展示条目的标题润色
    func cancelTitle() {
        guard let id = selectedRecording?.id else { return }
        cancelTitle(recordingID: id)
    }

    private func generatePrivacySafeTitle(
        from content: String,
        config: LLMConfigSnapshot,
        experience: AppExperience
    ) async throws -> String {
        let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
        let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
            savedValue: savedPIIValue,
            experience: experience
        )
        let scrubbed = (piiEnabled && config.shouldScrubText)
            ? PIIScrubService.scrub(content) : nil
        let title = try await LLMService.generateTitle(
            from: scrubbed?.scrubbed ?? content,
            config: config
        )
        return scrubbed.map {
            PIIScrubService.restore(title, mapping: $0.mapping)
        } ?? title
    }

    // MARK: - 总结流式状态（按条目隔离）

    /// 单次总结执行的流式状态。
    ///
    /// 缓冲、节流时钟与 PII 映射都按「本次执行」持有：旧实现把三者放在实例级共享字段上，
    /// 并发跑两个条目的总结时会互相追加对方的 token、用错对方的占位符映射，
    /// 表现为「总结内容串到别的录音」。存放于 `@MainActor` 的 `summaryStreams` 中，
    /// 只在主线程访问，无需额外加锁。
    private final class SummaryStreamState {
        let folderName: String
        var rawBuffer = ""
        var reasoningRawBuffer = ""
        var scrubMapping: PIIScrubMapping?
        var lastFlushTime: CFAbsoluteTime = 0
        var reasoningLastFlushTime: CFAbsoluteTime = 0
        /// 已按映射还原后的可展示文本（用于切回条目时恢复上屏）
        var displayText = ""
        var displayReasoning = ""

        init(folderName: String) { self.folderName = folderName }
    }

    @ObservationIgnored private var summaryStreams: [UUID: SummaryStreamState] = [:]
    /// 正在生成总结的条目集合（供切条目时恢复「进行中」态）
    @ObservationIgnored private var summarizingRecordingIDs: Set<UUID> = []

    private func isSelected(_ recordingID: UUID) -> Bool {
        selectedRecording?.id == recordingID
    }

    /// 切换选中条目时同步总结相关的共享 UI 态：进行中的另一条目不得把它的
    /// 流式内容与「正在生成」态显示到当前条目上。
    private func syncSummaryDisplayForSelection() {
        let id = selectedRecording?.id
        isSummarizing = id.map { summarizingRecordingIDs.contains($0) } ?? false
        isExtractingTodos = id.map { extractingTodoIDs.contains($0) } ?? false
        if let id, let state = summaryStreams[id] {
            summaryText = state.displayText
            summaryReasoningText = state.displayReasoning
        } else {
            summaryText = ""
            summaryReasoningText = ""
        }
    }

    /// 流式总结 token 追加：先累积到本次执行的原始缓冲，再按去标识化映射整体还原后展示。
    /// 每次全量还原可正确处理占位符被流式 token 切断的情况（如 "[人名" 与 "1]" 分片到达）
    private func appendSummaryToken(_ token: String, recordingID: UUID) {
        guard let state = summaryStreams[recordingID] else { return }
        state.rawBuffer += token
        let now = CFAbsoluteTimeGetCurrent()
        guard now - state.lastFlushTime >= 0.1 else { return }
        state.lastFlushTime = now
        flushSummaryText(recordingID: recordingID, state: state)
    }

    /// 把本次执行的缓冲区（含 PII 占位符还原）写入展示态；
    /// 只有当前展示条目才写入共享 UI 状态，避免并发串数据
    private func flushSummaryText(recordingID: UUID, state: SummaryStreamState) {
        let text: String
        if let mapping = state.scrubMapping, !mapping.isEmpty {
            text = PIIScrubService.restore(state.rawBuffer, mapping: mapping)
        } else {
            text = state.rawBuffer
        }
        state.displayText = text
        if isSelected(recordingID) { summaryText = text }
    }

    /// 流式「思考过程」缓冲：与正文分开累积，只用于展示与诊断
    private func appendSummaryReasoningToken(_ token: String, recordingID: UUID) {
        guard let state = summaryStreams[recordingID] else { return }
        state.reasoningRawBuffer += token
        let now = CFAbsoluteTimeGetCurrent()
        guard now - state.reasoningLastFlushTime >= 0.3 else { return }
        state.reasoningLastFlushTime = now
        flushSummaryReasoningText(recordingID: recordingID, state: state)
    }

    /// 思考文本同样由「已脱敏的 prompt」产出，因此要复用本次执行的占位符映射还原，
    /// 否则展示层会露出 `[人名1]` 这类内部占位符
    private func flushSummaryReasoningText(recordingID: UUID, state: SummaryStreamState) {
        let text: String
        if state.reasoningRawBuffer.isEmpty {
            text = ""
        } else if let mapping = state.scrubMapping, !mapping.isEmpty {
            text = PIIScrubService.restore(state.reasoningRawBuffer, mapping: mapping)
        } else {
            text = state.reasoningRawBuffer
        }
        state.displayReasoning = text
        if isSelected(recordingID) { summaryReasoningText = text }
    }

    /// 重试前清空本次执行的流式缓冲（避免新旧 token 重复拼接）
    private func resetSummaryStream(recordingID: UUID) {
        guard let state = summaryStreams[recordingID] else { return }
        state.rawBuffer = ""
        state.reasoningRawBuffer = ""
        state.displayText = ""
        state.displayReasoning = ""
        if isSelected(recordingID) {
            summaryText = ""
            summaryReasoningText = ""
        }
    }

    // MARK: - 画面要点流式缓冲（节流）

    /// 画面要点原始缓冲：token 级直接赋值 visualNotesText 会让 @Observable 对整段
    /// 长文本反复做差异计算，并在每秒数百次刷新下掉帧；与总结路径一致改为
    /// 「原始缓冲 + 0.3s 定时 flush」，正文只在折叠面板展开时渲染
    private var visualNotesRawBuffer = ""
    private var visualNotesLastFlushTime: CFAbsoluteTime = 0
    /// 思考文本的原始缓冲与节流时间（与正文分开累积，口径一致）
    private var visualNotesReasoningRawBuffer = ""
    private var visualNotesReasoningLastFlushTime: CFAbsoluteTime = 0
    /// 思考文本的分段起始下标：与正文同理，段内重试只回退本段已吐的思考
    private var visualReasoningSegmentStartOffset = 0

    private func appendVisualNotesToken(_ token: String) {
        visualNotesRawBuffer += token
        let now = CFAbsoluteTimeGetCurrent()
        // 折叠面板下只有用户展开才渲染正文：节流放宽到 0.3s（与总结思考文本一致），
        // 展开态也不会每秒多次重排长文本
        guard now - visualNotesLastFlushTime >= 0.3 else { return }
        visualNotesLastFlushTime = now
        flushVisualNotesText()
    }

    private func flushVisualNotesText() {
        visualNotesText = visualNotesRawBuffer
    }

    /// 画面要点「思考过程」追加：与正文分开累积，0.3s 节流上屏
    private func appendVisualNotesReasoningToken(_ token: String) {
        visualNotesReasoningRawBuffer += token
        let now = CFAbsoluteTimeGetCurrent()
        guard now - visualNotesReasoningLastFlushTime >= 0.3 else { return }
        visualNotesReasoningLastFlushTime = now
        flushVisualNotesReasoningText()
    }

    private func flushVisualNotesReasoningText() {
        visualNotesReasoningText = visualNotesReasoningRawBuffer
    }

    // MARK: - 批量总结


    /// P2-8: 批量总结改并发（TaskGroup + 信号量限流）
    /// 云端 API 允许 3 路并发，本地模型退化为串行（并发=1）
    // MARK: - 编辑转写片段（支持撤销）

    private var editUndoStack: [(segment: TranscriptSegment, originalText: String)] = []

    var canUndo: Bool { !editUndoStack.isEmpty }

    // MARK: - 修改录音标题

    /// 更新录音标题并同步到文件夹
    func updateRecordingTitle(_ recording: AudioRecording, newTitle: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.renameEntry) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recording.fileName = trimmed
        recording.saveMetaToFolder()
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "标题保存失败，请重试。"))
        }
    }

    // MARK: - 修改总结

    /// 更新总结内容并同步到文件夹（加密存储）
    func updateRecordingSummary(_ recording: AudioRecording, newSummary: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editSummary) else { return }
        let trimmed = newSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try SummaryHistory.preserve(recording.summary, in: recording.folderURL) }
        catch {
            showErrorMessage(String(localized: "无法保存总结历史，已保留原内容并停止替换。"))
            return
        }
        // 保持与生成总结时一致的加密存储逻辑
        do {
            recording.summary = try EncryptionService.encrypt(trimmed)
        } catch {
            EncryptionService.reportEncryptionFailure(error, context: "总结编辑后")
            recording.summary = trimmed
        }
        if recording.summaryGeneratedAt == nil {
            recording.summaryGeneratedAt = Date()
        }
        saveSummaryToFolder(recording)
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "总结保存失败，请重试。"))
        }
    }


    // MARK: - 修改画面要点

    /// 更新画面要点内容并同步到文件夹（加密存储，与总结编辑同策略）
    func updateRecordingVisualSummary(_ recording: AudioRecording, newVisualSummary: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editVisualSummary) else { return }
        let trimmed = newVisualSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 保持与生成画面要点时一致的加密存储逻辑
        do {
            recording.visualSummary = try EncryptionService.encrypt(trimmed)
        } catch {
            EncryptionService.reportEncryptionFailure(error, context: "画面要点编辑后")
            recording.visualSummary = trimmed
        }
        if recording.visualSummaryGeneratedAt == nil {
            recording.visualSummaryGeneratedAt = Date()
        }
        Task { await saveVisualSummaryToFolder(recording) }
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "画面要点保存失败，请重试。"))
        }
    }

    // MARK: - 隐藏/取消隐藏录音

    /// 切换录音的隐藏状态
    func toggleRecordingHidden(_ recording: AudioRecording, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.hideEntry) else { return }
        recording.isHidden.toggle()
        recording.saveMetaToFolder()
        do {
            try context.save()
        } catch {
            showErrorMessage("隐藏状态保存失败，请重试。")
        }
        // 如果隐藏了当前选中的录音，取消选中
        if recording.isHidden && selectedRecording?.id == recording.id {
            selectedRecording = nil
        }
    }

    func updateSegmentText(_ segment: TranscriptSegment, newText: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editTranscript) else { return }
        let originalText = segment.text
        editUndoStack.append((segment: segment, originalText: originalText))
        // 加密保存编辑后的文本
        do {
            segment.text = try EncryptionService.encrypt(newText)
        } catch {
            EncryptionService.reportEncryptionFailure(error, context: "转写片段编辑后")
            segment.text = newText
        }
        PersistenceReporting.saveOrReport { try context.save() }
        // 同步到文件夹
        if let recording = segment.recording {
            saveTranscriptToFolder(recording)
            invalidateTranscriptCache(recording)
        }
    }

    /// 转写内容写路径统一失效入口：**先清渲染缓存，再递增版本号**驱动 UI 重建。
    ///
    /// 顺序不可颠倒。旧实现先递增版本号、再用 fire-and-forget 的 `Task` 异步清缓存：
    /// 版本变化会让 `TranscriptView` 的 `.task(id:)` 立刻重载，而清缓存可能还没执行完，
    /// 重载就命中了变更前的旧缓存条目，UI 一直停留在旧内容——表现为「声纹标记后
    /// 转写页仍显示『说话人 N』」，且此后没有新的版本变化，就一直不再刷新。
    private func invalidateTranscriptCache(_ recording: AudioRecording) {
        let recordingID = recording.id
        Task { @MainActor in
            await TranscriptCache.invalidate(recordingID: recordingID)
            transcriptVersion += 1
        }
    }

    /// 更新转写内容的 Markdown 文本（编辑后替换为单个片段）
    func updateTranscriptMarkdown(_ recording: AudioRecording, newMarkdown: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editTranscript) else { return }
        let trimmed = newMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 保留原始时间范围
        let sortedSegments = recording.segments.sorted { $0.startTime < $1.startTime }
        let startTime = sortedSegments.first?.startTime ?? 0
        let endTime = sortedSegments.last?.endTime ?? 0

        // 清空撤销栈
        editUndoStack.removeAll()

        // 删除所有现有片段
        for segment in recording.segments {
            context.delete(segment)
        }

        // 创建单个片段存储编辑后的文本
        let encrypted: String
        do {
            encrypted = try EncryptionService.encrypt(trimmed)
        } catch {
            EncryptionService.reportEncryptionFailure(error, context: "转写 Markdown 编辑后")
            encrypted = trimmed
        }
        let newSegment = TranscriptSegment(startTime: startTime, endTime: endTime, text: encrypted)
        newSegment.recording = recording
        context.insert(newSegment)

        PersistenceReporting.saveOrReport { try context.save() }
        saveTranscriptToFolder(recording)
        invalidateTranscriptCache(recording)
    }

    /// 声纹标记（手动注册）：提取录音中指定说话人的声纹并注册到声纹库，
    /// 同时把本录音中该说话人的标注批量更新为姓名（下次转写可自动识别）。
    /// 失败时抛出错误由 UI 提示；音频片段不足、同名冲突等均有具体错误描述。
    func markVoiceprint(
        recording: AudioRecording,
        speaker: String,
        name: String,
        modelPath: String,
        context: ModelContext
    ) async throws {
        if let blocked = persistence.rejection(for: .editTranscript) {
            showErrorMessage(blocked.message)
            throw blocked
        }
        // 声纹属生物识别信息：没有单独同意就不得生成（设置页只是偏好，不能替代同意）
        guard MemoziaPrivacyPolicy.voiceprintConsentGranted() else {
            throw VoiceprintError.consentRequired
        }
        let ranges = recording.segments
            .filter { $0.speaker == speaker }
            .map { (start: $0.startTime, end: $0.endTime) }
        guard !ranges.isEmpty else { throw VoiceprintError.insufficientAudio }

        let (embedding, sampleCount) = try await SpeakerDiarizationService.shared.extractVoiceprint(
            audioURL: recording.fileURL,
            modelPath: modelPath,
            ranges: ranges
        )
        // 注册（库内自动相似度查重：同名同人更新、异名冲突报错）
        try VoiceprintStore.register(
            name: name,
            embedding: embedding,
            sampleCount: sampleCount,
            recordingId: recording.id.uuidString
        )
        VoiceprintLibrary.shared.reload()

        // 注册成功后自动把声纹姓名同步进去标识化词典（此前仅设置页手动“更新去标识化”
        // 才同步，新注册姓名会原样上云，造成脱敏覆盖不一致）
        _ = PIIScrubService.syncFromVoiceprints()

        // 批量更新本录音的说话人标注（transcriptMarkdown 为计算属性自动生效）
        for segment in recording.segments where segment.speaker == speaker {
            segment.speaker = name
        }
        PersistenceReporting.saveOrReport { try context.save() }
        saveTranscriptToFolder(recording)
        invalidateTranscriptCache(recording)
    }

    func undoLastEdit(context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editTranscript) else { return }
        guard let last = editUndoStack.popLast() else { return }
        last.segment.text = last.originalText
        PersistenceReporting.saveOrReport { try context.save() }
        // 同步到文件夹
        if let recording = last.segment.recording {
            saveTranscriptToFolder(recording)
            invalidateTranscriptCache(recording)
        }
    }

    // MARK: - 会议录音（macOS）

    /// 会议录音服务（参考 whisperLocalService 的单例模式）
    /// 直接暴露给 View 观察，避免 computed property 不追踪 @Observable 依赖
    let meetingRecorder = MeetingRecorderService.shared

    /// B-6: 启动时重置上次崩溃遗留的 .processing 状态
    /// - Parameter context: SwiftData 上下文
    func resetStaleProcessingStates(context: ModelContext) {
        var hasReset = false
        // 说明：这里本意是用 #Predicate 只取「有 .processing 状态」的条目（无谓词全表
        // fetch 会物化 summary 等大文本列）。但 SwiftData 的 #Predicate 不支持对
        // 可选枚举属性（ProcessingStatus?）做等值比较（"Member access without an
        // explicit base is not supported"），故维持全表 fetch。启动一次性成本，
        // 待 SwiftData 支持后可按状态谓词裁剪。
        let descriptor = FetchDescriptor<AudioRecording>()
        if let recordings = try? context.fetch(descriptor) {
            for recording in recordings {
                if recording.transcriptionStatus == .processing {
                    recording.transcriptionStatus = .pending
                    hasReset = true
                }
                if recording.summaryStatus == .processing {
                    recording.summaryStatus = .pending
                    hasReset = true
                }
                if recording.visualStatus == .processing {
                    recording.visualStatus = .pending
                    hasReset = true
                }
                if recording.todoStatus == .processing {
                    recording.todoStatus = .pending
                    hasReset = true
                }
            }
        }
        let noteDescriptor = FetchDescriptor<QuickNote>()
        if let notes = try? context.fetch(noteDescriptor) {
            for note in notes {
                if note.summaryStatus == .processing {
                    note.summaryStatus = .pending
                    hasReset = true
                }
                if note.todoStatus == .processing {
                    note.todoStatus = .pending
                    hasReset = true
                }
            }
        }
        if hasReset {
            // 这处保存失败的用户可见后果最重：状态没落库，下次启动又会读到 .processing，
            // 条目在列表里永久停在“处理中”。旧写法 `try? ` 吞掉异常，日志里一无所有
            PersistenceReporting.saveOrReport { try context.save() }
        }
    }

    /// 是否正在录音（绑定 UI，从 meetingRecorder 直接读取以保证 @Observable 依赖追踪）
    var isMeetingRecording: Bool { meetingRecorder.isRecording }

    #if os(macOS)
    // MARK: - 录屏状态（音频复用 meetingRecorder 现有双轨分片管线，另挂视频轨）

    private let screenVideoRecorder = ScreenVideoRecorder()
    /// 本次录屏的视频目标路径（停止时消费；非 nil 即正在录屏）
    private var screenVideoFinalURL: URL?
    var isScreenRecording: Bool { screenVideoFinalURL != nil }
    #endif

    /// 当前录音/录屏实际使用的声源（停止入口取此而非设置默认值；跨平台声明，
    /// 供未受平台守卫的启停链路读写）
    private(set) var activeRecordingSource: RecordingSource?
    /// 录音时长（绑定 UI）
    var recordingElapsed: TimeInterval { meetingRecorder.elapsedSeconds }
    /// 麦克风是否静音（绑定 UI）
    var isRecordingMuted: Bool { meetingRecorder.isMicMuted }
    /// 静音来源（绑定 UI）
    var recordingMuteSource: MuteSource { meetingRecorder.muteSource }

    /// 开始会议录音
    /// - Parameters:
    ///   - config: 录音配置
    ///   - context: SwiftData 上下文（录音停止后用于创建记录）
    func startMeetingRecording(config: RecordingConfig, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.createEntry) else { return }
        startRecordingCore(config: config, context: context)
    }

    /// 开始录屏（录音管线 + 视频轨）。区域/窗口目标由调用方（RootView 选取层）解析完成后传入；
    /// 声源（仅麦克风/仅系统音频/混合）与质量档位由调用方从录屏独立偏好读入。
    /// 「录音开始时静音麦克风」偏好与录音共用一份（截图会话工具栏的麦克风菜单也可改），
    /// 这里在启动瞬间读取，保证开场即按用户预期静音
    #if os(macOS)
    func startScreenRecording(
        target: ScreenRecordingTarget,
        source: RecordingSource,
        quality: ScreenRecordingQuality,
        context: ModelContext
    ) {
        guard !rejectWriteIfReadOnly(.createEntry) else { return }
        startScreenRecordingCore(
            config: RecordingConfig(
                source: source,
                startMuted: MicrophoneStartMutePreference.isEnabled()
            ),
            context: context,
            target: target,
            quality: quality
        )
    }
    #endif

    private func startRecordingCore(config: RecordingConfig, context: ModelContext) {
        // 合并进行中禁止开始新录音：消除同秒 stop→start 竞态
        //（上一条录音的合并还在写文件夹时就开启新会话，20260910 事故的放大器）
        guard !isMergingAudio else {
            showErrorMessage(String(localized: "上一条录音正在合并，请稍候再开始新录音。"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await meetingRecorder.startRecording(config: config)
                activeRecordingSource = config.source
                attachMeetingRecorderHooks(config: config, context: context)
            } catch {
                showErrorMessage(String(localized: "录音启动失败：\(UserFacingError.summary(for: error))"))
            }
        }
    }

    #if os(macOS)
    /// 录屏启动：先启音频（复用分片/混音管线），再在同文件夹同基名写 {base}_video.mp4；
    /// 视频启动失败整体中止并清理刚建文件夹，不留“只有音频的半条录屏”
    private func startScreenRecordingCore(
        config: RecordingConfig,
        context: ModelContext,
        target: ScreenRecordingTarget,
        quality: ScreenRecordingQuality
    ) {
        guard !isMergingAudio else {
            showErrorMessage(String(localized: "上一条录音正在合并，请稍候再开始新录音。"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let finalAudioURL = try await meetingRecorder.startRecording(config: config)
                let folderDir = finalAudioURL.deletingLastPathComponent()
                let base = finalAudioURL.deletingPathExtension().lastPathComponent
                let videoURL = folderDir.appendingPathComponent(
                    AudioConverter.retainedVideoName(base: base, ext: "mp4")
                )
                do {
                    try await screenVideoRecorder.start(
                        to: videoURL,
                        target: target,
                        quality: quality,
                        includeSystemAudio: config.source != .microphone
                    )
                } catch {
                    _ = await meetingRecorder.stopRecording()
                    try? FileManager.default.removeItem(at: folderDir)
                    showErrorMessage(String(format: String(localized: "录屏启动失败：%@，未开始录音。"), UserFacingError.summary(for: error)))
                    return
                }
                screenVideoFinalURL = videoURL
                // 视频轨已启动：标记本次会话为录屏，菜单栏据此显示「录屏中/停止录制」
                meetingRecorder.isScreenRecording = true
                activeRecordingSource = config.source
                attachMeetingRecorderHooks(config: config, context: context)
                attachScreenRecorderHooks(context: context, source: config.source)
            } catch {
                showErrorMessage(String(format: String(localized: "录屏启动失败：%@"), UserFacingError.summary(for: error)))
            }
        }
    }
    #endif

    /// 录音过程中的重要告警实时上抛（磁盘不足/系统音频中断/唤醒恢复等），
    /// 当前问题用常驻横幅，恢复用短暂反馈；保存失败才进入错误对话框。
    private func attachMeetingRecorderHooks(config: RecordingConfig, context: ModelContext) {
        meetingRecorder.onRecordingWarning = { [weak self] message in
            guard let self else { return }
            liveRecordingWarning = message
            // 实时采集问题不阻塞用户操作；实际无法保存由停录结果明确报错。
        }
        meetingRecorder.onRecordingStatus = { [weak self] message in
            guard let self else { return }
            if meetingRecorder.hasOngoingCaptureIssue {
                liveRecordingWarning = message
            } else {
                liveRecordingWarning = nil
                // 正常设备协商已自动完成、没有采集影响时，仅收起恢复横幅。
                guard let feedback = message else { return }
                guard lastRecoveredFeedback != feedback else { return }
                lastRecoveredFeedback = feedback
                recordingFeedback = RecordingFeedback(
                    message: feedback, isWarning: meetingRecorder.recordingCaptureReport.hasWarning
                )
            }
        }
        liveRecordingWarning = nil
        lastRecoveredFeedback = nil
        // 磁盘临界止损：走 ViewModel 的正常停止流程（合并分片 + 入库 + 提示）。
        // 不能让服务自己 stop：那样只有磁盘文件、没有数据库条目，
        // 用户会当作“录音丢了”（只能等下次扫描补录）
        meetingRecorder.onRequestStopForDiskPressure = { [weak self] in
            guard let self, self.meetingRecorder.isRecording else { return }
            Task {
                await self.stopMeetingRecording(context: context, source: config.source)
            }
        }
    }

    #if os(macOS)
    /// 视频轨钩子：空间不足走统一停止流程（音视一起收尾）；采集中断只提示，
    /// 录音继续（视频保留到中断时刻，碎片化 MP4 可直接回放）
    private func attachScreenRecorderHooks(context: ModelContext, source: RecordingSource) {
        screenVideoRecorder.onDiskCritical = { [weak self] in
            guard let self, self.meetingRecorder.isRecording else { return }
            Task {
                await self.stopMeetingRecording(context: context, source: source)
            }
        }
        screenVideoRecorder.onInterrupted = { [weak self] message in
            // 视频轨已中断、音频继续：本次会话不再是录屏，菜单栏回退为「录音中」
            self?.meetingRecorder.isScreenRecording = false
            self?.liveRecordingWarning = message
        }
    }
    #endif

    /// 停止会议录音/录屏并创建 AudioRecording 记录
    /// - Parameters:
    ///   - context: SwiftData 上下文
    ///   - source: 录音来源（用于命名和记录）
    func stopMeetingRecording(context: ModelContext, source: RecordingSource) async {
        // 重入保护：停止流程进行中再次触发（用户点击 + 磁盘临界止损）时直接返回，
        // 避免第二次调用的 defer 提前清空第一路仍在使用的实时告警/止损回调
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        recordingFeedback = nil
        var processingIssues: [RecordingCaptureReport.Issue] = []
        // 停录后的异常统一进入最终摘要；合并错误不能同时走实时弹窗再重复提示。
        meetingRecorder.onRecordingWarning = nil
        meetingRecorder.onRecordingStatus = nil
        // F-3: 录音合并进行中标志，便于 UI 反馈合并进度
        isMergingAudio = true
        defer {
            isStoppingRecording = false
            isMergingAudio = false
            // 合并已结束（无论成败）：解除实时告警接管并清理横幅
            meetingRecorder.onRecordingWarning = nil
            meetingRecorder.onRecordingStatus = nil
            meetingRecorder.onRequestStopForDiskPressure = nil
            liveRecordingWarning = nil
            activeRecordingSource = nil
            #if os(macOS)
            screenVideoRecorder.onDiskCritical = nil
            screenVideoRecorder.onInterrupted = nil
            #endif
        }

        // 先停音频并合并（m4a 是录屏 mp4 的最终声源：麦克风+系统声完整混音，混流需先行就绪）
        //
        // 但停止顺序被拆开：用户点击停止后，**两路采集立即停下**，合并/混流随后异步完成。
        // 旧写法先 `await stopRecording()`（内部含分片合并）再停视频，合并越慢视频录得越多，
        // 仍继续编码写盘；磁盘临界止损时更不利。

        // 录屏视频文件名（iOS 无录屏能力，恒为 nil）
        var screenVideoFileName: String?

        #if os(macOS)
        let screenVideoTargetName = screenVideoFinalURL?.lastPathComponent
        screenVideoFinalURL = nil
        // 视频轨：有本次目标路径则**并行收尾**（stop() 内部先 stopCapture 停采集、再 finishWriting
        // 封装容器），与下方音频采集停止同时开始；无目标但仍在采集（异常恢复路径兼容）只停采集
        let videoFinalizeTask: Task<URL?, Never>? = screenVideoTargetName != nil
            ? Task { await self.screenVideoRecorder.stop() }
            : nil
        if videoFinalizeTask == nil {
            screenVideoRecorder.stopCaptureOnly()
        }
        #endif

        // 立即停止音频采集（不等待合并）
        let captured = await meetingRecorder.stopCapturing()

        // 异步完成音频合并（视频轨收尾已在并行进行，不再串行等待其结束）
        let mergedAudioURL: URL?
        if let captured {
            mergedAudioURL = await meetingRecorder.mergeCapturedSegments(captured)
        } else {
            mergedAudioURL = nil
        }

        #if os(macOS)
        if let screenVideoTargetName, let videoFinalizeTask {
            if let finalized = await videoFinalizeTask.value,
               await ScreenVideoRecorder.hasPlayableVideoTrack(finalized) {
                // 目标路径即入队时的 videoURL（stop 回传同一 URL），文件名按原始约定记录
                screenVideoFileName = screenVideoTargetName
                // 混流：把含麦克风的完整混音嵌入 mp4 作为唯一音轨（passthrough 不转码）；
                // 失败保留原文件（可能仅有系统声轨/无声），不影响条目与音频入库
                if let mergedAudioURL {
                    do {
                        _ = try await AudioConverter.embedAudio(into: finalized, from: mergedAudioURL)
                    } catch {
                        processingIssues.append(.videoDegraded)
                        FileSyncService.logWarning("停录后视频混流失败：\(UserFacingError.technicalDetail(for: error))")
                    }
                }
            } else {
                processingIssues.append(.videoDegraded)
            }
        }
        #endif

        var report = meetingRecorder.recordingCaptureReport
        report.issues.append(contentsOf: processingIssues)
        #if os(macOS)
        if screenVideoRecorder.lastError != nil {
            if !report.issues.contains(.videoDegraded) { report.issues.append(.videoDegraded) }
            screenVideoRecorder.lastError = nil
        }
        #endif
        guard let url = mergedAudioURL else {
            // 不能让历史「已恢复」提醒掩盖本次没有可播放产物的真正失败。
            if let folder = captured?.finalURL.deletingLastPathComponent() {
                do { try RecordingCaptureReportStore.save(report, in: folder) }
                catch { PersistenceReporting.reportSaveFailure(error, scene: "停录失败时保存采集详情") }
            }
            let message = String(localized: "录音保存失败，未能生成可播放文件。已有分片已保留，请检查录音文件夹。")
            showErrorMessage([message, meetingRecorder.lastError].compactMap { $0 }.joined(separator: "\n"),
                             folder: captured?.finalURL.deletingLastPathComponent())
            return
        }

        let duration: TimeInterval
        do {
            duration = try await AudioConverter.getDuration(of: url)
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            FileSyncService.logWarning("停录后音频时长校验失败：\(UserFacingError.technicalDetail(for: error))")
            do { try RecordingCaptureReportStore.save(report, in: url.deletingLastPathComponent()) }
            catch { PersistenceReporting.reportSaveFailure(error, scene: "时长校验失败时保存采集详情") }
            showErrorMessage(String(localized: "录音文件无法确认有效时长，文件已保留，请检查后重试。"),
                             folder: url.deletingLastPathComponent())
            return
        }

        let storedFileName = url.lastPathComponent
        // 从 URL 提取文件夹名（父目录名）
        let folderName = url.deletingLastPathComponent().lastPathComponent
        #if os(macOS)
        let displayName = screenVideoFileName != nil
            ? String(format: String(localized: "录屏 %@"), Date().formatted(date: .abbreviated, time: .shortened))
            : String(format: String(localized: "会议录音 %@"), Date().formatted(date: .abbreviated, time: .shortened))
        #else
        let displayName = String(format: String(localized: "会议录音 %@"), Date().formatted(date: .abbreviated, time: .shortened))
        #endif

        let recording = AudioRecording(
            fileName: displayName,
            fileExtension: "m4a",
            duration: duration,
            storedFileName: storedFileName,
            recordingSource: source,
            folderName: folderName,
            videoFileName: screenVideoFileName
        )

        await finishRecordingSave(recording: recording, report: report, context: context)
        meetingRecorder.lastError = nil
    }

    /// 文件系统先落盘，数据库随后更新；任何关键保存失败都不发布「已保存」反馈。
    func finishRecordingSave(
        recording: AudioRecording, report: RecordingCaptureReport, context: ModelContext
    ) async {
        recordingFeedback = nil
        guard !rejectWriteIfReadOnly(.createEntry) else { return }
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            showErrorMessage(String(localized: "录音停止失败：未找到录音文件"), folder: recording.folderURL)
            return
        }
        var reportSaved = true
        do { try RecordingCaptureReportStore.save(report, in: recording.folderURL) }
        catch {
            reportSaved = false
            PersistenceReporting.reportSaveFailure(error, scene: "保存录音采集详情")
        }
        let metadataSaved = recording.saveMetaToFolder()
        context.insert(recording)
        var databaseSaved = true
        do { try await saveContextWithRetry(context) }
        catch {
            databaseSaved = false
            showErrorMessage(String(localized: "录音记录保存到数据库失败：\(UserFacingError.summary(for: error))\n录音文件已保存在磁盘上，请重启应用后检查是否自动恢复。"), folder: recording.folderURL)
        }
        selectedRecording = recording
        guard reportSaved, metadataSaved, databaseSaved else { return }
        let saved = String(localized: "录音已保存。")
        recordingFeedback = RecordingFeedback(
            message: [saved, report.summary].compactMap { $0 }.joined(separator: "\n"),
            isWarning: report.hasWarning, folderName: recording.folderName
        )
    }

    /// 保存 SwiftData 上下文，失败时短退避重试（应对长录音合并后的瞬时句柄耗尽）；
    /// 每次失败记录完整错误与当前打开句柄数，便于定位根因
    private func saveContextWithRetry(_ context: ModelContext, attempts: Int = 3) async throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try context.save()
                return
            } catch {
                lastError = error
                FileSyncService.logWarning(
                    "数据库保存失败（第 \(attempt + 1)/\(attempts) 次）: \(error.localizedDescription)，" +
                    "当前打开句柄数=\(ProcessLimits.openFileDescriptorCount())"
                )
                guard attempt < attempts - 1 else { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// 静音切换后的恢复结果由当前采集事件反馈，不能把旧磁盘告警误报成恢复失败。
    func toggleRecordingMute() {
        meetingRecorder.toggleLocalMute()
    }

    // MARK: - 文件持久化（转写记录、总结保存到文件夹）

    /// 将转写记录以 JSON 格式保存到录音文件夹（G-1: 加密存储）
    ///
    /// 性能设计：JSON 序列化与整体加密对长转写是数十毫秒级主线程开销，
    /// 主线程只做 SwiftData 快照，序列化+加密+写盘移入后台。
    ///
    /// 解密也一并移出主线程：旧实现在主线程 `segments.map { seg.decryptedText }` 逐段
    /// AES-GCM（数千段长会议在停止/编辑时可见卡顿），现在主线程只取 Sendable 的
    /// **原始密文串 + 时间/说话人**，解密在串行队列上完成后再提交（串行保证提交次序）
    func saveTranscriptToFolder(_ recording: AudioRecording) {
        guard !rejectWriteIfReadOnly(.writeMirror) else { return }
        guard !recording.folderName.isEmpty else { return }
        recording.transcriptModifiedAt = Date()

        let segments = recording.segments.sorted { $0.startTime < $1.startTime }
        // speaker 必须随盘持久化：磁盘恢复（loadTranscriptIfNeeded）以此重建片段，
        // 不存则崩溃/保存失败恢复后说话人标签与声纹姓名全部丢失
        let snapshot: [(startTime: TimeInterval, endTime: TimeInterval, speaker: String?, rawText: String)] =
            segments.map { seg in
                (
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    speaker: (seg.speaker?.isEmpty == false) ? seg.speaker : nil,
                    rawText: seg.text
                )
            }

        let folderName = recording.folderName
        let fileURL = recording.transcriptFileURL
        // 交给 EntryMirrorStore：同一条目连续保存合并为「只写最新一份」，退出前由 flush()
        // 等待落盘（旧实现是 detached 一把火，保存完立刻退出即丢最后一次修改）
        transcriptMirrorQueue.async {
            let items: [TranscriptMirrorItem] = snapshot.map { entry in
                TranscriptMirrorItem(
                    startTime: entry.startTime,
                    endTime: entry.endTime,
                    speaker: entry.speaker,
                    text: EncryptionService.decryptSafely(entry.rawText)
                )
            }
            EntryMirrorStore.shared.submitTranscript(items, folderName: folderName, to: fileURL)
        }
    }

    /// 将总结以 Markdown 格式保存到录音文件夹（G-1: 加密存储）
    /// 转写保存同款后台写入策略（见 saveTranscriptToFolder）
    func saveSummaryToFolder(_ recording: AudioRecording) {
        guard !rejectWriteIfReadOnly(.writeMirror) else { return }
        guard !recording.folderName.isEmpty else { return }

        let summary = recording.decryptedSummary
        guard !summary.isEmpty else { return }

        let folderName = recording.folderName
        let fileURL = recording.summaryFileURL
        // 与转写同入口：合并连续写入 + 退出前 flush（见 EntryMirrorStore）
        EntryMirrorStore.shared.submit(
            summary,
            kind: .summary,
            folderName: folderName,
            to: fileURL
        )
    }

    /// 将画面要点以加密镜像写入条目文件夹（visual.md），写入策略与 `saveSummaryToFolder` 一致
    func saveVisualSummaryToFolder(_ recording: AudioRecording) async -> Bool {
        guard !rejectWriteIfReadOnly(.writeMirror) else { return false }
        guard !recording.folderName.isEmpty else { return false }

        let notes = recording.decryptedVisualSummary
        guard !notes.isEmpty else { return false }

        let folderName = recording.folderName
        let fileURL = recording.visualFileURL
        // 必须等待写入结果：调用方据此决定能否删除分析检查点（写入失败就不能删）
        return await EntryMirrorStore.shared.writeNow(
            notes,
            kind: .visual,
            folderName: folderName,
            to: fileURL
        )
    }

    // MARK: - 合并录音

    /// 创建时间相同则以稳定 ID 决定顺序，避免 Set 的枚举顺序改变合并目标。
    static func orderedMergeCandidates(_ recordings: [AudioRecording]) -> [AudioRecording]? {
        guard recordings.count >= 2, Set(recordings.map(\.id)).count == recordings.count,
              recordings.allSatisfy({ !$0.isVideoRecording }) else { return nil }
        return recordings.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// 仅在用户确认合并并删除原录音后调用。先保存完整新条目，再逐笔删除较早原件。
    func mergeRecordings(_ recordings: [AudioRecording], context: ModelContext) async -> AudioRecording? {
        guard !rejectWriteIfReadOnly(.deleteEntry),
              let ordered = Self.orderedMergeCandidates(recordings), let latest = ordered.last else { return nil }
        guard !RecordingMergeActivity.shared.isRunning, !FileSyncService.hasResourcesPreventingUpdate,
              !AppUpdateService.shared.isPreparingToInstall, !isImporting, !isTranscribing,
              summarizingRecordingIDs.isEmpty, extractingTodoIDs.isEmpty, titleTasks.isEmpty,
              !isGeneratingVisualNotes, !isWritingTodos, !isCleaningUpVideo,
              !meetingRecorder.hasResourcesPreventingUpdate, !TaskCenter.shared.hasActiveWork,
              TaskCenter.shared.stoppingResourceClasses.isEmpty,
              TaskCenter.shared.restartRequiredResourceClasses.isEmpty,
              !BackgroundTaskQueue.hasEntries(),
              ordered.allSatisfy({ $0.modelContext === context
                  && $0.transcriptionStatus != .processing && $0.summaryStatus != .processing
                  && $0.todoStatus != .processing && $0.visualStatus != .processing }) else {
            showErrorMessage(String(localized: "请等待录音、处理任务和磁盘同步完成后再合并。"))
            return nil
        }
        RecordingMergeActivity.shared.isRunning = true
        defer { RecordingMergeActivity.shared.isRunning = false }
        do {
            try context.save()
            // 等待串行解密队列先提交镜像，再等待镜像落盘，防止迟到的旧镜像覆盖合并结果。
            await withCheckedContinuation { continuation in
                transcriptMirrorQueue.async { continuation.resume() }
            }
            let flush = await EntryMirrorStore.shared.flush()
            guard flush.remaining.isEmpty, flush.errors.isEmpty else { throw RecordingMergeService.MergeError() }
            let snapshots = ordered.map {
                RecordingMergeService.Input(id: $0.id, folderName: $0.folderName, folderURL: $0.folderURL,
                    audioURL: $0.fileURL, title: $0.fileName, segments: $0.transcriptSnapshot,
                    summary: $0.summary, isHidden: $0.isHidden,
                    transcriptionComplete: $0.transcriptionStatus == .completed)
            }
            let dedicatedFolders = snapshots.filter { !$0.folderName.isEmpty }.map(\.folderURL)
            guard Set(snapshots.map(\.audioURL)).count == snapshots.count,
                  Set(dedicatedFolders).count == dedicatedFolders.count else { throw RecordingMergeService.MergeError() }
            // 旧式根目录音频也可合并；最新条目按既有原子分配规则获得独立目录。
            let newFolderName: String?
            if latest.folderName.isEmpty {
                guard let allocated = AudioRecording.createUniqueFolder(from: latest.createdAt) else {
                    throw RecordingMergeService.MergeError()
                }
                newFolderName = allocated
            } else { newFolderName = nil }
            let destination = newFolderName.map { AudioRecording.resolveFolderURL(forFolderName: $0) } ?? latest.folderURL
            var preserveDestination = newFolderName == nil
            defer { if !preserveDestination { RecordingMergeService.removeStaging(destination) } }
            let prepared = try await RecordingMergeService().prepare(snapshots, destinationURL: destination)
            var shouldRemoveStaging = true
            defer { if shouldRemoveStaging { RecordingMergeService.removeStaging(prepared.stagingURL) } }
            try Task.checkCancellation()
            try RecordingMergeService.swap(prepared)
            preserveDestination = true
            do {
                for old in latest.segments { context.delete(old) }
                latest.segments = zip(prepared.segments, prepared.encryptedTexts).map { item, encrypted in
                    let segment = TranscriptSegment(startTime: item.startTime, endTime: item.endTime,
                                                    speaker: item.speaker, text: encrypted)
                    segment.recording = latest
                    return segment
                }
                latest.storedFileName = prepared.audioName
                if let newFolderName { latest.folderName = newFolderName }
                latest.fileExtension = "m4a"
                latest.duration = prepared.duration
                latest.transcriptionStatus = ordered.allSatisfy { $0.transcriptionStatus == .completed } ? .completed : .pending
                latest.transcriptModifiedAt = Date()
                latest.summary = prepared.encryptedSummary
                latest.summaryGeneratedAt = prepared.encryptedSummary == nil ? nil : Date()
                latest.summaryStatus = prepared.encryptedSummary == nil ? .pending : .completed
                latest.todoStatus = prepared.hasTodos ? .completed : .pending
                latest.isMeeting = nil
                latest.meetingJudgedBy = nil
                latest.meetingJudgedAt = nil
                latest.errorMessage = nil
                try context.save()
            } catch {
                // 此处尚未删除任何源录音。恢复整个旧条目后回滚本次索引修改。
                do {
                    try RecordingMergeService.swap(prepared)
                    preserveDestination = newFolderName == nil
                }
                catch {
                    // 无法回滚时保留 staging 中的旧原件，不能由 defer 清除。
                    shouldRemoveStaging = false
                    recordingFailureFolder = prepared.stagingURL
                    PersistenceReporting.reportSaveFailure(error)
                }
                context.rollback()
                throw error
            }
            invalidateTranscriptCache(latest)
            // 合并保留所有待办及 reminderIdentifier；删除源条目不能清理已转移的提醒事项。
            var deletionFailed = false
            for recording in ordered.dropLast() {
                do {
                    let original = recording.folderName.isEmpty ? recording.fileURL : recording.folderURL
                    try FileManager.default.removeItem(at: original)
                    context.delete(recording)
                    try context.save()
                } catch {
                    context.rollback()
                    PersistenceReporting.reportSaveFailure(error)
                    deletionFailed = true
                    break
                }
            }
            if newFolderName != nil, let original = snapshots.last?.audioURL {
                do { try FileManager.default.removeItem(at: original) }
                catch {
                    PersistenceReporting.reportSaveFailure(error)
                    deletionFailed = true
                }
            }
            selectedRecording = latest
            loadTodoDocument(for: latest)
            TodoDocument.postDidChange(folder: latest.folderURL)
            if deletionFailed {
                showErrorMessage(String(localized: "音频已合并，部分原录音未能删除。请删除剩余的原录音，勿重复合并。"))
            }
            return latest
        } catch {
            PersistenceReporting.reportSaveFailure(error)
            showErrorMessage(String(localized: "合并录音失败：\(UserFacingError.summary(for: error))"))
            return nil
        }
    }

    // MARK: - 删除

    /// 删除录音：同时删除数据库记录和磁盘上的录音文件
    /// - Parameters:
    ///   - recording: 要删除的录音
    ///   - context: SwiftData 上下文
    ///   - deleteFile: 是否同时删除磁盘文件，默认为 true
    func deleteRecording(_ recording: AudioRecording, context: ModelContext, deleteFile: Bool = true) {
        guard !rejectWriteIfReadOnly(.deleteEntry) else { return }
        // 按条目 id 取消该条目上正在跑的总结/待办/标题：无论是否当前展示条目，
        // 都要停掉它会继续落盘到「即将删除文件夹」的任务
        cancelSummary(recordingID: recording.id)
        cancelTodoExtraction(recordingID: recording.id)
        cancelTitle(recordingID: recording.id)
        if selectedRecording?.id == recording.id {
            cancelTranscription()
            // 画面要点生成中删条目：不取消会让抽帧与写入继续落在已删目录上
            cancelVisualNotes()
        }

        // P3-9: 先删除磁盘文件——若失败则保留数据库记录，防止下次 syncFromDisk 数据复活
        if deleteFile {
            if !recording.folderName.isEmpty {
                let folderURL = recording.folderURL
                if FileManager.default.fileExists(atPath: folderURL.path) {
                    do {
                        try FileManager.default.removeItem(at: folderURL)
                    } catch {
                        showErrorMessage(String(localized: "录音文件夹删除失败：\(UserFacingError.summary(for: error))。数据库记录已保留以防止数据复活，请手动删除文件夹后重试。"))
                        return
                    }
                }
            } else {
                // 旧数据（无文件夹），仅删除单个音频文件
                let fileURL = recording.fileURL
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                    } catch {
                        showErrorMessage(String(localized: "录音文件删除失败：\(UserFacingError.summary(for: error))。数据库记录已保留以防止数据复活，请手动删除文件后重试。"))
                        return
                    }
                }
            }
        }

        context.delete(recording)
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "删除失败：\(UserFacingError.summary(for: error))"))
        }
        if selectedRecording?.id == recording.id {
            selectedRecording = nil
            currentTodoDocument = nil
        }
    }

    // MARK: - 待办拆解（总结 → 待办）

    /// 待办文档加载代次：丢弃过期的后台读结果（快速切换条目时避免旧内容覆盖新内容）
    @ObservationIgnored
    private var todoDocumentLoadToken = 0

    /// 从磁盘加载该录音的待办文档（切换录音时调用）
    func loadTodoDocument(for recording: AudioRecording) {
        todoDocumentLoadToken += 1
        guard !recording.folderName.isEmpty else {
            currentTodoDocument = nil
            return
        }
        // TodoDocument.load 是同步磁盘读 + 解密，而本方法在详情页 onAppear / 切换条目时调用，
        // 主线程读盘会卡住首帧。改为后台读、主线程回填，并用代次守卫丢弃过期结果
        let token = todoDocumentLoadToken
        let folderURL = recording.folderURL
        Task { [weak self] in
            let document = await Task.detached(priority: .userInitiated) {
                TodoDocument.load(from: folderURL)
            }.value
            guard let self, self.todoDocumentLoadToken == token else { return }
            self.currentTodoDocument = document
        }
    }

    /// AI 拆解总结为待办事项
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当本次确实拆出待办并已落盘
    @discardableResult
    func extractTodos(from recording: AudioRecording, llmConfig: LLMConfig) -> Task<StepOutcome, Never> {
        let recordingID = recording.id
        // 只取消「同一条目」的上一次拆解
        todoExtractionTasks[recordingID]?.cancel()
        let executionToken = UUID()
        todoExtractionExecutions[recordingID] = executionToken
        todoExtractionProgress[recordingID] = nil
        extractingTodoIDs.insert(recordingID)
        if isSelected(recordingID) { isExtractingTodos = true }
        let taskExperience = AppExperiencePreference.resolved()

        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            defer {
                if self.todoExtractionExecutions[recordingID] == executionToken {
                    self.todoExtractionExecutions[recordingID] = nil
                    self.todoExtractionTasks[recordingID] = nil
                    self.extractingTodoIDs.remove(recordingID)
                    self.todoExtractionProgress[recordingID] = nil
                    if self.isSelected(recordingID) { self.isExtractingTodos = false }
                }
            }

            let summary = recording.decryptedSummary
            guard !summary.isEmpty else {
                self.showErrorMessage("总结为空，请先生成总结")
                return .failed
            }

            do {
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                // 端点信任与模型类型解耦；待办文档返回后逐字段还原。
                let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
                let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
                    savedValue: savedPIIValue,
                    experience: taskExperience
                )
                let scrubbed = (piiEnabled && snapshot.shouldScrubText)
                    ? PIIScrubService.scrub(summary) : nil
                var document = try await TodoExtractionService.extract(
                    from: scrubbed?.scrubbed ?? summary,
                    config: snapshot,
                    source: "summary",
                    isMeeting: recording.isMeeting,
                    piiScrubbed: scrubbed != nil,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.todoExtractionExecutions[recordingID] == executionToken else { return }
                            self.todoExtractionProgress[recordingID] = progress
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.todoExtractionExecutions[recordingID] == executionToken else { throw CancellationError() }
                if let mapping = scrubbed?.mapping {
                    document = PIIScrubService.restore(document, mapping: mapping)
                }
                // 只有当前展示条目才更新共享的待办文档 UI；持久化始终按本条目的文件夹写入
                if self.isSelected(recordingID) { self.currentTodoDocument = document }
                let saved = self.saveTodosToFolder(document, for: recording)
                // 成功仅当本次确实拆出非空待办并已落盘；空结果不算成功
                return (!document.items.isEmpty && saved) ? .succeeded : .failed
            } catch is CancellationError {
                // 用户取消，静默处理
                return .cancelled
            } catch {
                self.showErrorMessage(String(localized: "待办拆解失败：\(UserFacingError.summary(for: error))"))
                return .failed
            }
        }
        todoExtractionTasks[recordingID] = task
        return task
    }

    /// 取消指定条目的待办拆解（队列「取消」入口，只影响该条目的句柄）
    func cancelTodoExtraction(recordingID: UUID) {
        todoExtractionTasks[recordingID]?.cancel()
        todoExtractionTasks[recordingID] = nil
        todoExtractionExecutions[recordingID] = nil
        todoExtractionProgress[recordingID] = nil
        extractingTodoIDs.remove(recordingID)
        if isSelected(recordingID) { isExtractingTodos = false }
    }

    /// 兼容旧入口：取消当前展示条目的待办拆解
    func cancelTodoExtraction() {
        guard let id = selectedRecording?.id else { return }
        cancelTodoExtraction(recordingID: id)
    }

    /// 把待办写入提醒事项（使用 settingsVM.defaultReminderListID）
    func writeTodosToReminders(
        recording: AudioRecording,
        defaultListID: String
    ) async {
        guard let document = currentTodoDocument else { return }
        guard !document.items.isEmpty else {
            showErrorMessage("待办列表为空，无需写入")
            return
        }

        // 显式授权检查：未授权时先请求，仍无授权则给出明确引导
        if !RemindersService.shared.isAuthorized {
            let granted = await RemindersService.shared.requestAccess()
            if !granted {
                showErrorMessage("未授权提醒事项访问，无法写入待办。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中开启 Memozia，或在「应用设置 → 待办」中点击「请求授权」后重试。")
                return
            }
        }

        isWritingTodos = true
        defer { isWritingTodos = false }

        let result = await RemindersService.shared.writeReminders(
            items: document.items,
            to: defaultListID
        )

        var updatedDocument = document
        updatedDocument.items = result.updatedItems
        currentTodoDocument = updatedDocument
        saveTodosToFolder(updatedDocument, for: recording)

        if result.failed > 0 {
            // 进一步判断失败是否因授权丢失
            if !RemindersService.shared.isAuthorized {
                showErrorMessage("待办写入失败：提醒事项授权已失效。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中重新开启 Memozia 后重试。")
            } else {
                showErrorMessage(String(localized: "部分待办写入失败：成功 \(result.success) 个，失败 \(result.failed) 个"))
            }
        }
    }

    /// 删除当前待办文档（本地与提醒事项中的记录均清除）
    func clearTodos(for recording: AudioRecording) {
        guard let document = currentTodoDocument else { return }
        // 删除已写入提醒事项中的对应记录
        var hasDeleteFailure = false
        for item in document.items where item.status == .exported {
            if let identifier = item.reminderIdentifier {
                if !RemindersService.shared.deleteReminder(identifier: identifier) {
                    hasDeleteFailure = true
                }
            }
        }
        TodoDocument.remove(from: recording.folderURL)
        currentTodoDocument = nil
        if hasDeleteFailure {
            showErrorMessage("部分提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")
        }
    }

    // MARK: - 手动增删改单个待办

    /// 手动新增一个待办（状态为 pending，未写入提醒事项）
    func addTodoItem(_ item: TodoItem, for recording: AudioRecording) {
        var document = currentTodoDocument ?? TodoDocument(
            source: "manual",
            model: String(localized: "手动添加"),
            generatedAt: Date(),
            items: []
        )
        document.items.append(item)
        currentTodoDocument = document
        saveTodosToFolder(document, for: recording)
    }

    /// 手动修改一个待办
    /// - 若该待办已写入提醒事项，同步更新 EKReminder
    func updateTodoItem(_ updatedItem: TodoItem, for recording: AudioRecording) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard var document = currentTodoDocument,
              let index = document.items.firstIndex(where: { $0.id == updatedItem.id }) else { return }

        document.items[index] = updatedItem
        currentTodoDocument = document
        saveTodosToFolder(document, for: recording)

        // 已写入提醒事项的，同步更新
        if updatedItem.status == .exported, let identifier = updatedItem.reminderIdentifier {
            Task {
                let ok = await RemindersService.shared.updateReminder(identifier: identifier, with: updatedItem)
                if !ok {
                    // 更新失败时回退状态，提示用户
                    await MainActor.run {
                        var doc = self.currentTodoDocument
                        if let i = doc?.items.firstIndex(where: { $0.id == updatedItem.id }) {
                            doc?.items[i].status = .failed
                            self.currentTodoDocument = doc
                            if let d = doc { self.saveTodosToFolder(d, for: recording) }
                        }
                        self.showErrorMessage("提醒事项同步更新失败，本地已保存。可重新点击「写入提醒事项」重试。")
                    }
                }
            }
        }
    }

    /// 手动删除一个待办
    /// - 若该待办已写入提醒事项，同步从提醒事项中删除
    func deleteTodoItem(_ item: TodoItem, for recording: AudioRecording) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard var document = currentTodoDocument,
              let index = document.items.firstIndex(where: { $0.id == item.id }) else { return }

        document.items.remove(at: index)
        currentTodoDocument = document
        saveTodosToFolder(document, for: recording)

        // 已写入提醒事项的，同步删除
        if item.status == .exported, let identifier = item.reminderIdentifier {
            if !RemindersService.shared.deleteReminder(identifier: identifier) {
                showErrorMessage("提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")
            }
        }

        // 删空了就把整个文档清掉
        if document.items.isEmpty {
            TodoDocument.remove(from: recording.folderURL)
            currentTodoDocument = nil
        }
    }

    // MARK: - 待办文件持久化

    @discardableResult
    private func saveTodosToFolder(_ document: TodoDocument, for recording: AudioRecording) -> Bool {
        guard !rejectWriteIfReadOnly(.editTodo) else { return false }
        guard !recording.folderName.isEmpty else { return false }
        do {
            try document.save(to: recording.folderURL)
            return true
        } catch {
            FileSyncService.logWarning("待办文件写入失败：\(error.localizedDescription)")
            return false
        }
    }

    private func showErrorMessage(_ message: LocalizedStringResource, folder: URL? = nil) {
        recordingFailureFolder = folder
        errorMessage = String(localized: message)
        showError = true
    }

    /// 纯文本版本：已本地化或不可本地化的动态字符串
    private func showErrorMessage(_ message: String, folder: URL? = nil) {
        recordingFailureFolder = folder
        errorMessage = message
        showError = true
    }
}


// MARK: - 磁盘写入辅助

// 说明：原先用于「旧快照不要覆盖新快照」的 FolderWriteSeqBox 序号守卫已删除。
// 镜像写入统一走 `EntryMirrorStore`：同一目标只保留最新一份内容，由唯一写者顺序落盘，
// 既不会旧盖新，也不会出现多个 detached 任务并发写同一文件。
