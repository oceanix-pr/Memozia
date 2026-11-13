import Foundation
import AVFoundation
import os.log
#if os(macOS)
import CoreAudio
import AppKit
import ScreenCaptureKit
#else
/* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
import UIKit
*/
#endif

/// 会议录音总控服务
///
/// 整合麦克风采集、系统音频采集、系统静音监听、应用层静音检测四个子服务，
/// 对外提供统一的录音控制接口。
/// macOS 支持完整功能（麦克风+系统音频+静音检测）；iOS 仅支持麦克风采集。
///
/// 设计要点：
/// - MVP 阶段：mixed 模式优先录制麦克风，系统音频作为可选增强（失败时降级）
/// - 系统 mute 检测触发时自动暂停麦克风采集；本地手动静音开关作为补充
/// - 应用层静音检测（AppMuteDetector）可自动跟随 Teams/Zoom 的静音状态
@MainActor
@Observable
final class MeetingRecorderService: @unchecked Sendable {

    private let logger = Logger(subsystem: "app.memozia", category: "MeetingRecorder")

    /// 共享实例（参考 WhisperLocalService 的单例模式）
    static let shared = MeetingRecorderService()

    // MARK: - 可观察状态（UI 绑定）

    /// 是否正在录音
    var isRecording = false
    /// 是否正在启动（从进入 startRecording 到采集真正就绪）。
    /// 与 `isRecording` 分开：启动要跨越权限弹窗、SCShareableContent 等长挂起点，
    /// 期间 isRecording 仍为 false，仅靠它无法阻止第二次点击进入并覆写共享的分片状态
    private(set) var isStarting = false
    /// 本次会话是否同时录制屏幕画面（录屏）。录屏复用本服务的音频管线，视图层（菜单栏）
    /// 需要据此把状态与停止项显示为「录屏中 / 停止录制」；与 `isRecording` 同生命周期，
    /// 采集停止即复位
    var isScreenRecording = false
    /// 麦克风是否被静音（系统 mute 或本地手动静音）
    var isMicMuted = false {
        didSet { captureHealth.microphoneMuteChanged(isMicMuted) }
    }
    /// 静音来源
    var muteSource: MuteSource = .none
    /// 录音时长（秒）
    var elapsedSeconds: TimeInterval = 0
    /// 最近错误
    var lastError: String? {
        didSet {
            // 录音过程中的重要告警（磁盘不足/系统音频中断/唤醒恢复/写入失败）实时上抛，
            // 不再静默积压到停止时才可见；清空（nil）不触发
            guard let message = lastError else { return }
            onRecordingWarning?(message)
        }
    }
    /// 实时告警出口：ViewModel 开始录音时接管、停止时解除
    var onRecordingWarning: (@MainActor (String) -> Void)?
    /// 状态更新只刷新横幅；恢复信息不作为失败再次弹窗。
    var onRecordingStatus: (@MainActor (String?) -> Void)?
    private var captureHealth = RecordingCaptureHealth()
    private var activeCaptureSession: UUID?
    private var isStoppingCapture = false
    private var wakeRecoverySession: UUID?
    /// 当前是否有「麦克风恢复失败」挂起的告警：恢复成功后据此结算，避免停录时重复提示
    private var micRecoveryError: String?

    /// 设备切换/恢复期间的状态横幅文案。
    /// 可恢复中断只更新横幅，不能被包装成「麦克风录音写入失败……建议停止后重新录制」
    private static let microphoneRecoveringBanner = String(
        localized: "麦克风正在切换，尝试恢复采集；期间麦克风声音可能缺失。"
    )

    /// 停录后保存结构化采集详情；历史影响不再决定是否弹错误窗。
    var recordingCaptureReport: RecordingCaptureReport {
        var report = captureHealth.report
        if captureHadWarningBeforeMerge || (lastError != nil && !mergeHadDegradation) {
            report.issues.append(.captureWarning)
        }
        if mergeHadDegradation { report.issues.append(.audioDegraded) }
        report.skippedSegments = skippedSegmentNames.isEmpty ? nil : skippedSegmentNames
        report.repairedSegments = repairedSegmentNames.isEmpty ? nil : repairedSegmentNames
        report.retainedOriginals = retainedOriginals ? true : nil
        report.microphoneLastSuccessfulWriteAt = microphoneLastWrite
        report.microphoneWrittenFrames = microphoneFrames
        return report
    }

    var recordingWarningSummary: String? {
        let messages = [lastError, micRecoveryError, captureHealth.summary].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// 只用于当前常驻横幅；历史中断随恢复结算，保留在 report 中。
    var hasOngoingCaptureIssue: Bool {
        lastError != nil || micRecoveryError != nil
            || captureHealth.microphone == .recovering || captureHealth.microphone == .unavailable
            || captureHealth.systemAudio == .recovering || captureHealth.systemAudio == .interrupted
    }
    /// 磁盘临界止损请求：空间已不足以安全写完下一个分片时由 ViewModel 走**正常停止流程**
    /// （合并分片 + 入库 + 提示）。不能只靠警告让用户手动停：写满磁盘会同时弄坏
    /// 当前分片与 SwiftData 数据库，代价是整段录音丢失
    var onRequestStopForDiskPressure: (@MainActor () -> Void)?
    /// 停止录音后的合并是否进行中：应用退出流程据此等待合并收尾，
    /// 避免 Cmd+Q 杀死导出留下半成品 m4a 与 .merging 标记
    private(set) var isMerging = false
    private var mergeHadDegradation = false
    private var captureHadWarningBeforeMerge = false
    private var segmentTimeline: RecordingSegmentTimelineStore?
    private var timelineSaveFailed = false
    private var skippedSegmentNames: [String] = []
    private var repairedSegmentNames: [String] = []
    private var retainedOriginals = false
    private var microphoneLastWrite: Date?
    private var microphoneFrames: Int64?
    /// 本次合并的预计完成时刻（由导出看门狗上限推得）：退出等待与看门狗**同源**，
    /// 避免旧版写死 300s（而导出可跑至 3600s）造成“等待到期→强退→事故复现”
    private(set) var mergeProjectedFinishAt: Date?

    /// 停录收尾的可观察阶段：把「检查分片 → 回声消除 → 混音导出 → 保存」拆成
    /// 独立阶段，供 UI 显示当前在做什么，避免长会议停录时用户误以为卡死
    enum MergePhase: Sendable, Equatable {
        case idle
        case inspectingSegments
        case echoReduction
        case mixing
        case saving
    }

    /// 当前停录收尾阶段
    private(set) var mergePhase: MergePhase = .idle
    /// 回声消除进度：已完成片数 / 配对总片数（非回声阶段为 0）
    private(set) var mergeProgressCompleted = 0
    private(set) var mergeProgressTotal = 0
    /// 当前阶段开始时刻：供 UI 显示已耗时
    private(set) var mergeStageStartedAt: Date?
    /// 回声消除阶段是否可请求取消（仅该阶段可取消；其余阶段不可中断，避免半成品文件）
    var canCancelEchoReduction: Bool { mergePhase == .echoReduction }
    /// 本次回声消除的取消标记：MainActor 请求取消，协作线程池里的滤波循环查询
    private var echoReductionCancelFlag: CancellationFlag?

    /// 请求取消当前停录收尾的回声消除阶段（其余阶段不响应）。取消后已处理的分片保留，
    /// 未处理的回退原始音轨，合并继续，录音照常入库。
    func requestCancelEchoReduction() {
        echoReductionCancelFlag?.cancel()
    }

    // MARK: - 子服务

    /// 麦克风采集（macOS + iOS 均可用）
    private let micCapture = MicCaptureService()
    #if os(macOS)
    private let systemCapture = SystemAudioCaptureService()
    private let muteMonitor = MicMuteMonitor()
    private let appMuteDetector = AppMuteDetector()
    #endif

    /// 录音开始时间
    private var startDate: Date?
    /// 计时器
    private var timer: Timer?
    /// 当前录音配置
    private var config: RecordingConfig = RecordingConfig()

    // MARK: - 分片滚动录音状态
    //
    // 长录音采用分片滚动写入（每 segmentDuration 轮转一次）：
    // 分片为崩溃安全的 PCM 容器（mic→CAF、sys→WAV）：头部在文件开头、数据线性追加，
    // 硬崩溃后仅需修补头部 size 字段即可恢复全部分片（见 FileSyncService 崩溃恢复），
    // 停止录音时统一拼接/合并导出为 m4a(AAC)，分片随即删除。
    // 注意：PCM 分片体积约为 AAC 的 8~10 倍（双轨合计约 1GB/小时），停止后即释放。

    /// 分片时长（秒）
    private let segmentDuration: TimeInterval = 300
    /// 录音文件夹与基础文件名（分片命名用）
    private var segmentFolderDir: URL?
    private var segmentBaseName: String?
    /// 当前分片序号（从 1 开始）
    private var segmentIndex = 0
    /// 上次轮转时间
    private var lastRotationDate: Date?
    /// 已写入的分片 URL 列表（按序号递增，停止时拼接）
    private var micSegmentURLs: [URL] = []
    private var sysSegmentURLs: [URL] = []
    /// 设备格式变化会额外切麦克风分片，两轨片边界此后不再逐片对齐。
    private var micFormatChanged = false
    /// 防止两次轮转重叠执行
    private var isRotating = false
    /// 分片会话标识：每次开始录音或重置分片状态时递增。
    /// `rotateSegments` 跨 `await`（系统音轨轮转内含 finishWriting 等待），
    /// 若期间会话已变更（停止录音、停止后很快重开），旧会话的收尾不得写进
    /// 新会话的分片列表与轮转基准
    private var segmentSessionID = 0
    /// mixed 模式：合并后的最终文件 URL（停止录音时生成）
    private var pendingMergeFinalURL: URL?

    /// 按资源存在判定，覆盖启动失败或标志提前复位的异常态。
    var hasResourcesPreventingUpdate: Bool {
        isStarting || isRecording || isMerging || isStoppingCapture || isRotating
            || segmentFolderDir != nil || micCapture.isCapturing || systemCapture.hasResourcesPreventingUpdate
    }

    /// 当前活动录音的文件夹名集合（周期巡检/手动刷新时排除：
    /// 静音/睡眠间隙可能使活动分片 mtime 变旧，避免把正在写入的分片误判为崩溃遗留）
    var activeRecordingFolderNames: Set<String> {
        guard isRecording, let dir = segmentFolderDir else { return [] }
        return [dir.lastPathComponent]
    }

    #if os(macOS)
    /// 睡眠抑制 token：录音期间阻止系统因空闲进入睡眠，避免长录音被休眠中断
    private var sleepInhibitor: NSObjectProtocol?

    /// 睡眠/唤醒通知观察者（合盖场景：醒来后主动恢复两条采集链路）
    private var sleepObservers: [NSObjectProtocol] = []
    /// 睡眠开始时间（唤醒后计算睡眠时长提示用户）
    private var sleepStartDate: Date?
    /// 本次睡眠后需恢复的声轨；系统轨按资源判断，兼容断流先于睡眠通知。
    private var micActiveBeforeSleep = false
    private var sysActiveBeforeSleep = false
    #endif

    init() {
        micCapture.nextSegmentForFormatChange = { [weak self] in
            guard let self, let folderDir = self.segmentFolderDir,
                  let baseName = self.segmentBaseName else { return nil }
            self.segmentIndex += 1
            return Self.micSegmentURL(folderDir: folderDir, baseName: baseName, index: self.segmentIndex)
        }
        micCapture.onFormatChangeSegmentOpened = { [weak self] url in
            guard let self else { return }
            self.micSegmentURLs.append(url)
            self.micFormatChanged = true
        }
    }

    /// 每次录音绑定会话快照；回调跨线程排队后必须复查会话和流代次。
    private func attachCaptureCallbacks(session: UUID) {
        #if os(macOS)
        systemCapture.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.activeCaptureSession == session,
                      self.isRecording, !self.isStoppingCapture,
                      self.systemCapture.isCurrentEvent(event) else { return }
                switch event.kind {
                case .interrupted(let error):
                    self.captureHealth.handle(.interrupted(), sessionID: session)
                    // 睡眠期间仅记录事实，唤醒后根据实际恢复结果更新横幅。
                    guard self.sleepStartDate == nil else { return }
                    let nsError = error as NSError
                    let message: String
                    if nsError.domain == SCStreamErrorDomain,
                       nsError.code == SCStreamError.Code.userStopped.rawValue {
                        message = String(localized: "系统音频共享已被停止，后续系统声音将无法录入。")
                    } else {
                        message = String(localized: "系统音频采集已中断，中断期间的系统声音无法录入。")
                    }
                    if nsError.domain == SCStreamErrorDomain,
                       nsError.code == SCStreamError.Code.systemStoppedStream.rawValue {
                        self.onRecordingStatus?(self.lastError ?? message)
                    } else {
                        self.onRecordingWarning?(message)
                    }
                case .writerFailed:
                    self.captureHealth.handle(.interrupted(writerFailure: true), sessionID: session)
                    self.onRecordingWarning?(String(localized: "系统音频写入失败，当前分片可能不完整。请停止录音并检查磁盘。"))
                case .samplesDropped(let dropped):
                    self.captureHealth.handle(.samplesDropped, sessionID: session)
                    self.onRecordingWarning?(String(
                        format: String(localized: "系统音频写入跟不上采集速度，已丢弃 %lld 个音频样本，系统音轨可能有缺口。"), dropped
                    ))
                case .recovered:
                    self.captureHealth.handle(.recovered, sessionID: session)
                    self.onRecordingStatus?(self.lastError ?? self.captureHealth.summary)
                }
            }
        }
        #endif
        micCapture.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.activeCaptureSession == session,
                      !self.isStoppingCapture,
                      // 事件绑定采集会话代次：停止后迅速重录时，旧通知/旧重试的事件不得改写新会话
                      self.micCapture.isCurrentGeneration(event.generation) else { return }
                self.handleMicCaptureEvent(event, session: session)
            }
        }
    }

    /// 麦克风采集事件分流：
    /// - 设备切换/恢复（deviceUnavailable / recoveryStarted / recovered）只更新状态横幅，
    ///   不写 `lastError`——旧实现把设备丢失也走写入错误出口，用户看到的是
    ///   「写入失败……建议停止后重新录制」，而实际只是设备正在切换。
    /// - 恢复失败与真实写盘失败才作为错误提示，并留下缺口记录。
    private func handleMicCaptureEvent(_ event: MicCaptureEvent, session: UUID) {
        switch event {
        case .deviceUnavailable(let diagnostics):
            logMicDiagnostics(diagnostics)
            captureHealth.handle(.microphoneUnavailable, sessionID: session,
                                 lastSuccessfulWriteAt: diagnostics.lastSuccessfulWriteAt)
            onRecordingStatus?(lastError ?? Self.microphoneRecoveringBanner)
        case .recoveryStarted(_, _, _):
            captureHealth.handle(.microphoneRecovering, sessionID: session)
            onRecordingStatus?(lastError ?? Self.microphoneRecoveringBanner)
        case .recovered:
            captureHealth.handle(.microphoneRecovered, sessionID: session)
            logger.info("麦克风采集已恢复（新代次首包写入确认）")
            // 恢复成功即结算此前挂起的「恢复失败」告警，避免同一次故障在停录时再报一次
            settleMicrophoneRecoveryError()
            onRecordingStatus?(lastError ?? captureHealth.summary)
        case .recoveryFailed(let diagnostics):
            logMicDiagnostics(diagnostics)
            captureHealth.handle(.microphoneRecoveryFailed, sessionID: session,
                                 lastSuccessfulWriteAt: diagnostics.lastSuccessfulWriteAt)
            let systemState = captureHealth.systemAudio == .active && !systemCapture.capturing
                ? RecordingCaptureHealth.SystemAudioState.interrupted : captureHealth.systemAudio
            let message = Self.microphoneRecoveryFailureMessage(systemAudio: systemState)
            micRecoveryError = message
            onRecordingWarning?(message)
        case .writeFailed(let userSummary, let diagnostics):
            logMicDiagnostics(diagnostics)
            lastError = String(format: String(localized: "麦克风录音写入失败：%@\n录音数据可能不完整，建议停止后重新录制。"), userSummary)
        }
    }

    /// 恢复成功即结算历史告警：清除由设备恢复失败挂起的错误，
    /// 但 captureHealth 里记录的缺口事实不会被抹掉。
    private func settleMicrophoneRecoveryError() {
        micRecoveryError = nil
    }

    /// 分别说明麦克风与系统音频状态，不把单轨恢复失败说成整个录音失效。
    static func microphoneRecoveryFailureMessage(systemAudio: RecordingCaptureHealth.SystemAudioState) -> String {
        let microphone = String(localized: "麦克风采集未恢复，后续麦克风声音可能缺失。请检查设备；若仍未恢复，请停止录音后重新开始。")
        let system: String?
        switch systemAudio {
        case .unused: system = nil
        case .active: system = String(localized: "系统音频采集仍在运行。")
        case .interrupted: system = String(localized: "系统音频当前未正常采集。")
        case .recovering: system = String(localized: "系统音频尚未确认恢复。")
        }
        return [microphone, system].compactMap { $0 }.joined(separator: "\n")
    }

    /// 麦克风采集失败定位日志（阶段/代次/绑定结果/新旧格式/错误域与码，不含会议内容）
    private func logMicDiagnostics(_ diagnostics: MicCaptureDiagnostics) {
        logger.error("麦克风采集事件 stage=\(diagnostics.stage.rawValue, privacy: .public) 会话代次=\(diagnostics.generation) 尝试=\(diagnostics.attempt) 设备绑定=\(diagnostics.deviceBound.map { String($0) } ?? "-", privacy: .public) 采样率=\(diagnostics.oldSampleRate.map { String($0) } ?? "-", privacy: .public)→\(diagnostics.newSampleRate.map { String($0) } ?? "-", privacy: .public) 声道=\(diagnostics.oldChannelCount.map { String($0) } ?? "-", privacy: .public)→\(diagnostics.newChannelCount.map { String($0) } ?? "-", privacy: .public) 错误域=\(diagnostics.errorDomain ?? "-", privacy: .public) 错误码=\(diagnostics.errorCode.map { String($0) } ?? "-", privacy: .public)")
    }

    // MARK: - 录音控制

    /// 开始录音
    /// - Parameter config: 录音配置
    /// - Returns: 录音文件 URL（mixed 模式下为合并后的最终文件，录音停止后才生成）
    func startRecording(config: RecordingConfig) async throws -> URL {
        await UpdatePermissionRepair.shared.prepareIfNeeded()
        try Task.checkCancellation()
        guard !AppUpdateService.shared.isPreparingToInstall else {
            throw NSError(domain: "app.memozia.Updates", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "请稍后重试更新。")])
        }
        guard !isRecording, !isStarting else { throw MeetingRecorderError.alreadyRecording }
        // 进入即占用“启动中”：并发第二次调用直接失败，避免其失败分支的清理
        //（stopAllCaptures/resetSegmentState）误伤第一个会话已建立的分片与采集
        isStarting = true
        defer { isStarting = false }

        self.config = config
        lastError = nil
        micRecoveryError = nil
        mergeHadDegradation = false
        captureHadWarningBeforeMerge = false
        skippedSegmentNames = []
        repairedSegmentNames = []
        retainedOriginals = false
        timelineSaveFailed = false
        microphoneLastWrite = nil
        microphoneFrames = nil
        let captureSession = UUID()
        segmentTimeline = RecordingSegmentTimelineStore { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeCaptureSession == captureSession else { return }
                self.saveCaptureTimeline()
            }
        }
        activeCaptureSession = captureSession
        captureHealth = RecordingCaptureHealth(
            usesSystemAudio: config.source != .microphone,
            usesMicrophone: config.source != .systemAudio,
            sessionID: captureSession
        )
        attachCaptureCallbacks(session: captureSession)
        diskProbeFailures = 0
        diskProbeFailureReported = false

        // D-1: 磁盘空间预检。分片采用 PCM（崩溃安全容器）：双轨约 1GB/小时，
        // 单轨麦克风约 345MB/小时（见下方分片说明）。旧注释写“至少 100MB”与实现不符，
        // 且 500MB 实际只够写半小时：保留作为硬门槛，录音中另有阶梯式检查与临界止损
        let freeSpace = try? FileManager.default.attributesOfFileSystem(
            forPath: AudioRecording.storageDirectory.path
        )[.systemFreeSize] as? NSNumber
        if let freeBytes = freeSpace?.int64Value {
            if freeBytes < 500 * 1024 * 1024 {
                throw MeetingRecorderError.insufficientDiskSpace(freeBytes)
            }
        } else {
            // 读不到容量时不阻止开始录音（录音中另有阶梯检查与临界止损），但必须留痕：
            // 旧实现把"读失败"和"空间充足"合并成同一条静默路径，事后无从排查
            logger.error("录音前磁盘预检无法读取剩余容量，本次跳过预检；录音中的阶梯检查仍然生效")
        }

        // 生成录音文件路径：统一存到 ~/Documents/Memozia/yyyyMMddHHmmss/ 子文件夹
        // 原子创建独占文件夹名：并发录音/导入落在同一秒也不会共用目录互相覆盖
        let now = Date()
        let baseName = AudioRecording.fileName(from: now)
        guard let folderName = AudioRecording.createUniqueFolder(from: now) else {
            throw MeetingRecorderError.folderCreationFailed
        }
        let folderDir = AudioRecording.resolveFolderURL(forFolderName: folderName)

        // 分片滚动录音：各模式统一最终文件名 yyyyMMddHHmmss.m4a；
        // 录音过程中写入 _mic_tmp_%04d / _sys_tmp_%04d 分片，停止后拼接合并为最终文件
        let finalURL = folderDir.appendingPathComponent("\(baseName).m4a")
        segmentFolderDir = folderDir
        segmentBaseName = baseName
        segmentIndex = 1
        segmentSessionID += 1
        micSegmentURLs = [Self.micSegmentURL(folderDir: folderDir, baseName: baseName, index: 1)]
        sysSegmentURLs = []
        micFormatChanged = false
        pendingMergeFinalURL = finalURL

        do {
            try segmentTimeline?.save(in: folderDir)
            // 静音状态复位：上一次会话可能停在静音（停止路径同样会复位），本次按配置重新决定。
            // 采集层在首包前应用初始静音；这里同步界面状态。
            isMicMuted = false
            muteSource = .none

            // 根据配置启动对应的采集服务（均写入第 1 片分片）
            let firstMicURL = micSegmentURLs[0]
            switch config.source {
            case .microphone:
                try await startMicCapture(url: firstMicURL)
            case .systemAudio:
                micSegmentURLs = []
                #if os(macOS)
                sysSegmentURLs = [Self.sysSegmentURL(folderDir: folderDir, baseName: baseName, index: 1)]
                try await startSystemCapture(url: sysSegmentURLs[0])
                #else
                /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
                // iOS 不支持系统音频采集，降级为麦克风
                try startMicCapture(url: firstMicURL)
                */
                #endif
            case .mixed:
                // mixed 模式：先检查系统音频权限，未授权则阻止录音启动
                // 避免出现"麦克风已开始录但系统音频权限未决"的竞态
                #if os(macOS)
                let authorizedContent: SCShareableContent
                do { authorizedContent = try await ScreenCaptureAuthorization.content() }
                catch ScreenCaptureAuthorization.Failure.denied { throw SystemAudioError.permissionNotGranted }
                try Task.checkCancellation()
                #endif
                // 权限已确认，启动麦克风 + 系统音频（分别写入分片，停止时拼接合并）
                try await startMicCapture(url: firstMicURL)
                #if os(macOS)
                sysSegmentURLs = [Self.sysSegmentURL(folderDir: folderDir, baseName: baseName, index: 1)]
                try await systemCapture.start(to: sysSegmentURLs[0], timeline: segmentTimeline,
                                              authorizedContent: authorizedContent)
                #endif
            }

            // 首包已经按初始静音偏好写入；这里只更新界面，恢复重建保持该状态。
            // 仅系统音频来源没有麦克风轨，不需要也不应改写静音状态
            if config.startMuted, config.source != .systemAudio {
                isMicMuted = true
                muteSource = .local
                logger.info("按偏好「录音开始时静音麦克风」以静音状态开始采集")
            }

            // 启动系统静音监听（仅 macOS）
            #if os(macOS)
            if config.autoMuteDetection {
                setupMuteMonitor()
            }
            // 暂时停用 App 静音检测（AX 轮询 Teams/Zoom/腾讯会议静音按钮文案，
            // 依赖辅助功能权限且为 1 秒轮询 + 35 层 AX 树递归搜索，开销大、
            // 按钮文案本地化时易失效）。UI 静音改用本地手动按钮（见 RootView 录音徽章）
            // if config.appMuteDetection {
            //     setupAppMuteDetector()
            // }
            #endif

            // 录音期间抑制系统空闲睡眠，避免长录音被休眠中断
            beginSleepInhibition()

            // 监听系统睡眠/唤醒（合盖场景）：醒来后主动恢复采集（仅 macOS）
            #if os(macOS)
            setupSleepObservers()
            #endif

            // 启动计时
            startTimer()
            isRecording = true
            // 默认按纯音频开始；录屏链路在视频轨真正启动后置为 true
            isScreenRecording = false
            startDate = Date()
            lastRotationDate = Date()
            logger.info("开始录音: \(config.source.rawValue), 首片: \(firstMicURL.lastPathComponent)（每 \(Int(self.segmentDuration))s 轮转分片）")
        } catch {
            // 启动失败时清理已启动的子服务
            await stopAllCaptures()
            // 首包等待/后续声轨启动可能失败，但前面已写入的数据必须保留供恢复扫描。
            let preserveSegments = Self.hasCapturedFrames(in: micSegmentURLs + sysSegmentURLs)
            resetSegmentState()
            pendingMergeFinalURL = nil
            activeCaptureSession = nil
            if !preserveSegments {
                do { try FileManager.default.removeItem(at: folderDir) }
                catch { logger.error("清理未启动的录音目录失败: \(error.localizedDescription)") }
            }
            lastError = UserFacingError.summary(for: error)
            throw error
        }

        // 返回最终文件 URL（mixed 模式下停止录音后才生成此文件）
        return finalURL
    }

    /// 停止录音（停止采集 + 合并封装一步到位）
    /// - Returns: 录音文件 URL（失败返回 nil）
    func stopRecording() async -> URL? {
        guard let captured = await stopCapturing() else { return nil }
        return await mergeCapturedSegments(captured)
    }

    /// 仅停止采集并冻结本次的记录信息，**不做合并**。
    ///
    /// 拆出这一步的目的：用户点击停止（或磁盘临界止损触发停止）后，音频与视频两路
    /// 采集都要立刻停下。合并/混流是耗时操作，若把它塞在停止采集之前，视频会继续
    /// 录制、编码、写盘，且磁盘不足时更不利。调用方拿到 `CapturedSegments` 后
    /// 用 `mergeCapturedSegments(_:)` 异步完成音频合并。
    /// - Returns: 本次采集的分片与最终文件路径；未在录音或无有效目标时返回 nil
    func stopCapturing() async -> CapturedSegments? {
        guard isRecording, !isStoppingCapture else { return nil }
        isStoppingCapture = true
        #if os(macOS)
        if let session = activeCaptureSession, config.source != .microphone, !systemCapture.capturing {
            captureHealth.handle(.interrupted(), sessionID: session)
        }
        #endif
        activeCaptureSession = nil // 在第一个 await 前阻止迟到事件和唤醒任务写回。
        defer { isStoppingCapture = false }

        timer?.invalidate()
        timer = nil
        lowDiskSpaceWarned = false
        diskStopRequested = false
        endSleepInhibition()
        #if os(macOS)
        removeSleepObservers()
        #endif

        #if os(macOS)
        muteMonitor.stop()
        appMuteDetector.stop()
        #endif

        microphoneLastWrite = micCapture.lastSuccessfulWriteAt
        microphoneFrames = config.source == .systemAudio ? nil : micCapture.writtenFrames
        if let session = captureHealth.sessionID, config.source != .systemAudio, !micCapture.hasRecentWrites {
            captureHealth.handle(.microphoneUnavailable, sessionID: session, lastSuccessfulWriteAt: microphoneLastWrite)
        }
        await stopAllCaptures()
        segmentTimeline?.finish()
        saveCaptureTimeline()
        captureHealth.finish()

        isRecording = false
        isScreenRecording = false
        elapsedSeconds = 0
        muteSource = .none
        isMicMuted = false

        // 取出分片列表与最终文件路径，重置状态
        let micURLs = micSegmentURLs
        let sysURLs = sysSegmentURLs
        let formatChanged = micFormatChanged
        let finalURL = pendingMergeFinalURL
        resetSegmentState()
        pendingMergeFinalURL = nil
        startDate = nil

        guard let finalURL else { return nil }
        return CapturedSegments(micURLs: micURLs, sysURLs: sysURLs, finalURL: finalURL,
                                micFormatChanged: formatChanged)
    }

    /// 合并 `stopCapturing()` 冻结的分片为最终文件（耗时操作，可在停止采集后异步执行）
    /// - Returns: 录音文件 URL（失败返回 nil）
    func mergeCapturedSegments(_ captured: CapturedSegments) async -> URL? {
        let resultURL = await mergeSegments(
            micURLs: captured.micURLs, sysURLs: captured.sysURLs, outputURL: captured.finalURL,
            skipEchoReduction: captured.micFormatChanged
        )
        logger.info("停止录音: \(resultURL?.lastPathComponent ?? "nil")")
        return resultURL
    }

    /// 应用退出时的紧急收尾：停止采集并 finalize 当前分片，已轮转的分片本就可播放，
    /// 下次启动时 FileSyncService 会把全部分片拼接/合并为最终文件。
    /// 麦克风用 AVAudioFile（置 nil 即 flush）可同步 finalize；系统音频需等待
    /// AVAssetWriter.finishWriting。看门狗到点后放弃等待，但后台 worker 只能在主进程释放
    /// DatabaseOwnershipLock 后恢复分片，不会与还在收尾的 writer 并发操作。
    func finalizeForTermination() async {
        #if os(macOS)
        // 录屏视频轨先收尾：`ScreenVideoRecorder` 由 `RecordingViewModel` 私有持有，不在本服务内，
        // 只能经其静态登记表按「资源是否存在」找到并停采/封装；且"音频已停但视频仍在采集"
        // 的异常态也应收尾，故置于 isRecording 判定之前。
        await ScreenVideoRecorder.finalizeActiveRecordersForTermination(timeout: 10)
        #endif
        guard isRecording else { return }
        activeCaptureSession = nil
        logger.warning("应用退出，紧急收尾录音；已录分片将在下次启动时恢复拼接")
        timer?.invalidate()
        timer = nil
        lowDiskSpaceWarned = false
        diskStopRequested = false
        endSleepInhibition()
        #if os(macOS)
        removeSleepObservers()
        muteMonitor.stop()
        appMuteDetector.stop()
        #endif
        // 麦克风：置 nil 触发 AVAudioFile 关闭并 flush，finalize 当前分片
        micCapture.stop()
        #if os(macOS)
        let stopped = await RacingWatchdog.race(
            name: "退出时系统音频收尾", timeout: 10
        ) { [systemCapture] in
            _ = await systemCapture.stop()
        }
        if !stopped {
            logger.warning("系统音频收尾超时，分片将在进程退出后由 worker 恢复")
        }
        #endif
        segmentTimeline?.finish()
        saveCaptureTimeline()
        isRecording = false
        isScreenRecording = false
        elapsedSeconds = 0
        muteSource = .none
        isMicMuted = false
        resetSegmentState()
        pendingMergeFinalURL = nil
        startDate = nil
    }

    /// 重置分片状态（不清理磁盘文件：分片保留供恢复/手动处理）
    private func resetSegmentState() {
        segmentTimeline = nil
        segmentFolderDir = nil
        segmentBaseName = nil
        segmentIndex = 0
        lastRotationDate = nil
        micSegmentURLs = []
        sysSegmentURLs = []
        micFormatChanged = false
        isRotating = false
        // 磁盘探测失败计数随会话结束复位（下次录音重新累计，避免跨会话误报）
        diskProbeFailures = 0
        diskProbeFailureReported = false
        // 递增会话标识：使任何在途的 rotateSegments 在 await 之后判定为过期
        segmentSessionID += 1
    }

    /// 麦克风分片 URL：{baseName}_mic_tmp_%04d.caf（PCM 容器，崩溃安全）
    private static func micSegmentURL(folderDir: URL, baseName: String, index: Int) -> URL {
        folderDir.appendingPathComponent(String(format: "%@_mic_tmp_%04d.caf", baseName, index))
    }

    /// 系统音频分片 URL：{baseName}_sys_tmp_%04d.wav（PCM 容器，崩溃安全）
    private static func sysSegmentURL(folderDir: URL, baseName: String, index: Int) -> URL {
        folderDir.appendingPathComponent(String(format: "%@_sys_tmp_%04d.wav", baseName, index))
    }

    /// 分片轮转：关闭当前分片（finalize 后立即可播放），打开下一片继续写入。
    /// 由录音计时器每 segmentDuration 秒触发一次；两条声轨各自独立轮转，
    /// 单轨失败时保留旧分片继续写入（不丢数据，下轮重试）。
    private func rotateSegments() async {
        // 记录本次轮转所属的会话：系统音轨轮转跨 await，期间会话可能被重置/重开
        let session = segmentSessionID
        guard isRecording, !isRotating,
              let folderDir = segmentFolderDir, let baseName = segmentBaseName else { return }
        guard let last = lastRotationDate, Date().timeIntervalSince(last) >= segmentDuration else { return }

        let micActive = micCapture.isCapturing
        #if os(macOS)
        let sysActive = systemCapture.capturing
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let sysActive = false
        */
        #endif
        guard micActive || sysActive else { return }

        isRotating = true
        // 会话已变更时不复位标志：由新会话自己的轮转负责复位，
        // 否则旧调用的 defer 会踩掉新会话刚置上的 isRotating（导致并发轮转）
        defer { if segmentSessionID == session { isRotating = false } }

        segmentIndex += 1 // await 前保留编号，设备恢复可能在等待系统 writer 收尾时再分配编号。
        let nextIndex = segmentIndex

        // 麦克风：同步原子替换（先建新文件再切换，无写入空窗）
        if micActive {
            let newMicURL = Self.micSegmentURL(folderDir: folderDir, baseName: baseName, index: nextIndex)
            if micCapture.rotateSegment(to: newMicURL) {
                micSegmentURLs.append(newMicURL)
            } else {
                logger.error("麦克风分片轮转失败，继续写入当前分片")
            }
        }

        // 系统音频：异步轮转 writer（失败时旧 writer 继续写入，不丢数据）
        #if os(macOS)
        if sysActive {
            let newSysURL = Self.sysSegmentURL(folderDir: folderDir, baseName: baseName, index: nextIndex)
            if await systemCapture.rotateWriter(to: newSysURL) {
                sysSegmentURLs.append(newSysURL)
            }
        }
        #endif

        // await 期间会话可能已被重置（停止录音 / 停止后很快重开）：此时
        // micSegmentURLs / segmentIndex / lastRotationDate 已属于新会话，
        // 旧会话的收尾不得再写入，否则会把上一文件夹的分片混进本次拼接列表
        guard segmentSessionID == session else {
            logger.warning("分片轮转在途期间会话已变更，丢弃本次轮转结果")
            return
        }

        lastRotationDate = Date()
        logger.info("分片轮转 → 第 \(nextIndex) 片")
    }

    // MARK: - 音频拼接与合并（分片）

    /// 把各轨分片拼接/合并为最终文件：
    /// - 两轨均有可播放分片：各自顺序拼接后叠加混音导出
    /// - 仅一轨有可播放分片：该轨分片顺序拼接（旧版 m4a 单分片直接改名）
    /// - 全部不可播放（仅旧版 AAC 分片缺 moov atom）：保留分片并提示用户
    /// 完整且无采集故障时清理分片；降级/跳片时全部保留；
    /// 失败时保留分片供手动处理
    /// - Returns: 最终文件 URL；失败返回 nil
    private func mergeSegments(
        micURLs: [URL], sysURLs: [URL], outputURL: URL, skipEchoReduction: Bool
    ) async -> URL? {
        isMerging = true
        mergeHadDegradation = false
        repairedSegmentNames = []
        captureHadWarningBeforeMerge = lastError != nil
        mergePhase = .inspectingSegments
        mergeProgressCompleted = 0
        mergeProgressTotal = 0
        mergeStageStartedAt = Date()
        defer {
            isMerging = false
            mergeProjectedFinishAt = nil
            mergePhase = .idle
            mergeProgressCompleted = 0
            mergeProgressTotal = 0
            mergeStageStartedAt = nil
            echoReductionCancelFlag = nil
        }

        // 合并互斥：合并期间在录音文件夹写入 PID 化标记（内容含写标记进程 PID 与开始时间），
        // 阻止磁盘扫描/守护进程把“合并进行中”的中间态误判为崩溃遗留而介入
        //（曾发生扫描删掉正在导出的半成品、争抢分片导致全部失败）；defer 保证任何路径都移除
        let folderURL = outputURL.deletingLastPathComponent()
        FileSyncService.writeMergeMarker(at: folderURL)
        defer { FileSyncService.removeMergeMarker(at: folderURL) }

        var timeline: RecordingSegmentTimeline?
        do { timeline = try RecordingSegmentTimeline.load(in: folderURL) }
        catch {
            retainedOriginals = true
            lastError = String(localized: "录音时间轴保存失败，原始分片已保留。")
            logger.error("无法读取录音时间轴，停止合并并保留原片: \(error.localizedDescription)")
            return nil
        }

        var usable: [URL: URL] = [:]
        var repairedCopies: [URL] = []
        var repairedNames: [String] = []
        defer { removeSegments(repairedCopies) }
        for url in micURLs + sysURLs {
            if await isPlayable(at: url) {
                usable[url] = url
            } else if let repaired = await FileSyncService.repairedPCMContainerCopy(at: url) {
                usable[url] = repaired
                repairedCopies.append(repaired)
                repairedNames.append(url.lastPathComponent)
                // 修复只恢复容器，不改变样本所在的原始时间，不能顺序拼接压缩缺口。
                let start = timeline?.starts[url.lastPathComponent]
                timeline?.starts[repaired.lastPathComponent] = start
            }
        }
        var micOK = micURLs.compactMap { usable[$0] }
        let sysOK = sysURLs.compactMap { usable[$0] }

        skippedSegmentNames = (micURLs + sysURLs).filter { usable[$0] == nil }.map(\.lastPathComponent)
        let skipped = skippedSegmentNames.count
        retainedOriginals = skipped > 0 || !repairedNames.isEmpty || timelineSaveFailed || captureHadWarningBeforeMerge
            || micRecoveryError != nil || captureHealth.report.hasWarning
        if skipped > 0 {
            mergeHadDegradation = true
            logger.warning("跳过 \(skipped) 个不可播放分片（静音期空段或异常退出遗留的未 finalize 分片）")
        }

        let estimatedDuration = TimeInterval(max(micOK.count, sysOK.count)) * segmentDuration
        // 导出超时上限（秒）：挂起检测用，远大于正常耗时（2.2h 素材实测恢复导出 ~35s）；
        // 基础 10 分钟 + 每小时素材 7.5 分钟，上限 1 小时
        let exportTimeout = FileSyncService.mergeExportTimeout(estimatedAudioDuration: estimatedDuration)
        // 回声消除的独立时间预算：旧实现没有独立预算，该阶段一旦卡住整个停录就无反馈
        let echoTimeout = FileSyncService.echoReductionTimeout(estimatedAudioDuration: estimatedDuration)

        // 预计完成时刻 = 回声消除上限 + 导出上限 + 探测/写盘余量，供退出流程同源等待。
        // 在回声消除**之前**起算：两个阶段的耗时都要计入，否则退出流程会按过期时刻提前放弃等待
        mergeProjectedFinishAt = Date().addingTimeInterval(echoTimeout + exportTimeout + 30)

        // 离线参考回声消除：以系统音轨为参考，清掉麦克风轨里泄漏进来的远端声音
        //（远端声音从本地扬声器外放后被麦克风采回，同一句话在两条轨各有一份，
        // 混音后会造成转写重复与说话人误判）。只对已确认可播放的成对分片处理，
        // 任一环节失败/超时/取消都回退为原始分片，不丢音频、不阻断合并入库。
        var createdCleanURLs: [URL] = []
        if !skipEchoReduction, !micOK.isEmpty, !sysOK.isEmpty, EchoReductionPreference.isEnabled(),
           await RecordingSegmentTimeline.canReduceEcho(mic: micOK, system: sysOK, timeline: timeline) {
            if let reduced = await runEchoReduction(
                micOK: micOK, sysOK: sysOK, outputURL: outputURL, timeout: echoTimeout
            ) {
                for (original, cleaned) in zip(micOK, reduced.micURLs) {
                    let start = timeline?.starts[original.lastPathComponent]
                    timeline?.starts[cleaned.lastPathComponent] = start
                }
                micOK = reduced.micURLs
                createdCleanURLs = reduced.createdURLs
            }
        }

        mergePhase = .mixing
        mergeStageStartedAt = Date()

        guard !micOK.isEmpty || !sysOK.isEmpty else {
            logger.error("全部分片均不可播放: mic=\(micURLs.count) sys=\(sysURLs.count)")
            lastError = String(localized: "录音分片均已损坏，无法生成最终文件。分片文件已保留在录音文件夹，可用 ffmpeg 等专业工具尝试修复。")
            return nil
        }

        // 合并成功后需清理的全部分片：原始分片 + 回声消除新建的清理分片
        let cleanupURLs = micURLs + sysURLs + createdCleanURLs

        // 两轨均可用：拼接后叠加混音
        if !micOK.isEmpty && !sysOK.isEmpty {
            if await exportMixedComposition(micSegments: micOK, sysSegments: sysOK, outputURL: outputURL, timeout: exportTimeout, timeline: timeline) {
                repairedSegmentNames = repairedNames
                // 只有完整且无采集故障的合并才删除原片；未知/未消费素材保留。
                let shellCount = micURLs.count + sysURLs.count - micOK.count - sysOK.count
                if !retainedOriginals { removeSegments(cleanupURLs) }
                if shellCount > 0 {
                    logger.warning("已保留 \(shellCount) 个未合入分片供修复")
                }
                mergePhase = .saving
                logger.info("音频合并完成: \(outputURL.lastPathComponent)")
                return outputURL
            }
            // 混音导出失败：回退为仅拼接麦克风轨
            mergeHadDegradation = true
            retainedOriginals = true
            logger.error("双轨混音失败，回退为仅麦克风音轨")
            lastError = String(localized: "两条音轨合并失败，已保留麦克风音轨，系统音频可能丢失。")
        } else if micOK.isEmpty, config.source != .systemAudio {
            mergeHadDegradation = true
            lastError = String(localized: "麦克风声轨无可播放分片，已使用系统音频音轨。")
        } else if sysOK.isEmpty, config.source == .mixed {
            mergeHadDegradation = true
        }

        retainedOriginals = retainedOriginals || mergeHadDegradation

        // 单轨路径：按时间轴保留缺口（麦克风优先）
        let single = !micOK.isEmpty ? micOK : sysOK
        if let result = await concatOrMove(segments: single, to: outputURL, timeout: exportTimeout, timeline: timeline) {
            // 双轨导出失败后的单轨回退，只能确认被实际选中声轨的分片已修复合入。
            let consumedOriginals = !micOK.isEmpty ? micURLs : sysURLs
            repairedSegmentNames = consumedOriginals.filter {
                guard let prepared = usable[$0] else { return false }
                return prepared != $0
            }.map(\.lastPathComponent)
            // 单轨回退与跳片时保留全部原片，不能删除未合入的另一轨。
            if !retainedOriginals { removeSegments(cleanupURLs) }
            mergePhase = .saving
            logger.info("分片拼接完成: \(outputURL.lastPathComponent)（\(single.count) 片）")
            return result
        }

        // 拼接也失败：保留分片供手动处理
        lastError = (lastError ?? "") + String(format: String(localized: "\n⚠️ 录音分片拼接失败，分片文件已保留在录音文件夹（共 %d 个），请手动处理。"), single.count)
        return nil
    }

    /// 运行回声消除阶段：独立看门狗 + 取消 + 进度。
    ///
    /// 看门狗超时或用户取消时，回退为原始音轨继续合并（不丢音频、不阻断入库）。
    /// 超时属于「操作挂起被放弃」：被等操作成为孤儿任务，可能仍在写清理分片，
    /// 故超时后清理文件夹里残留的 `_mic_clean` 文件，避免留下磁盘垃圾。
    /// - Returns: 处理结果；超时/无可处理结果时返回 nil。
    private func runEchoReduction(
        micOK: [URL],
        sysOK: [URL],
        outputURL: URL,
        timeout: TimeInterval
    ) async -> EchoReductionService.Result? {
        mergePhase = .echoReduction
        mergeProgressCompleted = 0
        mergeProgressTotal = min(micOK.count, sysOK.count)
        mergeStageStartedAt = Date()

        let cancelFlag = CancellationFlag()
        echoReductionCancelFlag = cancelFlag
        let deadline = Date().addingTimeInterval(timeout)
        let resultBox = LockedBox<EchoReductionService.Result?>(nil)

        let finished = await RacingWatchdog.race(
            name: "停录回声消除",
            timeout: timeout,
            onTimeout: { cancelFlag.cancel() }
        ) { [self] in
            let reduced = await EchoReductionService.reduceEcho(
                micURLs: micOK,
                sysURLs: sysOK,
                deadline: deadline,
                isCancelled: { cancelFlag.isCancelled },
                onProgress: { completed, total in
                    Task { @MainActor in
                        self.mergeProgressCompleted = completed
                        self.mergeProgressTotal = total
                    }
                }
            )
            resultBox.value = reduced
        }

        echoReductionCancelFlag = nil

        guard finished else {
            // 超时：放弃等待挂起的孤儿任务，回退原始音轨，并清理其可能残留的清理分片
            logger.error("停录回声消除超时（>\(Int(timeout))s），跳过并回退原始音轨")
            removeLeftoverCleanedSegments(in: outputURL.deletingLastPathComponent())
            return nil
        }
        return resultBox.value
    }

    /// 清理因超时/异常中断残留的 `_mic_clean` 分片（这些文件不在任何待合并列表中）。
    /// 仅在回声消除阶段未能正常返回时调用；best-effort，不影响主流程。
    private func removeLeftoverCleanedSegments(in folderURL: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.lastPathComponent.contains("_mic_clean") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 顺序拼接分片导出为最终 m4a；旧版 m4a 单分片直接移动（零开销），
    /// PCM 分片（caf/wav）必须经导出转为 AAC 容器
    /// - Returns: 输出文件 URL；失败返回 nil
    private func concatOrMove(segments: [URL], to outputURL: URL, timeout: TimeInterval, timeline: RecordingSegmentTimeline?) async -> URL? {
        guard !segments.isEmpty else { return nil }
        var temporaryFiles: [URL] = []
        defer { removeSegments(temporaryFiles) }
        do {
            let composition = AVMutableComposition()
            let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            let seconds = try await RecordingSegmentTimeline.append(segments, to: track, timeline: timeline, temporaryFiles: &temporaryFiles)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return nil
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            try await exportWithWatchdog(exporter, outputURL: outputURL, estimatedAudioDuration: seconds, timeout: timeout)
            // 校验可播放性：导出过程被中断会留下容器未 finalize 的损坏文件
            return await isPlayable(at: outputURL) ? outputURL : nil
        } catch {
            logger.error("分片拼接异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 两条轨各自顺序拼接后叠加混音导出为最终文件
    /// - Returns: 是否成功（含导出后可播放性校验）
    private func exportMixedComposition(micSegments: [URL], sysSegments: [URL], outputURL: URL, timeout: TimeInterval, timeline: RecordingSegmentTimeline?) async -> Bool {
        var temporaryFiles: [URL] = []
        defer { removeSegments(temporaryFiles) }
        do {
            let composition = AVMutableComposition()

            // 麦克风轨：分片顺序拼接
            let micTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            let micSeconds = try await RecordingSegmentTimeline.append(micSegments, to: micTrack, timeline: timeline, temporaryFiles: &temporaryFiles)

            // 系统音频轨：分片顺序拼接，与麦克风同时开始（叠加混音）
            let sysTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            let sysSeconds = try await RecordingSegmentTimeline.append(sysSegments, to: sysTrack, timeline: timeline, temporaryFiles: &temporaryFiles)

            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return false
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            let estimatedSeconds = max(micSeconds, sysSeconds)
            try await exportWithWatchdog(exporter, outputURL: outputURL, estimatedAudioDuration: estimatedSeconds, timeout: timeout)
            // 导出后校验：导出过程中进程退出/崩溃会留下体积完整但容器未 finalize 的损坏文件
            return await isPlayable(at: outputURL)
        } catch {
            logger.error("混音导出异常: \(error.localizedDescription)")
            return false
        }
    }

    /// 删除已处理的分片文件
    private func removeSegments(_ urls: [URL]) {
        for url in urls {
            do { try FileManager.default.removeItem(at: url) }
            catch { logger.error("清理音频分片失败: \(error.localizedDescription, privacy: .private)") }
        }
    }

    /// 导出挂起看门狗：AVAssetExportSession 偶发永久挂起（20260910 会议事故实证：
    /// 合并卡死、.merging 标记无法释放、半成品残留且无任何用户可见反馈）。
    /// 超时后抛错，由调用方走失败清理路径（defer 释放标记、保留分片供恢复）
    private func exportWithWatchdog(
        _ exporter: AVAssetExportSession,
        outputURL: URL,
        estimatedAudioDuration: TimeInterval,
        timeout: TimeInterval
    ) async throws {
        // AVAssetExportSession 非 Sendable：session 仅由导出任务独占操作，
        // 错误留在 LockedBox 内交接
        nonisolated(unsafe) let session = exporter
        let errorBox = LockedBox<SentError?>(nil)
        // 超时后尽力中止导出；即使不响应取消，RacingWatchdog 也能真正返回
        // （旧版结构化并发组必须 join 挂起的导出子任务，“假超时”会永久卡在停录/退出路径）
        let finished = await RacingWatchdog.race(
            name: "录音合并导出 \(outputURL.lastPathComponent)",
            timeout: timeout,
            onTimeout: {
                // 超时后必须尽力中止导出：否则该导出可能继续往 outputURL 写，
                // 而调用方（合并/抽轨/对账）此后可能已删除或重建同一路径。
                // cancelExport() 在 macOS 27 被标记弃用但仍可用，故无条件调用
                // （仅产生一条弃用警告；旧系统本就依赖它中止挂起的导出）
                session.cancelExport()
            }
        ) {
            do {
                try await session.export(to: outputURL, as: .m4a)
            } catch {
                errorBox.value = SentError(error)
            }
        }
        guard finished else {
            if Task.isCancelled { throw CancellationError() }
            throw MeetingRecorderError.exportTimeout
        }
        if let exportError = errorBox.value {
            throw exportError.value
        }
    }

    /// 校验音频文件可播放（时长 > 0 且有音轨）
    private func isPlayable(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    /// 移动文件到目标位置（覆盖已存在的目标文件）
    private func moveFile(at src: URL, to dst: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.moveItem(at: src, to: dst)
        return dst
    }

    /// 切换本地手动静音
    func toggleLocalMute() {
        if isMicMuted {
            // 如果当前静音来源是 app 或 system，不允许本地解除静音
            if muteSource == .app || muteSource == .system {
                logger.info("当前静音由 \(self.muteSource.rawValue) 触发，无法手动解除")
                return
            }
            // 恢复结果由 MicCaptureService 的采集事件上报（恢复失败会明确告警），
            // 这里不再抛出/捕获：否则「正在恢复」会被当成一次即时错误重复提示
            micCapture.unmute()
            isMicMuted = false
            if muteSource == .local { muteSource = .none }
            logger.info("解除本地静音")
        } else {
            micCapture.mute()
            isMicMuted = true
            muteSource = .local
            logger.info("已本地静音")
        }
    }

    // MARK: - 私有方法

    /// 启动麦克风采集（所有平台可用）
    /// 首次运行会在权限未决时弹系统授权框，故为 async
    private func startMicCapture(url: URL) async throws {
        try await micCapture.start(to: url, initiallyMuted: config.startMuted, timeline: segmentTimeline)
    }

    /// 读失败时保守保留，不能把不可读取的录音当作空壳删除。
    static func hasCapturedFrames(in urls: [URL]) -> Bool {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                if try AVAudioFile(forReading: url).length > 0 { return true }
            } catch {
                Logger(subsystem: "app.memozia", category: "MeetingRecorder")
                    .error("启动回滚无法检查分片，已保留录音目录: \(error.localizedDescription)")
                return true
            }
        }
        return false
    }

    #if os(macOS)
    /// 启动系统音频采集（仅 macOS）
    private func startSystemCapture(url: URL) async throws {
        try await systemCapture.start(to: url, timeline: segmentTimeline)
    }

    private func setupMuteMonitor() {
        muteMonitor.onMuteChange = { [weak self] muted in
            guard let self else { return }
            Task { @MainActor in
                self.handleSystemMuteChange(muted)
            }
        }
        muteMonitor.start()
    }

    /// 系统静音状态变化处理
    private func handleSystemMuteChange(_ muted: Bool) {
        // 系统静音时自动暂停麦克风采集；解除时恢复（除非用户也手动静音了）
        if muted {
            micCapture.mute()
            isMicMuted = true
            muteSource = .system
            logger.info("检测到系统静音，已暂停麦克风采集")
        } else {
            // 系统解除静音：仅当非本地手动静音且非 app 静音时才恢复
            if muteSource != .local && muteSource != .app {
                micCapture.unmute()
                isMicMuted = false
                muteSource = .none
                logger.info("系统静音解除，恢复麦克风采集")
            }
        }
    }

    /// 设置 App 静音检测器
    private func setupAppMuteDetector() {
        appMuteDetector.onMuteChange = { [weak self] (muted: Bool) in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppMuteChange(muted)
            }
        }
        // C-5: 检查 AppMuteDetector 启动结果，未授权时向用户反馈
        if !appMuteDetector.start() {
            lastError = String(localized: "应用静音检测启动失败：未授予辅助功能权限。请到「系统设置 → 隐私与安全性 → 辅助功能」中开启 Memozia 后重新录音以启用此功能。")
            logger.warning("AppMuteDetector 启动失败：辅助功能权限未授予")
        }
    }

    /// App 层静音状态变化处理（Teams/Zoom 等会议软件内静音）
    private func handleAppMuteChange(_ muted: Bool) {
        logger.info("[App静音] 收到回调 muted=\(muted) 当前muteSource=\(self.muteSource.rawValue) isMicMuted=\(self.isMicMuted)")
        if muted {
            // 会议软件内静音 → 自动暂停 Memozia 麦克风采集
            micCapture.mute()
            isMicMuted = true
            muteSource = .app
            logger.info("[App静音] ✅ 已暂停麦克风采集 (muteSource=.app)")
        } else {
            // 会议软件解除静音：仅当非本地手动静音且非系统静音时才恢复
            if muteSource != .local && muteSource != .system {
                micCapture.unmute()
                isMicMuted = false
                muteSource = .none
                logger.info("[App静音] ✅ 已恢复麦克风采集 (muteSource=.none)")
            } else {
                logger.info("[App静音] 跳过恢复，当前 muteSource=\(self.muteSource.rawValue)（本地/系统静音优先）")
            }
        }
    }
    #endif

    private func stopAllCaptures() async {
        micCapture.stop()
        #if os(macOS)
        let result = await systemCapture.stop()
        if let session = captureHealth.sessionID {
            if result.wasInterrupted || result.writerFailed {
                captureHealth.handle(.interrupted(writerFailure: result.writerFailed), sessionID: session)
            }
            if result.droppedSamples > 0 {
                captureHealth.handle(.samplesDropped, sessionID: session)
            }
        }
        #endif
    }

    private func startTimer() {
        // 录音开始即建立节拍基准：起始预检刚做过，没必要在第一个 tick 再 stat 一次
        diskPacer = TimePacer(interval: diskCheckInterval, lastFiredAt: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // 整个逻辑在 MainActor 上执行，避免 @Sendable 闭包访问 @MainActor 属性
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
                // 录音中定期检查磁盘空间（每 30 秒），写满前提醒/止损。
                // 按**时间差**放行：旧写法 `Int(elapsed) % 30 == 0` 要求定时器正好落在
                // 30 的整数倍上，而定时器漂移、系统睡眠唤醒后的补 tick、单次 tick 超过 1s
                // 都可能整体跳过该周期——磁盘临界止损恰恰依赖这个节拍
                if self.diskPacer.fireIfNeeded(at: Date()) {
                    self.checkDiskSpaceWhileRecording()
                }
                if self.sleepStartDate == nil, self.config.source != .systemAudio {
                    self.micCapture.checkCaptureHealth()
                }
                self.saveCaptureTimeline()
                // 分片滚动：到点轮转，确保任何时刻崩溃最多丢一片
                await self.rotateSegments()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func saveCaptureTimeline() {
        guard let folder = segmentFolderDir, let segmentTimeline else { return }
        do { try segmentTimeline.save(in: folder) }
        catch {
            logger.error("录音时间轴保存失败: \(error.localizedDescription)")
            if !timelineSaveFailed {
                timelineSaveFailed = true
                lastError = String(localized: "录音时间轴保存失败，原始分片已保留。")
            }
        }
    }

    // MARK: - 睡眠抑制

    #if os(macOS)
    /// 录音期间抑制系统空闲睡眠：长录音时避免系统因空闲休眠导致采集中断。
    /// 仅阻止空闲睡眠；合盖/电池策略仍可能休眠，属硬件行为。
    private func beginSleepInhibition() {
        guard sleepInhibitor == nil else { return }
        sleepInhibitor = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .latencyCritical],
            reason: String(localized: "Memozia 正在录音")
        )
        logger.info("已抑制系统空闲睡眠（录音中）")
    }

    private func endSleepInhibition() {
        if let token = sleepInhibitor {
            ProcessInfo.processInfo.endActivity(token)
            sleepInhibitor = nil
            logger.info("已解除系统睡眠抑制")
        }
    }

    // MARK: - 睡眠/唤醒处理（合盖场景）
    //
    // 合盖睡眠会停掉 AVAudioEngine、终止 SCStream；麦克风大概率随配置变化通知自愈，
    // 但系统音频断后不会自动重连。因此录音期间监听唤醒事件，醒来后主动恢复两条链路。

    /// 安装睡眠/唤醒通知观察者（仅录音期间有效）
    private func setupSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemDidWake()
            }
        })
    }

    private func removeSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            center.removeObserver(observer)
        }
        sleepObservers = []
        sleepStartDate = nil
        micActiveBeforeSleep = false
        sysActiveBeforeSleep = false
    }

    /// 系统即将睡眠：记录睡眠开始时间与睡前两轨状态
    /// （唤醒后 SCStream 的错误回调已把采集状态抹掉，不提前记录就无从判断该不该重连）
    private func handleSystemWillSleep() {
        guard isRecording, let session = activeCaptureSession, !isStoppingCapture else { return }
        sleepStartDate = Date()
        captureHealth.handle(.sleep, sessionID: session)
        // 断流通知可能先于睡眠通知到达；按本次实际声源和残留资源决定恢复。
        micActiveBeforeSleep = config.source != .systemAudio
        sysActiveBeforeSleep = config.source != .microphone && systemCapture.canResumeAfterWake
        logger.info("系统即将睡眠（录音中）：mic=\(self.micActiveBeforeSleep) sys=\(self.sysActiveBeforeSleep)")
    }

    /// 系统唤醒：主动恢复两条采集链路，并向用户提示睡眠时段无录音数据
    private func handleSystemDidWake() async {
        guard isRecording, !isStoppingCapture,
              let session = activeCaptureSession, wakeRecoverySession != session,
              let sleepStart = sleepStartDate else { return }
        wakeRecoverySession = session
        defer { if wakeRecoverySession == session { wakeRecoverySession = nil } }
        let restoreSystem = sysActiveBeforeSleep
        let restoreMic = micActiveBeforeSleep
        logger.info("系统唤醒（录音中），开始恢复采集链路")

        var sysOK = true
        if restoreSystem {
            captureHealth.handle(.beginRecovery, sessionID: session)
            let originID = systemCapture.captureID
            let result = LockedBox(false)
            let capture = systemCapture
            let finished = await RacingWatchdog.race(
                name: "唤醒后系统音频恢复", timeout: 30,
                onTimeout: { capture.cancelWakeRecovery(originID: originID) },
                onCancel: { capture.cancelWakeRecovery(originID: originID) }
            ) {
                result.value = await capture.resumeAfterWake(expectedCaptureID: originID)
            }
            sysOK = finished && result.value
            guard activeCaptureSession == session, !isStoppingCapture else { return }
            if !sysOK { captureHealth.handle(.interrupted(), sessionID: session) }
        }

        var micOK = true
        if restoreMic {
            if restoreSystem, sysOK {
                let gap = Date().timeIntervalSince(sleepStart)
                if gap > 1 {
                    let written = await micCapture.writeSilence(for: gap)
                    guard activeCaptureSession == session, !isStoppingCapture else { return }
                    logger.info("睡眠间隙已补写麦克风静音 \(Int(written))s（间隙 \(Int(gap))s）")
                }
            }
            micOK = micCapture.ensureCapturing()
        }

        // 新流首包成功写入才标记 active；启动返回不等于已经录到声音。
        onRecordingStatus?(lastError ?? captureHealth.summary)
        if restoreSystem && !sysOK {
            onRecordingWarning?(String(localized: "系统音频恢复失败，后续系统声音无法录入。请停止录音后重新开始。"))
        }
        if restoreMic && !micOK {
            // 恢复结果由 MicCaptureService 的采集事件上报：立即失败先进入有限重试并只更新横幅，
            // 重试耗尽（recoveryFailed）才作为错误告警，避免「正在恢复」被误报成恢复失败
            logger.warning("唤醒后麦克风恢复未在首次尝试内完成，已进入有限重试")
        }
        // 若本次恢复期间又发生睡眠，保留较新的睡眠记录供下一次唤醒使用。
        if sleepStartDate == sleepStart {
            sleepStartDate = nil
            micActiveBeforeSleep = false
            sysActiveBeforeSleep = false
        }
    }
    #else
    /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
    /// iOS：录音期间阻止屏幕自动锁定（间接避免系统挂起录音）
    private func beginSleepInhibition() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func endSleepInhibition() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
    */
    #endif

    /// 录音中磁盘空间检查：阶梯式预警 + 临界止损
    /// - 剩余 < 1GB：提示一次（按当前码率约还能写半小时～一小时）
    /// - 剩余 < 200MB：不足写完一个 5 分钟分片，立即请求上层停止保全已录内容
    private var lowDiskSpaceWarned = false
    private var diskStopRequested = false
    /// 磁盘容量探测连续失败计数与"已告警"标记。
    /// 旧实现在读不到容量时直接 `return`，等价于「临界止损静默失效」——
    /// 用户可能在毫无提示的情况下一直录到磁盘写满
    private var diskProbeFailures = 0
    private var diskProbeFailureReported = false
    private static let diskProbeFailureThreshold = 3
    /// 磁盘检查节拍器（基准在 `startTimer` 建立；纯逻辑见文件级 `TimePacer`）
    private var diskPacer = TimePacer(interval: diskCheckInterval, lastFiredAt: nil)

    private func checkDiskSpaceWhileRecording() {
        guard !diskStopRequested else { return }
        let freeSpace = try? FileManager.default.attributesOfFileSystem(
            forPath: AudioRecording.storageDirectory.path
        )[.systemFreeSize] as? NSNumber
        guard let freeBytes = freeSpace?.int64Value else {
            // 读不到容量时旧实现直接 return：临界止损（<200MB 自动停录）会静默失效。
            // 连续失败到阈值后给一次可见告警，走录音中实时告警通道
            diskProbeFailures += 1
            if diskProbeFailures >= Self.diskProbeFailureThreshold, !diskProbeFailureReported {
                diskProbeFailureReported = true
                let message = String(localized: "连续多次无法读取磁盘剩余空间，录音的磁盘保护（剩余 200MB 自动停止）可能未生效，请手动留意磁盘空间。")
                logger.error("\(message, privacy: .public)")
                lastError = message
            }
            return
        }
        diskProbeFailures = 0

        if freeBytes < 200 * 1024 * 1024 {
            diskStopRequested = true
            logger.warning("磁盘剩余不足 200MB，停止录音以保全已录内容")
            lastError = String(localized: "磁盘剩余空间不足 200MB（PCM 分片约 1GB/小时），已自动停止录音以保全已录内容。请清理磁盘后重新录制。")
            onRequestStopForDiskPressure?()
            return
        }

        guard !lowDiskSpaceWarned else { return }
        if freeBytes < 1024 * 1024 * 1024 {
            lowDiskSpaceWarned = true
            lastError = String(localized: "磁盘剩余空间不足 1GB，按当前码率较快写满，请尽快停止录音或清理磁盘。")
            logger.warning("录音中磁盘空间不足: \(freeBytes / (1024 * 1024))MB")
        }
    }
}

// MARK: - 静音来源枚举

/// 静音触发来源
enum MuteSource: String {
    case none
    case system   // 系统级静音
    case app      // 应用层静音（Teams/Zoom 等会议软件内静音）
    case local    // 用户手动静音
}

/// 录音服务错误
enum MeetingRecorderError: LocalizedError {
    case insufficientDiskSpace(Int64)
    case exportTimeout
    case alreadyRecording
    /// 录音文件夹创建失败（父目录不可写/磁盘满/同秒重名冲突超上限）
    case folderCreationFailed

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let freeBytes):
            let freeMB = freeBytes / (1024 * 1024)
            return String(format: String(localized: "磁盘空间不足（剩余 %lldMB），录音至少需要 500MB 可用空间。请清理磁盘后重试。"), freeMB)
        case .exportTimeout:
            return String(localized: "音频合并超时，导出已被中断。分片文件已保留在录音文件夹，重新刷新后可自动恢复。")
        case .alreadyRecording:
            return String(localized: "当前已有录音正在进行，请先停止后再开始新录音。")
        case .folderCreationFailed:
            return String(localized: "创建录音文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。")
        }
    }
}

/// 录音中磁盘空间巡检的最小间隔（秒）。
/// 文件级常量而非类型静态成员：属性默认值里不能引用 `Self` 的静态成员
private let diskCheckInterval: TimeInterval = 30

/// 停止采集后冻结的本次录音信息：分片列表与最终输出路径。
///
/// 声明在**文件作用域**而非 `MeetingRecorderService` 的嵌套类型：
/// `@MainActor` 类中的嵌套类型会继承隔离，跨 `await` 传递会受限。
/// 为值类型且成员均 Sendable，可在停止采集与异步合并之间安全交接。
struct CapturedSegments: Sendable {
    let micURLs: [URL]
    let sysURLs: [URL]
    let finalURL: URL
    let micFormatChanged: Bool
}

// MARK: - 定时节拍器

/// 按时间差放行的节拍器（纯值类型，便于回归测试）。
///
/// 存在的理由：项目里多处"每 N 秒做一次"的巡检原先用 `Int(elapsed) % N == 0` 判定，
/// 这要求 1s 定时器**恰好**落在 N 的整数倍上。定时器漂移、系统睡眠后补发/合并 tick、
/// 单次回调耗时超过 1s，都会让某些周期一次都不命中 → 巡检被整段跳过（而不是延后一拍）。
struct TimePacer: Sendable {
    let interval: TimeInterval
    /// 上一次放行的时刻；nil 表示尚未建立基准（下一次调用立即放行）
    private(set) var lastFiredAt: Date?

    init(interval: TimeInterval, lastFiredAt: Date? = nil) {
        self.interval = interval
        self.lastFiredAt = lastFiredAt
    }

    /// 到点则推进基准并返回 true；未到点返回 false 且不改动状态
    mutating func fireIfNeeded(at date: Date) -> Bool {
        guard let last = lastFiredAt else {
            lastFiredAt = date
            return true
        }
        guard date.timeIntervalSince(last) >= interval else { return false }
        lastFiredAt = date
        return true
    }
}
