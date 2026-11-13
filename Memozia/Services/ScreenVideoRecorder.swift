#if os(macOS)
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import AppKit
import os.log

/// 录屏目标。区域矩形为**该显示屏内、左上原点、points** 坐标（选区会话已完成换算）。
enum ScreenRecordingTarget: Sendable {
    /// 鼠标所在显示屏全屏
    case mouseDisplay
    /// 指定显示屏（可选区域内录制）
    case display(id: CGDirectDisplayID, regionInDisplayPoints: CGRect?)
    /// 指定窗口（desktopIndependentWindow 过滤，窗口被遮挡仍可完整采集）
    case window(id: CGWindowID)
}

/// 录屏目标种类（菜单/工具栏/通知 userInfo 传递用）。
/// 统一捕获后：fullScreen 一步直达；region/window 进入带录制出口的捕获会话。
enum ScreenTargetKind: String, Sendable {
    case fullScreen
    case region
    case window
}

/// 录屏质量档位：分辨率上限 / 帧率 / 码率三合一，控制磁盘占用
enum ScreenRecordingQuality: String, CaseIterable, Sendable {
    /// 原生分辨率 30fps ≈18 GB/h
    case best
    /// 长边 ≤2560px 30fps ≈6.8 GB/h（默认）
    case standard
    /// 长边 ≤1920px 15fps ≈2.7 GB/h
    case economy

    static let qualityDefaultsKey = "screen_recording_quality"
    static let sourceDefaultsKey = "screen_recording_source"

    var displayName: String {
        switch self {
        case .best:     return String(localized: "高清")
        case .standard: return String(localized: "标准")
        case .economy:  return String(localized: "省空间")
        }
    }

    var fps: Int {
        switch self {
        case .best, .standard: return 30
        case .economy:         return 15
        }
    }

    /// 输出长边像素上限；nil = 不缩放（原生）
    var maxLongEdgePixels: Int? {
        switch self {
        case .best:     return nil
        case .standard: return 2560
        case .economy:  return 1920
        }
    }

    var videoBitRate: Int {
        switch self {
        case .best:     return 40_000_000
        case .standard: return 15_000_000
        case .economy:  return 6_000_000
        }
    }

    /// 每小时估算字节数（视频码率 + AAC 音频），用于菜单展示与磁盘预检
    var bytesPerHour: Int64 {
        Int64(Double(videoBitRate) / 8 * 3600) + Int64(128_000 / 8 * 3600)
    }

    var estimatedSizeLabel: String {
        let gb = Double(bytesPerHour) / 1_000_000_000
        // 显式传 locale：`String(format:)` 不带 locale 时小数分隔符恒为 "."，
        // 在德/法/俄等用逗号的语言里与界面其他数字不一致
        return String(format: String(localized: "约 %.1f GB/小时"), locale: Locale.current, gb)
    }

    static func saved() -> ScreenRecordingQuality {
        guard let raw = UserDefaults.standard.string(forKey: qualityDefaultsKey),
              let quality = ScreenRecordingQuality(rawValue: raw) else { return .standard }
        return quality
    }

    static func save(_ quality: ScreenRecordingQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: qualityDefaultsKey)
    }

    /// 录屏音频来源（与会议录音 RecordingSource 同一套语义，独立偏好）
    static func savedSource() -> RecordingSource {
        guard let raw = UserDefaults.standard.string(forKey: sourceDefaultsKey),
              let source = RecordingSource(rawValue: raw) else { return .mixed }
        return source
    }

    static func saveSource(_ source: RecordingSource) {
        UserDefaults.standard.set(source.rawValue, forKey: sourceDefaultsKey)
    }
}

/// 屏幕视频轨录制器：SCStream → AVAssetWriter 分片 MP4（碎片化写入，进程被杀时
/// 已落盘片段仍可播放，对齐 PCM 分片的崩溃安全思路）。
///
/// 设计约束（与录屏方案分析一致）：
/// - 音频 m4a 仍由 MeetingRecorderService 现有双轨分片管线负责；本服务只产出视频文件
///   （可选内嵌**系统声**音轨供回放；麦克风人声在 m4a 转写轨里，v1 不进 mp4）。
/// - 与系统音频服务各自持有独立 SCStream：同一次屏幕录制权限覆盖多条流，
///   避免把音频服务的占位丢弃路径改成条件写入带来的回归面。
///
/// 并发模型：@unchecked Sendable + NSLock 保护跨线程状态；采样回调统一在
/// `sampleQueue` 串行处理（与 SystemAudioCaptureService 同一约定）。
final class ScreenVideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum ScreenRecordingError: LocalizedError {
        case alreadyRecording
        case permissionDenied
        case displayUnavailable
        case windowUnavailable
        case insufficientSpace(String)
        case writerSetupFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return String(localized: "已有录屏在进行，请先停止。")
            case .permissionDenied:
                return String(localized: "缺少屏幕录制权限，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Memozia。")
                    + "\n\n" + ScreenCaptureAuthorization.recoveryAdvice
            case .displayUnavailable:
                return String(localized: "未找到目标显示屏（可能刚被拔出），请重试。")
            case .windowUnavailable:
                return String(localized: "目标窗口已关闭或不可录制，请重新选择。")
            case .insufficientSpace(let label):
                return String(label)
            case .writerSetupFailed(let reason):
                return String(format: String(localized: "无法创建录屏文件（%@），请检查磁盘空间与文件夹权限。"), reason)
            }
        }
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "ScreenRecording")

    private let stateLock = NSLock()
    private var _stream: SCStream?
    private var _writer: AVAssetWriter?
    private var _videoInput: AVAssetWriterInput?
    private var _audioInput: AVAssetWriterInput?
    private var _destinationURL: URL?
    private var _sessionStarted = false
    private var _sessionStartTime: CMTime?
    private var _videoFrameCount = 0
    private var _appendFailureReported = false
    private var _isCapturing = false
    private var _diskStopFired = false
    private var diskTimer: DispatchSourceTimer?

    /// 写入背压导致的丢弃计数：`isReadyForMoreMediaData` 为 false 时样本会被静默丢弃，
    /// 旧实现既不计也不报，用户只在回放时发现跳帧/音画不同步
    private var _droppedFrameCount = 0
    private var _droppedAudioSampleCount = 0
    /// 磁盘容量探测连续失败次数与"已提示过"标记：本例程是录屏唯一的磁盘止损
    private var _capacityProbeFailures = 0
    private var _capacityProbeReported = false
    private static let capacityProbeFailureThreshold = 3

    /// 采样串行队列：写入、停止、磁盘巡检共用，保证与 markAsFinished 的先后次序
    private let sampleQueue = DispatchQueue(label: "app.memozia.screenrecording.samples")

    private var _lastError: String?

    /// 中断/失败文案（拔屏、撤权、窗口销毁、收尾异常）：采样队列写、主线程读，
    /// 统一走 stateLock，不做跨线程裸写
    var lastError: String? {
        get { stateLock.withLock { _lastError } }
        set { stateLock.withLock { _lastError = newValue } }
    }

    /// 空间不足以安全继续时触发一次（调用方走正常停止流程保存已有内容）
    var onDiskCritical: (() -> Void)?
    /// 采集中断（音频继续，视频停止）；调用方负责提示
    var onInterrupted: ((String) -> Void)?

    var isRecording: Bool { capturingSnapshot() }

    // MARK: - 锁同步助手
    // Swift 6：NSLock 的 lock/withLock 不能在 async 函数体直接调用（noasync），
    // 所有临界区统一包在这些同步 helper 里；调用方（VM 均在 MainActor）串行发起启停，
    // 快照检查与提交之间的窗口不构成实际竞态。

    private func capturingSnapshot() -> Bool {
        stateLock.withLock { _isCapturing }
    }

    private func commitStarted(
        stream: SCStream,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?,
        destination: URL
    ) {
        stateLock.withLock {
            _stream = stream
            _writer = writer
            _videoInput = videoInput
            _audioInput = audioInput
            _destinationURL = destination
            _sessionStarted = false
            _sessionStartTime = nil
            _videoFrameCount = 0
            _appendFailureReported = false
            _diskStopFired = false
            _droppedFrameCount = 0
            _droppedAudioSampleCount = 0
            _capacityProbeFailures = 0
            _capacityProbeReported = false
            _isCapturing = true
        }
    }

    /// SCStream 是否仍持有资源（含异常断流后保留待 finalize 的 writer）
    private func hasPendingResources() -> Bool {
        stateLock.withLock { _writer != nil || _stream != nil }
    }

    /// 取出并清空资源用于停止收尾。
    ///
    /// 清理依据是「资源是否存在」而非 `_isCapturing`：SCStream 异常停止
    /// （`didStopWithError`）会把 `_isCapturing` 置 false 却**保留** writer，
    /// 若此处仍以 `_isCapturing` 为门槛就会漏掉 finalize —— 表现为 moov 未封装
    /// （`hasPlayableVideoTrack` 判不可播 → 视频被当纯音频入库）、`_destinationURL`
    /// 残留、writer 与其缓冲区永久泄漏。改为资源存在即返回，同时保证 stop() 幂等。
    private func takeStopSnapshot() -> (SCStream?, AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, URL?) {
        stateLock.withLock {
            let tuple = (_stream, _writer, _videoInput, _audioInput, _destinationURL)
            _isCapturing = false
            _stream = nil; _writer = nil; _videoInput = nil; _audioInput = nil
            return tuple
        }
    }

    private func clearDestination() {
        stateLock.withLock { _destinationURL = nil }
    }

    /// 启动录制。`includeSystemAudio` 对应“系统声音”开关；麦克风由录音服务管。
    func start(
        to url: URL,
        target: ScreenRecordingTarget,
        quality: ScreenRecordingQuality,
        includeSystemAudio: Bool
    ) async throws {
        // 采集中或仍有未收尾的资源（如断流后保留待 finalize 的 writer）都拒绝重复启动，
        // 否则 commitStarted 会直接覆写旧 writer，导致上一个文件永不 finalize
        guard !capturingSnapshot(), !hasPendingResources() else {
            throw ScreenRecordingError.alreadyRecording
        }

        // 磁盘预检：至少留出「2GB 或 半小时预估量」取大
        let floor = max(2_000_000_000, quality.bytesPerHour / 2)
        if let free = Self.availableCapacity(for: url), free < floor {
            throw ScreenRecordingError.insufficientSpace(String(
                format: String(localized: "磁盘空间不足：剩余 %@，本次录屏前请先清理或改用「省空间」质量。"),
                Self.humanSize(free)
            ))
        }

        let content: SCShareableContent
        do { content = try await ScreenCaptureAuthorization.content(onScreenWindowsOnly: true) }
        catch ScreenCaptureAuthorization.Failure.denied { throw ScreenRecordingError.permissionDenied }
        try Task.checkCancellation()

        // 目标解析 + 几何计算（sourceRect 用显示屏内 points，输出宽高用目标像素）
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var contentWidthPx: Int
        var contentHeightPx: Int

        switch target {
        case .mouseDisplay, .display:
            let displayID: CGDirectDisplayID
            var regionPoints: CGRect?
            switch target {
            case .mouseDisplay:
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
                guard let screen,
                      let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    throw ScreenRecordingError.displayUnavailable
                }
                displayID = id
            case .display(let id, let region):
                displayID = id
                regionPoints = region
            case .window:
                // 外层已分支到窗口，不可达；满足穷举
                throw ScreenRecordingError.windowUnavailable
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.displayUnavailable
            }
            guard let screen = Self.screen(for: displayID) else {
                throw ScreenRecordingError.displayUnavailable
            }
            let scale = screen.backingScaleFactor
            if let region = regionPoints {
                let clamped = region.intersection(CGRect(origin: .zero, size: screen.frame.size))
                guard clamped.width >= 20, clamped.height >= 20 else {
                    throw ScreenRecordingError.displayUnavailable
                }
                config.sourceRect = clamped
                contentWidthPx = Int((clamped.width * scale).rounded())
                contentHeightPx = Int((clamped.height * scale).rounded())
            } else {
                contentWidthPx = Int((screen.frame.width * scale).rounded())
                contentHeightPx = Int((screen.frame.height * scale).rounded())
            }
            filter = SCContentFilter(display: display, excludingWindows: [])

        case .window(let windowID):
            guard let window = content.windows.first(where: {
                $0.windowID == windowID && $0.windowLayer == 0
            }) else {
                Self.logger.error("未找到录屏目标窗口（id=\(windowID)）：可能已关闭或层级变化")
                throw ScreenRecordingError.windowUnavailable
            }
            // 诊断：明确本次录的是哪个窗口（只记 ID/层级/宿主 App，不记窗口标题等用户内容），
            // 便于排查「点选窗口后录成别的窗口」这类目标定位问题
            Self.logger.debug("录屏目标窗口 id=\(windowID) layer=\(window.windowLayer) owner=\(window.owningApplication?.applicationName ?? "?", privacy: .public) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
            let scale = NSScreen.screens.first(where: { $0.frame.intersects(Self.appKitFrame(of: window)) })?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2
            contentWidthPx = Int((window.frame.width * scale).rounded())
            contentHeightPx = Int((window.frame.height * scale).rounded())
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        // 质量档位长边缩放；宽高取偶数满足编码器约束
        if let cap = quality.maxLongEdgePixels {
            let longEdge = max(contentWidthPx, contentHeightPx)
            if longEdge > cap {
                let factor = Double(cap) / Double(longEdge)
                contentWidthPx = Int(Double(contentWidthPx) * factor)
                contentHeightPx = Int(Double(contentHeightPx) * factor)
            }
        }
        config.width = max(2, contentWidthPx - contentWidthPx % 2)
        config.height = max(2, contentHeightPx - contentHeightPx % 2)
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))

        if includeSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // 碎片化 MP4：每 5s 自增片段落盘，进程被杀时已写内容仍可播放
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: quality.videoBitRate,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeSystemAudio {
            let ai = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVEncoderBitRateKey: 128_000,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                ]
            )
            ai.expectsMediaDataInRealTime = true
            writer.add(ai)
            audioInput = ai
        }

        // startWriting 不抛错：失败经 status/.error 暴露后取消收尾
        writer.startWriting()
        guard writer.status == .writing else {
            let reason = writer.error?.localizedDescription ?? "未知错误"
            writer.cancelWriting()
            throw ScreenRecordingError.writerSetupFailed(reason)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if includeSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            throw error
        }

        commitStarted(
            stream: stream,
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            destination: url
        )
        // 登记为"在录实例"：退出收尾路径无法从 ViewModel 拿到本实例，
        // 只能靠这张弱引用登记表按「资源是否存在」找到它并收尾
        Self.register(self)

        startDiskWatch(quality: quality, url: url)
        Self.logger.info("录屏已启动：\(url.lastPathComponent, privacy: .public) \(config.width)x\(config.height)@\(quality.fps)fps")
    }

    /// 收尾（markAsFinished + finishWriting）最长等待：正常只需补写 moov，给足冗余但不无限等
    private static let defaultFinalizeTimeout: TimeInterval = 120

    /// 停止并封装文件。返回最终 URL（文件存在且非空即返回，碎片化写入保证中断后可播）。
    /// - Parameter timeout: finishWriting 最长等待；退出收尾用较短上界，避免阻塞进程退出
    func stop(timeout: TimeInterval = ScreenVideoRecorder.defaultFinalizeTimeout) async -> URL? {
        stopDiskWatch()

        let (stream, writer, videoInput, audioInput, destination) = takeStopSnapshot()
        // 资源已取出：无论后续是否 finalize 成功，本实例都不再是"在录实例"
        Self.unregister(self)
        guard let destination else { return nil }

        if let stream {
            try? await stream.stopCapture()
        }
        guard let writer else {
            // 从未在录或已停止：文件此前已 finalize，存在即返回
            return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
        }

        // sampleQueue 串行使 markAsFinished 晚于最后一个采样回调。
        // AVAssetWriter/Input 非 Sendable：与导出链路同一交接风格，
        // 仅限 sampleQueue 上独占操作，完成后不再触碰
        nonisolated(unsafe) let w = writer
        nonisolated(unsafe) let vIn = videoInput
        nonisolated(unsafe) let aIn = audioInput
        let queue = sampleQueue
        // finishWriting 不回调会让停止流程永久卡住（与导出链路的挂起前科同类），
        // 按工程既有 RacingWatchdog 兜底。超时不取消 writer：容器已落盘，
        // 此刻取消只会把可播片段一起毁掉，交给调用方的可播性校验判断
        let finalized = await RacingWatchdog.race(
            name: "录屏收尾 \(destination.lastPathComponent)",
            timeout: timeout
        ) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    vIn?.markAsFinished()
                    aIn?.markAsFinished()
                    if w.status == .writing {
                        w.finishWriting {
                            continuation.resume()
                        }
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        var result: URL?
        if writer.status == .completed {
            result = destination
        } else {
            let frameCount = stateLock.withLock { _videoFrameCount }
            let reason: String
            if !finalized {
                reason = "收尾超时（finishWriting 未回调，已放弃等待）"
            } else if let error = writer.error {
                reason = error.localizedDescription
            } else if frameCount == 0 {
                reason = "未收到任何完整画面帧（屏幕采集未出帧）"
            } else {
                reason = "未知"
            }
            let message = "录屏视频轨封装异常（\(reason)），已写入片段可能不完整，音频不受影响。"
            Self.logger.error("\(message, privacy: .public)")
            lastError = message
            result = FileManager.default.fileExists(atPath: destination.path) ? destination : nil
        }
        // 背压丢样本的汇总提示：仅在本次没有更严重的错误时提示，
        // 让"回放跳帧/音画不同步"有可追溯的原因
        let drops = stateLock.withLock { (_droppedFrameCount, _droppedAudioSampleCount) }
        if (drops.0 > 0 || drops.1 > 0), lastError == nil {
            let message = String(
                format: String(localized: "录屏写入跟不上采集速度，已丢弃 %lld 帧画面与 %lld 个音频缓冲，回放时可能有轻微跳帧或音画不同步。"),
                drops.0, drops.1
            )
            Self.logger.warning("\(message, privacy: .public)")
            lastError = message
        }
        clearDestination()
        Self.logger.info("录屏已停止：\(destination.lastPathComponent, privacy: .public)")
        return result
    }

    /// 退出/紧急路径快速收尾：碎片化文件无需 finishWriting 即可播放，仅停采集
    func stopCaptureOnly() {
        let (stream, discarded) = stateLock.withLock { () -> (SCStream?, URL?) in
            let current = _stream
            let destination = _destinationURL
            _stream = nil
            _writer = nil
            _videoInput = nil
            _audioInput = nil
            _destinationURL = nil
            _isCapturing = false
            return (current, destination)
        }
        if let discarded {
            // 该路径不复位 destination，mp4 不会登记进条目，成为无人引用的孤儿产物；
            // 留一条日志便于磁盘排查（碎片化文件仍可播放，故不主动删除以免误删有效数据）
            Self.logger.warning("录屏快速收尾：未登记的视频文件保留在磁盘 \(discarded.lastPathComponent, privacy: .public)")
        }
        Self.unregister(self)
        stopDiskWatch()
        Task { [stream] in
            try? await stream?.stopCapture()
        }
    }

    // MARK: - 在录实例登记（退出收尾用）

    /// 正在录屏的实例登记表。
    ///
    /// 为什么需要它：`ScreenVideoRecorder` 由 `RecordingViewModel` 私有持有，而应用退出
    /// 收尾走的是 `MeetingRecorderService.finalizeForTermination()`（只认识音频服务），
    /// 拿不到 VM 里的这个实例。旧行为下录屏中退出，SCStream 与 AVAssetWriter 都不会被停，
    /// 只能靠 `movieFragmentInterval` 留下碎片。这里用弱引用登记，让退出路径按
    /// 「资源是否存在」逐实例收尾，与 `takeStopSnapshot` 的清理判据保持一致。
    /// 可变状态由内部 NSLock 保护（@unchecked Sendable）。
    private final class ActiveRecorderRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var boxes: [WeakRecorderBox] = []

        func register(_ recorder: ScreenVideoRecorder) {
            lock.lock(); defer { lock.unlock() }
            boxes.removeAll { $0.value == nil || $0.value === recorder }
            boxes.append(WeakRecorderBox(recorder))
        }

        func unregister(_ recorder: ScreenVideoRecorder) {
            lock.lock(); defer { lock.unlock() }
            boxes.removeAll { $0.value == nil || $0.value === recorder }
        }

        /// 取出仍存在的在录实例（顺带清理已释放的弱引用）
        func activeSnapshot() -> [ScreenVideoRecorder] {
            lock.lock(); defer { lock.unlock() }
            boxes.removeAll { $0.value == nil }
            return boxes.compactMap(\.value)
        }
    }

    private final class WeakRecorderBox {
        weak var value: ScreenVideoRecorder?
        init(_ value: ScreenVideoRecorder) { self.value = value }
    }

    private static let recorderRegistry = ActiveRecorderRegistry()

    private static func register(_ recorder: ScreenVideoRecorder) {
        recorderRegistry.register(recorder)
    }

    private static func unregister(_ recorder: ScreenVideoRecorder) {
        recorderRegistry.unregister(recorder)
    }

    static var hasResourcesPreventingUpdate: Bool {
        recorderRegistry.activeSnapshot().contains { $0.hasPendingResources() }
    }

    /// 应用退出收尾：把所有仍有未收尾资源的实例有界收尾。
    ///
    /// 碎片化 mp4 不 `finishWriting` 也可播放，这里优先尝试补写 moov 以得到完整可播文件；
    /// 到点未完成即放弃，回落到「碎片已落盘」这一兜底，不阻塞进程退出。
    /// 已 finalize 的实例（`hasPendingResources` 为 false）直接跳过，保证幂等。
    static func finalizeActiveRecordersForTermination(timeout: TimeInterval = 10) async {
        let pending = recorderRegistry.activeSnapshot().filter { $0.hasPendingResources() }
        guard !pending.isEmpty else { return }
        logger.warning("应用退出：收尾 \(pending.count) 路仍在录制的视频轨")
        for recorder in pending {
            _ = await recorder.stop(timeout: timeout)
        }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ aStream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // 全程在 sampleQueue（添加输出时指定）串行执行；状态经 NSLock 快照后本地使用
        let (writing, writer, videoInput, audioInput, started, sessionStart) = stateLock.withLock {
            (_isCapturing, _writer, _videoInput, _audioInput, _sessionStarted, _sessionStartTime)
        }
        guard writing, let writer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMSampleBufferIsValid(sampleBuffer), pts.isValid else { return }

        if type == .screen {
            // idle/blank/suspended 帧没有生成新画面（无图像数据）：追加会让 writer 进入 failed，
            // 表现为容器缺少 moov、文件损坏且体积异常小
            guard Self.isAppendableScreenFrame(sampleBuffer) else { return }
            if !started {
                // 首帧 PTS 作为会话起点：音视频样本保留原始 PTS，writer 自动做相对偏移，
                // 两轨相对时间轴天然对齐（同系统音频服务“首包定标”先例）
                let claimed = stateLock.withLock { () -> Bool in
                    guard !_sessionStarted else { return false }
                    _sessionStarted = true
                    _sessionStartTime = pts
                    return true
                }
                guard claimed, writer.status == .writing else { return }
                writer.startSession(atSourceTime: pts)
            }
            guard let videoInput, writer.status == .writing else { return }
            // 背压（写入跟不上采集）时该帧会被丢弃：计数留痕，停止时汇总提示，
            // 不再像旧实现那样完全静默
            guard videoInput.isReadyForMoreMediaData else {
                stateLock.withLock { _droppedFrameCount += 1 }
                return
            }
            if videoInput.append(sampleBuffer) {
                stateLock.withLock { _videoFrameCount += 1 }
            } else {
                reportAppendFailure(writer, track: "视频")
            }
        } else {
            // 会话开始前的音频（无视频锚点）直接丢弃，最多损失首帧前片段
            guard started, let audioInput, writer.status == .writing else { return }
            // 早于会话起点的样本无法定位到会话时间轴，追加会让 writer 失败
            if let sessionStart, pts < sessionStart { return }
            guard audioInput.isReadyForMoreMediaData else {
                stateLock.withLock { _droppedAudioSampleCount += 1 }
                return
            }
            if !audioInput.append(sampleBuffer) {
                reportAppendFailure(writer, track: "音频")
            }
        }
    }

    /// 该帧是否携带可编码的画面。
    /// SDK 语义：complete = 生成了新帧；started = 流启动后的第一帧（同为真实画面）；
    /// idle / blank / suspended / stopped = 未生成新帧，追加会让 writer 进入 failed
    private static func isAppendableScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete || status == .started
    }

    /// 追加失败上报（只报首次）：append 失败会让 writer 立刻 failed，后续帧被静默丢弃
    private func reportAppendFailure(_ writer: AVAssetWriter, track: String) {
        let first = stateLock.withLock { () -> Bool in
            guard !_appendFailureReported else { return false }
            _appendFailureReported = true
            return true
        }
        guard first else { return }
        let message = "录屏\(track)轨写入失败（\(writer.error?.localizedDescription ?? "未知")），视频可能不完整，音频不受影响。"
        Self.logger.error("\(message, privacy: .public)")
        lastError = message
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ aStream: SCStream, didStopWithError error: Error) {
        // 拔屏/撤销权限/窗口销毁：停视频保现场，音频轨继续
        stateLock.withLock {
            _stream = nil
            _isCapturing = false
        }
        stopDiskWatch()
        let message = "画面采集已中断（\(error.localizedDescription)），录音继续进行，视频保留到中断时刻。"
        Self.logger.error("\(message, privacy: .public)")
        lastError = message
        let callback = onInterrupted
        DispatchQueue.main.async { callback?(message) }
    }

    // MARK: - 磁盘巡检

    private func startDiskWatch(quality: ScreenRecordingQuality, url: URL) {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        let floor = max(2_000_000_000, quality.bytesPerHour / 6)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let recording = self.stateLock.withLock { self._isCapturing }
            guard recording else { return }
            guard let free = Self.availableCapacity(for: url) else {
                // 读不到容量不能静默跳过：本巡检是录屏唯一的磁盘止损，
                // 持续探测失败等于止损整段失效（用户会一直录到磁盘写满）
                self.noteCapacityProbeFailure()
                return
            }
            self.resetCapacityProbeFailures()
            guard free < floor else { return }
            let first = self.stateLock.withLock { () -> Bool in
                guard !self._diskStopFired else { return false }
                self._diskStopFired = true
                return true
            }
            guard first else { return }
            let callback = self.onDiskCritical
            DispatchQueue.main.async { callback?() }
        }
        timer.resume()
        stateLock.withLock { diskTimer = timer }
    }

    private func stopDiskWatch() {
        let timer = stateLock.withLock { () -> DispatchSourceTimer? in
            let current = diskTimer
            diskTimer = nil
            return current
        }
        timer?.cancel()
    }

    /// 记录一次容量探测失败；连续失败到阈值后给一次可见提示（会话内仅一次）
    private func noteCapacityProbeFailure() {
        let shouldReport = stateLock.withLock { () -> Bool in
            _capacityProbeFailures += 1
            guard _capacityProbeFailures >= Self.capacityProbeFailureThreshold else { return false }
            guard !_capacityProbeReported else { return false }
            _capacityProbeReported = true
            return true
        }
        guard shouldReport else { return }
        let message = String(localized: "连续多次无法读取磁盘剩余容量，本次录屏的磁盘空间保护可能未生效，请留意磁盘空间。")
        Self.logger.error("\(message, privacy: .public)")
        lastError = message
    }

    /// 探测成功后复位失败计数（避免偶发失败累积到阈值后误报）
    private func resetCapacityProbeFailures() {
        stateLock.withLock { _capacityProbeFailures = 0 }
    }

    // MARK: - Helpers

    /// 视频轨是否真的可播放（容器已封装 moov 且含时长大于 0 的视频轨）。
    /// 替代「文件字节数」启发式：静止画面的录屏可合法压缩到很小，字节数会误判为保存失败
    static func hasPlayableVideoTrack(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return false }
        return CMTimeGetSeconds(duration) > 0
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    /// SCWindow.frame（左上原点全局坐标）→ AppKit 坐标系（左下原点），仅用于匹配所在屏
    private static func appKitFrame(of window: SCWindow) -> NSRect {
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(
            x: window.frame.minX,
            y: mainMaxY - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        )
    }

    private static func availableCapacity(for url: URL) -> Int64? {
        do {
            let values = try url.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            // 取不到容量时磁盘巡检会直接跳过（fail-open），且 20s 巡检也静默失效；
            // 记录一次，避免“磁盘将满却完全没有任何痕迹”
            logger.error("读取磁盘剩余容量失败，录屏磁盘止损本次跳过：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
