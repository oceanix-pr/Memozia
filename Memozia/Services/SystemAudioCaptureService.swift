import Foundation
import AVFoundation
import os.log
#if os(macOS)
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
#endif

/// 系统音频采集服务（基于 ScreenCaptureKit）
///
/// 使用 ScreenCaptureKit 采集系统输出音频。
/// 注意：即使只录音频，ScreenCaptureKit 也需要用户授予"屏幕录制"权限。
/// 首次调用 SCShareableContent 时会触发系统授权对话框。
///
/// 仅支持 macOS（iOS 无此框架的系统音频捕获能力）。
#if os(macOS)
final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum EventKind: Sendable {
        case interrupted(Error)
        case writerFailed
        case samplesDropped(Int)
        case recovered
    }

    struct StopResult: Sendable {
        let wasInterrupted: Bool
        let writerFailed: Bool
        let droppedSamples: Int
    }

    struct Event: Sendable {
        let captureID: UUID
        let kind: EventKind
    }

    /// 统一 macOS 26+ Receiver 与旧版 AVAssetWriterInput 的最小写入接口。
    /// 实例始终只在 writeQueue 使用，类本身负责封装跨版本的非 Sendable AVFoundation 对象。
    private final class WriterEndpoint: @unchecked Sendable {
        private let appendBlock: (CMSampleBuffer) throws -> Bool
        private let finishBlock: () -> Void

        init(
            append: @escaping (CMSampleBuffer) throws -> Bool,
            finish: @escaping () -> Void
        ) {
            appendBlock = append
            finishBlock = finish
        }

        func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
            try appendBlock(sampleBuffer)
        }

        func finish() {
            finishBlock()
        }
    }

    private let logger = Logger(subsystem: "app.memozia", category: "SystemAudioCapture")
    private let loadContent: @Sendable () async throws -> SCShareableContent

    init(loadContent: @escaping @Sendable () async throws -> SCShareableContent = {
        try await ScreenCaptureAuthorization.content()
    }) {
        self.loadContent = loadContent
        super.init()
    }

    /// 静态方法（createWriter/finalizeWriter）使用的日志器
    private static let staticLogger = Logger(subsystem: "app.memozia", category: "SystemAudioCapture")

    /// 状态锁：保护所有跨线程访问的可变状态
    /// 本类是 @unchecked Sendable，内部通过 NSLock 提供实际线程安全
    private let stateLock = NSLock()
    private var _stream: SCStream?
    private var _writer: AVAssetWriter?
    private var _writerEndpoint: WriterEndpoint?

    /// 采集状态机：是否要清理由「资源在不在」决定，而不是单个布尔标志。
    ///
    /// 旧实现只有 `_isCapturing` 一个布尔值，且 stop() 以它作为唯一清理门槛，两种路径会漏清理：
    /// - `start()` 先安装 stream/writer 再 `startCapture()`：抛错时 writer 已安装，标志仍是 false；
    /// - SCStream 异常停止回调把标志置 false，却把 writer/stream 留在状态里。
    /// 两者都让 stop() 判定「无需清理」直接返回，遗留未 finalize 的音频分片、文件句柄与旧 stream
    /// （录音停录后系统音轨分片不完整，只能靠磁盘扫描修补）。
    private enum CaptureState {
        /// 无资源，可启动
        case idle
        /// 资源已安装，正在等待 startCapture() 返回
        case starting
        /// 正常采集中
        case running
        /// 唤醒后替换旧流；旧流已摘除，writer 仍归当前录音持有。
        case reconnecting
        /// stop() 已取走资源，正在收尾（stopCapture + finalize）
        case stopping
        /// 启动失败或流异常停止：资源仍在，等待 stop() 收尾
        case failed
    }

    private var _state: CaptureState = .idle

    var hasResourcesPreventingUpdate: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .idle = _state { return _stream != nil || _writer != nil }
        return true
    }
    /// 写入会话是否已开始（首包到达时以其 PTS 为起点，保证时间戳从 0 开始）
    private var _timeline: RecordingSegmentTimelineStore?
    private var _sessionStartTime: TimeInterval?
    private var _sessionStarted = false
    private let writeQueue = DispatchQueue(label: "app.memozia.systemaudio.write")
    /// 占位屏幕输出的派发队列：只录音频时 SCStream 仍会产生视频帧，
    /// 注册占位 .screen 输出（回调直接丢弃非音频样本）消除框架
    /// “stream output NOT found. Dropping frame” 报错；独立队列避免与音频写入争用
    private let screenDiscardQueue = DispatchQueue(label: "app.memozia.systemaudio.screenDiscard")

    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _captureID = UUID()
    private var _awaitingRecoverySample = false
    private var _userStopped = false
    private var _wakeOriginID: UUID?
    /// 上一次因 append 失败写日志的时间（采样级失败不去抖会刷屏）
    private var _lastAppendErrorLoggedAt: Date?
    /// append 失败是否已上报过（同一会话只上报一次，避免反复弹窗）
    private var _appendFailureReported = false
    /// writer 背压时丢弃的音频样本数（会话内累计）。
    private var _droppedSampleCount = 0
    /// 背压丢样本是否已上报过（与 append 失败分开计数：两者语义不同，不能互相吃掉上报机会）
    private var _dropReported = false
    /// 累计丢到该数量才上报：单次丢一两帧通常不可闻，避免健康会话误报
    private static let droppedSampleReportThreshold = 25

    /// AVAssetWriter 写入失败错误（携带原始原因，便于上报时给出真实信息）
    private struct WriterAppendError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// 当前是否正在采集（`failed`（异常停止）与 `starting` 都不算活跃）
    var capturing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state == .running
    }

    /// 带采集代次的事件；接收方切换 actor 后必须再次校验代次。
    var onEvent: (@Sendable (Event) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onEvent = newValue }
    }

    func isCurrentEvent(_ event: Event) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard event.captureID == _captureID, _stream != nil, let writer = _writer else { return false }
        switch event.kind {
        case .interrupted: return _state == .failed
        case .recovered: return _state == .running && writer.status == .writing
        case .writerFailed, .samplesDropped: return true
        }
    }

    var captureID: UUID {
        stateLock.lock(); defer { stateLock.unlock() }
        return _captureID
    }

    /// 超时/取消只撤销对应恢复；旧任务不得撤销新录音或较新的恢复。
    func cancelWakeRecovery(originID: UUID) {
        stateLock.lock()
        guard _wakeOriginID == originID else { stateLock.unlock(); return }
        let stream = _stream
        _stream = nil
        _captureID = UUID()
        _wakeOriginID = nil
        _state = .failed
        stateLock.unlock()
        if let stream { Task { await Self.stopStream(stream) } }
    }

    /// failed 仍持有待收尾资源；不能用 capturing 判断是否需要恢复。
    var canResumeAfterWake: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !_userStopped && _writer != nil && (_state == .failed || _state == .running)
    }

    // MARK: - 权限检查

    /// 检查屏幕录制权限状态（不触发弹窗）
    /// - Returns: true=已授权，false=未授权或未决定
    static func preflightPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 开始采集系统音频
    /// - Parameter url: 目标文件 URL（m4a）
    func start(to url: URL, timeline: RecordingSegmentTimelineStore? = nil,
               authorizedContent: SCShareableContent? = nil) async throws {
        // 在第一个 await 前原子占用 idle→starting，避免两个并发 start 都通过检查。
        guard let startID = reserveStart() else {
            logger.warning("系统音频采集已在启动、运行或收尾，拒绝重复启动")
            throw SystemAudioError.alreadyCapturing
        }
        var resourcesInstalled = false
        defer {
            if !resourcesInstalled { releaseStartReservation(matching: startID) }
        }

        let content: SCShareableContent
        do {
            if let authorizedContent { content = authorizedContent }
            else { content = try await loadContent() }
        } catch ScreenCaptureAuthorization.Failure.denied {
            throw SystemAudioError.permissionNotGranted
        }
        try Task.checkCancellation()
        guard isCurrentStart(startID) else { throw SystemAudioError.startInterrupted }
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayFound
        }

        // 3. 配置过滤器与采集参数（只录音频）
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // 排除自身输出，避免回授
        config.channelCount = 2
        config.sampleRate = 48000
        // 只录音频但 SCStream 仍会产视频帧：把帧率压到最低，减少占位屏幕输出的无谓开销
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // 4. 创建 SCStream
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        // 注册占位屏幕输出：未注册 .screen 时框架视频回调找不到输出，
        // 持续报 “stream output NOT found. Dropping frame”；屏幕样本在回调中直接丢弃
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenDiscardQueue)

        // 5. 配置 AVAssetWriter（直接接收 CMSampleBuffer，无需转换）
        let (newWriter, newEndpoint) = try Self.createWriter(at: url)
        // 不在此处 startSession：SCStream 的采样时间戳不从 0 开始，
        // 改为首包到达时以其 PTS 作为会话起点（见 stream 回调），避免音轨开头出现大段空白/与麦克风轨错位

        // 6. 赋值到共享状态（同步辅助方法内持锁，NSLock 不能在 async 上下文直接使用）
        // 状态进入 starting：资源已存在但尚未开始采集
        guard installCaptureState(stream: newStream, writer: newWriter, endpoint: newEndpoint,
                                  timeline: timeline, startID: startID) else {
            await Self.finalizeWriter(writer: newWriter, endpoint: newEndpoint, on: writeQueue)
            throw SystemAudioError.startInterrupted
        }
        resourcesInstalled = true

        // 7. 启动采集；失败必须回滚已安装的资源，否则 writer 永不 finalize、
        // 分片容器不完整且文件句柄泄漏（旧实现把残留资源留在状态里，stop() 又因
        // 标志为 false 判定无需清理）
        do {
            try await newStream.startCapture()
        } catch {
            await rollbackFailedStart(stream: newStream)
            throw error
        }

        guard markRunningIfCurrent(newStream) else {
            throw SystemAudioError.startInterrupted
        }
        logger.info("系统音频采集已启动: \(url.lastPathComponent)")
    }

    /// 启动失败回滚：停掉刚建的 stream 并 finalize/清空已安装的 writer，交还 idle
    private func rollbackFailedStart(stream: SCStream) async {
        let detached = detachCaptureState(matching: stream)
        await Self.stopStream(stream)
        await Self.finalizeWriter(writer: detached.writer, endpoint: detached.writerEndpoint, on: writeQueue)
        markIdleIfStopping()
        logger.error("系统音频启动失败，已回滚 stream 与 writer")
    }

    /// 唤醒重连：系统睡眠会终止 SCStream（错误回调把状态标为 failed），
    /// 但 writer 仍然有效；重建 SCStream 后继续向当前分片写入。
    /// 不重置会话起点：新采样以 PTS 间隙追加，睡眠时段表现为静音，时间轴保持连续。
    /// - Returns: 是否重连成功
    func resumeAfterWake(expectedCaptureID: UUID) async -> Bool {
        // 同步辅助方法内持锁（NSLock 不能在 async 上下文直接使用）
        let snapshot = beginWakeRecovery(expectedCaptureID: expectedCaptureID)
        // 无 writer（从未采集或已停止）时不重连
        guard let expectedWriter = snapshot.writer else { return false }

        // 旧流可能还存活（部分唤醒路径不报错），先尝试停掉再建新流
        if let oldStream = snapshot.stream {
            await Self.stopStream(oldStream)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                throw SystemAudioError.noDisplayFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.channelCount = 2
            config.sampleRate = 48000
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenDiscardQueue)
            guard installReconnectingStream(newStream, expectedWriter: expectedWriter, originID: expectedCaptureID) else {
                markWakeRecoveryFailed(expectedWriter: expectedWriter, originID: expectedCaptureID)
                return false
            }
            do {
                try await newStream.startCapture()
            } catch {
                cancelWakeRecovery(originID: expectedCaptureID)
                throw error
            }

            // 上述 await 期间用户可能已停止录音（或停止后重开）：仅在仍是同一会话
            // （writer 未被替换、状态仍为 failed/running）时才装回。旧实现无条件
            // 写回 _state = .running，会让已停止会话"复活"成无人回收的幽灵采集
            // （持续采集系统音频 + 泄漏文件句柄）。
            guard lockedInstallStreamIfCurrent(newStream, expectedWriter: expectedWriter, originID: expectedCaptureID) else {
                markWakeRecoveryFailed(expectedWriter: expectedWriter, originID: expectedCaptureID)
                await Self.stopStream(newStream)
                logger.info("唤醒重连在途期间会话已结束，已丢弃新建的采集流")
                return false
            }
            logger.info("唤醒后系统音频采集已重连")
            return true
        } catch {
            markWakeRecoveryFailed(expectedWriter: expectedWriter, originID: expectedCaptureID)
            logger.error("唤醒后系统音频重连失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 唤醒重连前的状态快照：旧流引用 + writer 引用（后者用于重连后校验会话未变）
    private func beginWakeRecovery(expectedCaptureID: UUID) -> (stream: SCStream?, writer: AVAssetWriter?) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _captureID == expectedCaptureID, !Task.isCancelled,
              !_userStopped, let writer = _writer,
              _state == .failed || _state == .running else { return (nil, nil) }
        let oldStream = _stream
        _stream = nil
        _wakeOriginID = expectedCaptureID
        _captureID = UUID() // 旧流及其已排进 MainActor 的事件立即失效。
        _state = .reconnecting
        _awaitingRecoverySample = true
        return (oldStream, writer)
    }

    private func installReconnectingStream(
        _ stream: SCStream, expectedWriter: AVAssetWriter, originID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !Task.isCancelled, _wakeOriginID == originID,
              _state == .reconnecting, _writer === expectedWriter,
              expectedWriter.status == .writing else { return false }
        _stream = stream
        return true
    }

    private func markWakeRecoveryFailed(expectedWriter: AVAssetWriter, originID: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if _wakeOriginID == originID, _writer === expectedWriter, _state == .reconnecting { _state = .failed }
    }

    /// 重连成功后安装新流并恢复采集状态。
    /// 必须确认 writer、新流和 reconnecting 状态仍归本次恢复持有；
    /// 否则返回 false，调用方需停掉新流。
    private func lockedInstallStreamIfCurrent(
        _ stream: SCStream, expectedWriter: AVAssetWriter, originID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !Task.isCancelled, _wakeOriginID == originID,
              _writer === expectedWriter, _stream === stream,
              _state == .reconnecting, expectedWriter.status == .writing else {
            return false
        }
        _stream = stream
        _state = .running
        return true
    }

    /// 分片轮转：创建新 writer 接管后续采样，旧 writer 异步 finalize。
    /// finalize 后的分片立即可播放，任何时刻硬崩溃最多丢失当前未关闭的一片。
    /// 新 writer 创建失败时保留旧 writer 继续写入，不丢数据。
    /// - Parameter url: 新分片的目标 URL
    /// - Returns: 是否轮转成功
    func rotateWriter(to url: URL) async -> Bool {
        guard lockedState() == .running else { return false }
        // 1. 创建新 writer（失败则继续用旧 writer）
        let newPair: (writer: AVAssetWriter, endpoint: WriterEndpoint)
        do {
            newPair = try Self.createWriter(at: url)
        } catch {
            logger.error("分片轮转失败，继续写入旧分片: \(error.localizedDescription)")
            return false
        }

        // 2. 持锁原子替换；重置会话起点，新 writer 的首包会重新 startSession
        // （同步辅助方法内持锁，NSLock 不能在 async 上下文直接使用）
        let old = swapWriterState(writer: newPair.writer, endpoint: newPair.endpoint)
        guard old.swapped else { return false }

        // 3. finalize 旧 writer（markAsFinished + finishWriting 后 WAV 容器完整，分片可播放）
        await Self.finalizeWriter(writer: old.writer, endpoint: old.endpoint, on: writeQueue)
        logger.info("系统音频分片轮转完成: \(url.lastPathComponent)")
        return true
    }

    /// 持锁原子替换 writer/endpoint；未在采集时不替换（返回 swapped=false）
    private func swapWriterState(writer: AVAssetWriter, endpoint: WriterEndpoint)
        -> (swapped: Bool, writer: AVAssetWriter?, endpoint: WriterEndpoint?) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _state == .running else { return (false, nil, nil) }
        let old = (_writer, _writerEndpoint)
        _writer = writer
        _writerEndpoint = endpoint
        _sessionStarted = false
        _sessionStartTime = nil
        _captureID = UUID()
        _awaitingRecoverySample = _awaitingRecoverySample || _appendFailureReported
        // 轮转后的新分片重新允许一次失败上报
        _appendFailureReported = false
        return (true, old.0, old.1)
    }

    /// 创建并启动一个接收音频 CMSampleBuffer 的 AVAssetWriter。
    /// 分片写为 WAV(PCM Int16)：崩溃安全容器（头部在文件开头、数据线性追加），
    /// 异常退出后仅需修补头部 size 字段即可完整恢复（见 FileSyncService），
    /// 最终在停止录音时统一导出为 m4a(AAC)
    private static func createWriter(at url: URL) throws -> (writer: AVAssetWriter, endpoint: WriterEndpoint) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // AVAssetWriter 要求目标文件不能已存在（清理可能的残留文件）
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else {
            throw SystemAudioError.writerSetupFailed
        }

        if #available(macOS 26.0, *) {
            let receiver = writer.inputReceiver(for: input)
            try writer.start()
            let endpoint = WriterEndpoint(
                append: { sampleBuffer in
                    // CMSampleBuffer 由 SCStream 回调独占交给 writer；新 API 用
                    // `sending` 表达所有权转移，显式切断编译器无法推导的回调隔离关系。
                    nonisolated(unsafe) let transferableBuffer = sampleBuffer
                    return try receiver.appendImmediately(
                        CMReadySampleBuffer(unsafeBuffer: transferableBuffer)
                    )
                },
                finish: { receiver.finish() }
            )
            return (writer, endpoint)
        } else {
            return try createLegacyWriter(writer: writer, input: input)
        }
    }

    /// macOS 15–25 兼容路径。旧 WriterInput API 被限制在其有效系统范围内，
    /// 因而使用 macOS 27 SDK 构建时不会产生弃用告警。
    @available(macOS, deprecated: 27.0)
    private static func createLegacyWriter(
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) throws -> (writer: AVAssetWriter, endpoint: WriterEndpoint) {
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw SystemAudioError.writerSetupFailed
        }
        let endpoint = WriterEndpoint(
            append: { sampleBuffer in
                guard input.isReadyForMoreMediaData else { return false }
                guard input.append(sampleBuffer) else {
                    throw WriterAppendError(reason: "AVAssetWriterInput 追加音频样本失败")
                }
                return true
            },
            finish: { input.markAsFinished() }
        )
        return (writer, endpoint)
    }

    /// finalize 一个 writer：标记输入结束并等待容器写完（WAV 完整可播放；
    /// 若进程异常退出未完成，下次启动时修补头部 size 亦可恢复）
    ///
    /// `markAsFinished()` 必须与采样回调在**同一条串行队列**上执行：
    /// 否则轮转/停止时可能与仍在队列中的 `input.append()` 交错，
    /// 向已 markAsFinished 的 input 追加会让整个 writer 进 `.failed`（当前分片全部作废）
    private static func finalizeWriter(
        writer: AVAssetWriter?,
        endpoint: WriterEndpoint?,
        on queue: DispatchQueue
    ) async {
        guard let writer else { return }
        // AVAssetWriter/Input 非 Sendable：仅在这一条串行队列上独占操作
        nonisolated(unsafe) let targetWriter = writer
        let targetEndpoint = endpoint
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                targetEndpoint?.finish()
                targetWriter.finishWriting {
                    continuation.resume()
                }
            }
        }
        if writer.status == .failed {
            staticLogger.error("AVAssetWriter finishWriting 失败: \(writer.error?.localizedDescription ?? "未知错误")")
        }
    }

    /// 停止采集（幂等：无资源时是空操作）
    ///
    /// 清理依据是「资源是否存在」而非状态标志：启动失败与异常断流后资源仍在，
    /// stop() 必须把 writer finalize 掉（否则分片容器不完整、文件句柄泄漏）
    @discardableResult
    func stop() async -> StopResult {
        // 同步辅助方法内持锁取出并清空状态（NSLock 不能在 async 上下文直接使用）
        let detached = detachCaptureState()
        if let stream = detached.stream {
            await Self.stopStream(stream)
        }
        await Self.finalizeWriter(writer: detached.writer, endpoint: detached.writerEndpoint, on: writeQueue)
        // 只在仍处于 stopping 时归位：并发 stop() 交错时不会踩掉随后启动的新会话
        markIdleIfStopping()
        logger.info("系统音频采集已停止")
        return StopResult(
            wasInterrupted: detached.wasInterrupted,
            writerFailed: detached.writer?.status == .failed || detached.writer?.status == .cancelled,
            droppedSamples: detached.droppedSamples
        )
    }

    private static func stopStream(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain,
               nsError.code == SCStreamError.Code.attemptToStopStreamState.rawValue {
                staticLogger.debug("采集流已经停止，无需重复停止")
            } else {
                staticLogger.error("停止系统音频失败 domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            }
        }
    }

    // MARK: - 同步持锁辅助方法（NSLock 在 async 上下文中被禁用，统一包装为同步方法）

    private func lockedState() -> CaptureState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func lockedSetState(_ state: CaptureState) {
        stateLock.lock(); defer { stateLock.unlock() }
        _state = state
    }

    private func reserveStart() -> UUID? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _state == .idle, _stream == nil, _writer == nil else { return nil }
        _captureID = UUID()
        _state = .starting
        return _captureID
    }

    private func isCurrentStart(_ id: UUID) -> Bool {
        stateLock.withLock { _captureID == id && _state == .starting }
    }

    private func releaseStartReservation(matching id: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if _captureID == id, _state == .starting, _stream == nil, _writer == nil { _state = .idle }
    }

    private func markRunningIfCurrent(_ stream: SCStream) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _state == .starting, _stream === stream else { return false }
        _state = .running
        return true
    }

    /// 仅当仍处于 stopping 时归位 idle
    private func markIdleIfStopping() {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .stopping = _state { _state = .idle }
    }

    private func installCaptureState(
        stream: SCStream, writer: AVAssetWriter, endpoint: WriterEndpoint, timeline: RecordingSegmentTimelineStore?,
        startID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _captureID == startID, _state == .starting, _stream == nil, _writer == nil else { return false }
        _stream = stream
        _timeline = timeline
        _captureID = UUID()
        _awaitingRecoverySample = false
        _userStopped = false
        _wakeOriginID = nil
        _writer = writer
        _writerEndpoint = endpoint
        _sessionStarted = false
        _sessionStartTime = nil
        _state = .starting
        // 新 writer：重新允许一次失败上报
        _appendFailureReported = false
        _droppedSampleCount = 0
        _dropReported = false
        return true
    }

    /// 取出并清空采集状态（幂等：无资源时返回空元组）。
    /// 旧实现以 `_isCapturing` 为门槛，启动失败/异常断流后标志已为 false 而资源仍在，
    /// 于是 stop() 直接返回、writer 永不 finalize
    private func detachCaptureState(
        matching expectedStream: SCStream? = nil
    ) -> (stream: SCStream?, writerEndpoint: WriterEndpoint?, writer: AVAssetWriter?, wasInterrupted: Bool, droppedSamples: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let expectedStream, _stream !== expectedStream {
            return (nil, nil, nil, false, 0)
        }
        let result = (_stream, _writerEndpoint, _writer,
                      _state == .failed || _state == .reconnecting,
                      _dropReported ? _droppedSampleCount : 0)
        let hadResources = (result.0 != nil || result.2 != nil)
        _stream = nil
        _captureID = UUID()
        _awaitingRecoverySample = false
        _wakeOriginID = nil
        _writer = nil
        _writerEndpoint = nil
        _sessionStarted = false
        _sessionStartTime = nil
        _droppedSampleCount = 0
        _dropReported = false
        // starting 期间即使还未安装资源，stop 也要取消这次启动预约。
        if hadResources || _state == .starting || _state == .failed { _state = .stopping }
        return result
    }

    private func noteDroppedSample(captureID: UUID) {
        stateLock.lock()
        guard captureID == _captureID else { stateLock.unlock(); return }
        _droppedSampleCount += 1
        let count = _droppedSampleCount
        stateLock.unlock()
        if count == 1 || count % 100 == 0 {
            Self.staticLogger.warning("Writer 背压导致系统音频样本丢弃，当前会话累计 \(count)")
        }
        // 丢样本意味着系统音轨出现缺口：旧实现只写日志，用户无从得知音频不完整。
        // 累计到阈值后上报一次（会话内仅一次），与 append 失败的上报互相独立
        guard count >= Self.droppedSampleReportThreshold else { return }
        stateLock.lock()
        guard captureID == _captureID else { stateLock.unlock(); return }
        let shouldReport = !_dropReported
        if shouldReport { _dropReported = true }
        let callback = _onEvent
        let isCurrent = captureID == _captureID
        stateLock.unlock()
        guard shouldReport, isCurrent else { return }
        callback?(Event(captureID: captureID, kind: .samplesDropped(count)))
    }

    /// append 失败处理：日志去抖（5s）+ 上报去重（会话内仅一次）；返回需上报的错误（无需上报时为 nil）
    private func lockedHandleAppendFailure(_ reason: String, captureID: UUID) -> Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _captureID == captureID else { return nil }
        let now = Date()
        let shouldLog = _lastAppendErrorLoggedAt.map { now.timeIntervalSince($0) >= 5 } ?? true
        if shouldLog {
            _lastAppendErrorLoggedAt = now
            Self.staticLogger.error("系统音频 append 失败: \(reason)")
        }
        guard !_appendFailureReported else { return nil }
        _appendFailureReported = true
        return WriterAppendError(reason: reason)
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        stateLock.lock()
        let isRunning = (_state == .running && _stream === stream)
        let captureID = _captureID
        let endpoint = _writerEndpoint
        let writer = _writer
        let sessionStarted = _sessionStarted
        let startTime = _sessionStartTime
        let timeline = _timeline
        stateLock.unlock()
        guard isRunning else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let endpoint, let writer else { return }
        // writer 已失败时不再逐帧尝试（失败已上报，交由下次轮转建新 writer）
        guard writer.status == .writing else { return }

        // 首包到达时以其 PTS 为会话起点，保证输出文件时间戳从 0 开始
        // （writeQueue 为串行队列，startSession 与 append 顺序有保证）
        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            stateLock.lock()
            if _writer === writer, _captureID == captureID {
                _sessionStarted = true
                _sessionStartTime = pts.seconds
            }
            stateLock.unlock()
        }
        // append 失败必须可见：丢弃返回值时，writer 进 .failed 后后续采样全部静默丢失，
        // 用户只能在停录后才发现系统音轨为空
        do {
            guard try endpoint.append(sampleBuffer) else {
                noteDroppedSample(captureID: captureID)
                return
            }
            stateLock.lock()
            let sessionStart = startTime ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let recovered = _captureID == captureID && _state == .running && _awaitingRecoverySample
            if recovered { _awaitingRecoverySample = false }
            let callback = _onEvent
            stateLock.unlock()
            timeline?.noteWrite(to: writer.outputURL, hostTime: sessionStart,
                                frames: CMSampleBufferGetNumSamples(sampleBuffer))
            if recovered { callback?(Event(captureID: captureID, kind: .recovered)) }
        } catch {
            let nsError = (writer.error ?? error) as NSError
            logger.error("系统音频写入失败 domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            let reason = String(
                format: String(localized: "系统音频写入失败，当前系统音频分片可能丢失。\n%@"),
                writer.error?.localizedDescription ?? error.localizedDescription
            )
            if lockedHandleAppendFailure(reason, captureID: captureID) != nil {
                stateLock.lock()
                let callback = _onEvent
                stateLock.unlock()
                callback?(Event(captureID: captureID, kind: .writerFailed))
            }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        // 已被替换的旧流（唤醒重连后）的迟到错误回调直接忽略，避免误抹新流的采集状态
        guard _stream === stream else {
            stateLock.unlock()
            logger.debug("忽略已停止或替换旧流的回调")
            return
        }
        // 只标状态为 failed，**保留** writer/stream 引用：
        // writer 仍需在 stop() 里 finalize（否则当前分片容器不完整、句柄泄漏），
        // 唤醒重连（resumeAfterWake）也依赖 writer 继续写当前分片
        _state = .failed
        let nsError = error as NSError
        _userStopped = nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userStopped.rawValue
        let callback = _onEvent
        let captureID = _captureID
        stateLock.unlock()
        logger.error("SCStream 停止 domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
        callback?(Event(captureID: captureID, kind: .interrupted(error)))
    }
}
#endif

// MARK: - 错误类型

enum SystemAudioError: LocalizedError {
    case permissionNotGranted
    case noDisplayFound
    case writerSetupFailed
    case notSupported
    case alreadyCapturing
    case startInterrupted

    var errorDescription: String? {
        switch self {
        case .permissionNotGranted:
            return String(localized: "系统音频采集需要「屏幕录制」权限。请到「系统设置 → 隐私与安全性 → 屏幕录制」中授权 Memozia，然后重新开始录音。授权后需重启应用生效。\n如不需要录制系统音频，可在「设置 → 录音」中切换为「仅麦克风」模式。")
                + "\n\n" + ScreenCaptureAuthorization.recoveryAdvice
        case .noDisplayFound:
            return String(localized: "未找到可捕获的显示器")
        case .writerSetupFailed:
            return String(localized: "音频写入器初始化失败")
        case .notSupported:
            return String(localized: "当前平台不支持系统音频采集（仅 macOS）")
        case .alreadyCapturing:
            return String(localized: "系统音频采集已在运行或正在收尾")
        case .startInterrupted:
            return String(localized: "系统音频采集在启动过程中被中断")
        }
    }
}
