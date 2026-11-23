import Foundation
import AVFoundation
import os.log
#if os(macOS)
import CoreMedia

/// Owns the active Core Audio tap and rolling PCM writer. Mutable session state is locked,
/// and the writer receives owned samples on one serial queue.
final class SystemAudioCaptureService: @unchecked Sendable {
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

        // AVAssetWriter requires one input format throughout a WAV, including after a route
        // change or wake. Convert on writeQueue, keeping the resampler across input packets.
        private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                           channels: 2, interleaved: true)
        private var converter: AVAudioConverter?

        func sample(from input: AVAudioPCMBuffer, at pts: CMTime) throws -> CMSampleBuffer? {
            guard let target else { throw SystemAudioError.invalidFormat }
            let pcm: AVAudioPCMBuffer
            if input.format == target {
                converter = nil
                pcm = input
            } else {
                if converter?.inputFormat != input.format {
                    converter = AVAudioConverter(from: input.format, to: target)
                    converter?.primeMethod = .none
                }
                let capacity = ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 32
                guard let converter, capacity < Double(UInt32.max),
                      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: UInt32(capacity)) else {
                    throw SystemAudioError.invalidFormat
                }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if let error { throw error }
                guard status != .error else { throw SystemAudioError.invalidFormat }
                pcm = output
            }
            guard pcm.frameLength > 0 else { return nil }
            var sample: CMSampleBuffer?
            try SystemAudioTap.check(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
                dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: target.formatDescription, sampleCount: Int(pcm.frameLength),
                presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample))
            guard let sample else { throw SystemAudioError.invalidFormat }
            try SystemAudioTap.check(CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList))
            try SystemAudioTap.check(CMSampleBufferSetDataReady(sample))
            return sample
        }

        func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
            try appendBlock(sampleBuffer)
        }

        func finish() {
            finishBlock()
        }
    }

    private let logger = Logger(subsystem: "app.memozia", category: "SystemAudioCapture")
    private let startTap: @Sendable (SystemAudioTap) async throws -> Void

    init(startTap: @escaping @Sendable (SystemAudioTap) async throws -> Void = { try await $0.start() }) {
        self.startTap = startTap
    }

    /// 静态方法（createWriter/finalizeWriter）使用的日志器
    private static let staticLogger = Logger(subsystem: "app.memozia", category: "SystemAudioCapture")

    /// 状态锁：保护所有跨线程访问的可变状态
    /// 本类是 @unchecked Sendable，内部通过 NSLock 提供实际线程安全
    private let stateLock = NSLock()
    private var _tap: SystemAudioTap?
    private var _writer: AVAssetWriter?
    private var _writerEndpoint: WriterEndpoint?

    private enum CaptureState {
        case idle, starting, running, reconnecting, stopping, failed
    }

    private var _state: CaptureState = .idle

    var hasResourcesPreventingUpdate: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .idle = _state { return _tap != nil || _writer != nil }
        return true
    }
    /// 写入会话是否已开始（首包到达时以其 PTS 为起点，保证时间戳从 0 开始）
    private var _timeline: RecordingSegmentTimelineStore?
    private var _sessionStartTime: TimeInterval?
    private var _sessionStarted = false
    private let writeQueue = DispatchQueue(label: "app.memozia.systemaudio.write")
    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _captureID = UUID()
    private var _awaitingRecoverySample = false
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
        guard event.captureID == _captureID, _tap != nil, let writer = _writer else { return false }
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
        let tap = _tap
        _tap = nil
        _captureID = UUID()
        _wakeOriginID = nil
        _state = .failed
        stateLock.unlock()
        tap?.invalidate()
    }

    /// failed 仍持有待收尾资源；不能用 capturing 判断是否需要恢复。
    var canResumeAfterWake: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _writer != nil && (_state == .failed || _state == .running)
    }

    private func makeTap() -> SystemAudioTap {
        SystemAudioTap(output: .init(queue: writeQueue,
            receive: { [weak self] tap, pcm, pts in self?.receive(pcm, at: pts, from: tap) },
            dropped: { [weak self] tap in self?.noteDroppedSample(from: tap) },
            interrupted: { [weak self] tap, error in self?.interrupted(tap, error: error) }))
    }

    /// Start the actual audio-only input before creating the entry or starting the microphone.
    /// No samples go to a file until the meeting takes ownership of this tap.
    func prepareTap() async throws -> SystemAudioTap {
        let tap = makeTap()
        do {
            try await startTap(tap)
            try Task.checkCancellation()
            return tap
        } catch {
            tap.invalidate()
            throw error
        }
    }

    func start(to url: URL, timeline: RecordingSegmentTimelineStore? = nil,
               preparedTap: SystemAudioTap? = nil) async throws {
        let tap = preparedTap ?? makeTap()
        guard let startID = reserveStart(tap) else { throw SystemAudioError.alreadyCapturing }
        var installed = false
        defer {
            if !installed {
                tap.invalidate()
                releaseStartReservation(matching: startID)
            }
        }
        if preparedTap == nil { try await startTap(tap) }
        try Task.checkCancellation()
        guard isCurrentStart(startID) else { throw SystemAudioError.startInterrupted }
        let (writer, endpoint) = try Self.createWriter(at: url)
        guard installCaptureState(tap: tap, writer: writer, endpoint: endpoint,
                                  timeline: timeline, startID: startID) else {
            await Self.finalizeWriter(writer: writer, endpoint: endpoint, on: writeQueue)
            throw SystemAudioError.startInterrupted
        }
        installed = true
        logger.info("系统音频采集已启动")
    }

    /// Keep the current WAV and its host-clock origin when replacing the input after sleep.
    func resumeAfterWake(expectedCaptureID: UUID) async -> Bool {
        let snapshot = writeQueue.sync { beginWakeRecovery(expectedCaptureID: expectedCaptureID) }
        guard let writer = snapshot.writer else { return false }
        if let old = snapshot.tap { await old.stop() }
        let tap = makeTap()
        guard installReconnectingTap(tap, expectedWriter: writer, originID: expectedCaptureID) else {
            markWakeRecoveryFailed(expectedWriter: writer, originID: expectedCaptureID)
            return false
        }
        do {
            try await startTap(tap)
            guard finishWakeRecovery(tap, expectedWriter: writer, originID: expectedCaptureID) else {
                cancelWakeRecovery(originID: expectedCaptureID)
                tap.invalidate()
                return false
            }
            return true
        } catch {
            cancelWakeRecovery(originID: expectedCaptureID)
            tap.invalidate()
            let failure = error as NSError
            logger.error("唤醒后系统音频重连失败 domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            return false
        }
    }

    /// 唤醒重连前的状态快照：旧流引用 + writer 引用（后者用于重连后校验会话未变）
    private func beginWakeRecovery(expectedCaptureID: UUID) -> (tap: SystemAudioTap?, writer: AVAssetWriter?) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _captureID == expectedCaptureID, !Task.isCancelled,
              let writer = _writer,
              _state == .failed || _state == .running else { return (nil, nil) }
        let oldTap = _tap
        _tap = nil
        _wakeOriginID = expectedCaptureID
        _captureID = UUID() // 旧流及其已排进 MainActor 的事件立即失效。
        _state = .reconnecting
        _awaitingRecoverySample = true
        return (oldTap, writer)
    }

    private func installReconnectingTap(
        _ tap: SystemAudioTap, expectedWriter: AVAssetWriter, originID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !Task.isCancelled, _wakeOriginID == originID,
              _state == .reconnecting, _writer === expectedWriter,
              expectedWriter.status == .writing else { return false }
        _tap = tap
        return true
    }

    private func markWakeRecoveryFailed(expectedWriter: AVAssetWriter, originID: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if _wakeOriginID == originID, _writer === expectedWriter, _state == .reconnecting { _state = .failed }
    }

    /// 重连成功后安装新流并恢复采集状态。
    /// 必须确认 writer、新流和 reconnecting 状态仍归本次恢复持有；
    /// 否则返回 false，调用方需停掉新流。
    private func finishWakeRecovery(
        _ tap: SystemAudioTap, expectedWriter: AVAssetWriter, originID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !Task.isCancelled, _wakeOriginID == originID,
              _writer === expectedWriter, _tap === tap,
              _state == .reconnecting, expectedWriter.status == .writing else {
            return false
        }
        _tap = tap
        _state = .running
        return true
    }

    /// 分片轮转：创建新 writer 接管后续采样，旧 writer 异步 finalize。
    /// finalize 后的分片立即可播放，任何时刻硬崩溃最多丢失当前未关闭的一片。
    /// 新 writer 创建失败时保留旧 writer 继续写入，不丢数据。
    /// - Parameter url: 新分片的目标 URL
    /// - Returns: 是否轮转成功
    func rotateWriter(to url: URL) async -> Bool {
        guard let generation = stateLock.withLock({ _state == .running ? _captureID : nil }) else { return false }
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
        let old = writeQueue.sync {
            swapWriterState(writer: newPair.writer, endpoint: newPair.endpoint, generation: generation)
        }
        guard old.swapped else {
            await Self.finalizeWriter(writer: newPair.writer, endpoint: newPair.endpoint, on: writeQueue)
            return false
        }

        // 3. finalize 旧 writer（markAsFinished + finishWriting 后 WAV 容器完整，分片可播放）
        await Self.finalizeWriter(writer: old.writer, endpoint: old.endpoint, on: writeQueue)
        logger.info("系统音频分片轮转完成: \(url.lastPathComponent)")
        return true
    }

    /// 持锁原子替换 writer/endpoint；未在采集时不替换（返回 swapped=false）
    private func swapWriterState(writer: AVAssetWriter, endpoint: WriterEndpoint, generation: UUID)
        -> (swapped: Bool, writer: AVAssetWriter?, endpoint: WriterEndpoint?) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _state == .running, _captureID == generation else { return (false, nil, nil) }
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
                    // CMSampleBuffer 已复制到独立存储，由写队列独占交给 writer；新 API 用
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
                    throw WriterAppendError(reason: String(localized: "AVAssetWriterInput 追加音频样本失败"))
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
        // Process copies already handed off by HAL before closing the current segment.
        let detached = writeQueue.sync { detachCaptureState() }
        if let tap = detached.tap {
            if detached.writer == nil { tap.invalidate() } else { await tap.stop() }
        }
        await Self.finalizeWriter(writer: detached.writer, endpoint: detached.writerEndpoint, on: writeQueue)
        // 只在仍处于 stopping 时归位：并发 stop() 交错时不会踩掉随后启动的新会话
        if detached.tap != nil || detached.writer != nil { markIdleIfStopping() }
        logger.info("系统音频采集已停止")
        return StopResult(
            wasInterrupted: detached.wasInterrupted,
            writerFailed: detached.writer?.status == .failed || detached.writer?.status == .cancelled,
            droppedSamples: detached.droppedSamples
        )
    }

    private func reserveStart(_ tap: SystemAudioTap) -> UUID? {
        stateLock.withLock {
            guard _state == .idle, _tap == nil, _writer == nil else { return nil }
            _captureID = UUID()
            _tap = tap
            _state = .starting
            return _captureID
        }
    }

    private func isCurrentStart(_ id: UUID) -> Bool {
        stateLock.withLock { _captureID == id && _state == .starting }
    }

    private func releaseStartReservation(matching id: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        if _captureID == id, _state == .starting, _writer == nil {
            _tap = nil
            _state = .idle
        }
    }

    /// 仅当仍处于 stopping 时归位 idle
    private func markIdleIfStopping() {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .stopping = _state { _state = .idle }
    }

    private func installCaptureState(
        tap: SystemAudioTap, writer: AVAssetWriter, endpoint: WriterEndpoint, timeline: RecordingSegmentTimelineStore?,
        startID: UUID
    ) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _captureID == startID, _state == .starting, _tap === tap, _writer == nil else { return false }
        _timeline = timeline
        _captureID = UUID()
        _awaitingRecoverySample = false
        _wakeOriginID = nil
        _writer = writer
        _writerEndpoint = endpoint
        _sessionStarted = false
        _sessionStartTime = nil
        _state = .running
        // 新 writer：重新允许一次失败上报
        _appendFailureReported = false
        _droppedSampleCount = 0
        _dropReported = false
        return true
    }

    /// 取出并清空采集状态（幂等：无资源时返回空元组）。
    /// 旧实现以 `_isCapturing` 为门槛，启动失败/异常断流后标志已为 false 而资源仍在，
    /// 于是 stop() 直接返回、writer 永不 finalize
    private func detachCaptureState()
        -> (tap: SystemAudioTap?, writerEndpoint: WriterEndpoint?, writer: AVAssetWriter?, wasInterrupted: Bool, droppedSamples: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        let result = (_tap, _writerEndpoint, _writer,
                      _state == .failed || _state == .reconnecting,
                      _dropReported ? _droppedSampleCount : 0)
        let hadResources = (result.0 != nil || result.2 != nil)
        _tap = nil
        _captureID = UUID()
        _awaitingRecoverySample = false
        _wakeOriginID = nil
        _writer = nil
        _writerEndpoint = nil
        _sessionStarted = false
        _sessionStartTime = nil
        _droppedSampleCount = 0
        _dropReported = false
        if hadResources { _state = .stopping }
        return result
    }

    private func noteDroppedSample(from tap: SystemAudioTap) {
        let id = stateLock.withLock { _tap === tap && _state == .running ? _captureID : nil }
        if let id { noteDroppedSample(captureID: id) }
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

    private func receive(_ pcm: AVAudioPCMBuffer, at pts: CMTime, from tap: SystemAudioTap) {
        stateLock.lock()
        if _tap === tap, _state == .failed, _writer != nil {
            // A route interruption can clear before a wake notification. Confirm on a real write.
            _state = .running
            _awaitingRecoverySample = true
        }
        let isRunning = _state == .running && _tap === tap
        let captureID = _captureID
        let endpoint = _writerEndpoint
        let writer = _writer
        let sessionStarted = _sessionStarted
        let startTime = _sessionStartTime
        let timeline = _timeline
        stateLock.unlock()
        guard isRunning else { return }
        guard let endpoint, let writer else { return }
        // writer 已失败时不再逐帧尝试（失败已上报，交由下次轮转建新 writer）
        guard writer.status == .writing else { return }

        do {
            guard let sampleBuffer = try endpoint.sample(from: pcm, at: pts) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                stateLock.withLock {
                    if _writer === writer, _captureID == captureID {
                        _sessionStarted = true
                        _sessionStartTime = pts.seconds
                    }
                }
            }
            guard try endpoint.append(sampleBuffer) else {
                noteDroppedSample(captureID: captureID)
                return
            }
            stateLock.lock()
            let sessionStart = startTime ?? pts.seconds
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

    private func interrupted(_ tap: SystemAudioTap, error: any Error) {
        stateLock.lock()
        guard _tap === tap, _state == .running else { stateLock.unlock(); return }
        _state = .failed
        let callback = _onEvent
        let id = _captureID
        stateLock.unlock()
        let failure = error as NSError
        logger.error("系统音频中断 domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        callback?(Event(captureID: id, kind: .interrupted(error)))
    }
}

enum SystemAudioError: LocalizedError {
    case permissionNotGranted, startTimedOut, deviceUnavailable, invalidFormat
    case writerSetupFailed, alreadyCapturing, startInterrupted

    var errorDescription: String? {
        switch self {
        case .permissionNotGranted:
            return String(localized: "请在「系统设置 → 隐私与安全性 → 录屏与系统录音」中允许 Memozia 仅录制系统音频，然后重新开始录音。")
        case .startTimedOut:
            return String(localized: "未能及时收到系统音频。请检查系统录音权限和声音输出设备，然后重试。")
        case .deviceUnavailable:
            return String(localized: "系统音频设备不可用")
        case .invalidFormat:
            return String(localized: "无法读取系统音频格式")
        case .writerSetupFailed:
            return String(localized: "音频写入器初始化失败")
        case .alreadyCapturing:
            return String(localized: "系统音频采集已在运行或正在收尾")
        case .startInterrupted:
            return String(localized: "系统音频采集在启动过程中被中断")
        }
    }
}
#endif
