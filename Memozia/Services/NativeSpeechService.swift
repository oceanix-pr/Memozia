import AVFoundation
import Foundation
import os

/// AVSpeechSynthesizer 的回调可能来自任意线程。
/// 这个包装是唯一的音频写入入口：文件、块令牌和关闭状态全部由同一把锁保护；
/// AVAudioBuffer 只在回调期间同步使用，不跨 actor、不逃逸。取消先关闭入口，迟到回调直接忽略。
final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var chunkID: UUID?
    private var chunkFrames: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var closed = false

    init(url: URL) { self.url = url }

    func beginChunk(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        chunkID = id
        chunkFrames = 0
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    func isStalled(for id: UUID, after seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && chunkID == id && ProcessInfo.processInfo.systemUptime - lastActivity > seconds
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        chunkID = nil
        file = nil // 关闭 WAV 并完成容器头；与所有写入互斥。
    }

    var frameCount: AVAudioFramePosition {
        lock.lock(); defer { lock.unlock() }
        return totalFrames
    }

    /// 返回 nil 表示尚在写入/已被取消；非 nil 表示该块已结束（成功或错误）。
    private func append(_ buffer: AVAudioBuffer, for id: UUID) -> Result<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, chunkID == id else { return nil }
        lastActivity = ProcessInfo.processInfo.systemUptime
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            chunkID = nil
            return .failure(SpeechSynthesisError.incompatibleAudio)
        }
        if pcm.frameLength == 0 {
            chunkID = nil
            return chunkFrames > 0 ? .success(()) : .failure(SpeechSynthesisError.noAudio)
        }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat,
                                       interleaved: pcm.format.isInterleaved)
            }
            guard let file, file.processingFormat == pcm.format else {
                throw SpeechSynthesisError.incompatibleAudio
            }
            try file.write(from: pcm)
            chunkFrames += AVAudioFramePosition(pcm.frameLength)
            totalFrames += AVAudioFramePosition(pcm.frameLength)
            return nil
        } catch {
            chunkID = nil
            return .failure(error)
        }
    }

    // 在非隔离上下文创建闭包，不能让音频回调继承调用方 MainActor。
    func callback(for id: UUID, onEnd: @escaping @Sendable (Result<Void, Error>) -> Void)
        -> @Sendable (AVAudioBuffer) -> Void {
        { [self] buffer in
            if let result = append(buffer, for: id) { onEnd(result) }
        }
    }
}

struct SpeechAudioArtifact: Sendable {
    let directory: URL
    let audioURL: URL
    let format: SpeechAudioFormat

    func remove() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Logger(subsystem: "app.memozia", category: "SpeechSynthesis")
                .error("清理语音临时文件失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 每个面板独占一个实例。原生引擎与 continuation 只在主 actor 操作。
/// 只有文件 sink 进入系统回调；看门狗/取消会立即恢复 continuation，不等待迟到回调。
@MainActor
final class NativeSpeechService {
    private var synthesizer: AVSpeechSynthesizer?
    private var activeChunk: UUID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var sink: SpeechAudioSink?
    private var running = false

    func synthesize(text: String, voiceID: String, rate: Float, format: SpeechAudioFormat,
                    onProgress: @escaping @MainActor (Double) -> Void) async throws -> SpeechAudioArtifact {
        guard !running else { throw SpeechSynthesisError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechSynthesisError.emptyText
        }
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else {
            throw SpeechSynthesisError.voiceUnavailable
        }
        if format == .mp3 && !SpeechAudioFormat.supportsMP3Encoding {
            throw SpeechSynthesisError.mp3Unavailable
        }
        try Task.checkCancellation()
        running = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Memozia-Speech-\(UUID().uuidString)", isDirectory: true)
        var succeeded = false
        defer {
            sink?.close()
            sink = nil
            synthesizer?.stopSpeaking(at: .immediate)
            synthesizer = nil
            watchdog?.cancel()
            watchdog = nil
            running = false
            if !succeeded {
                SpeechAudioArtifact(directory: directory, audioURL: directory, format: format).remove()
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let wavURL = directory.appendingPathComponent("speech.wav")
        let audioSink = SpeechAudioSink(url: wavURL)
        sink = audioSink
        synthesizer = AVSpeechSynthesizer()
        let chunks = SpeechTextPreparer.chunks(text)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
            try await write(utterance, to: audioSink)
            onProgress(Double(index + 1) / Double(chunks.count))
        }
        audioSink.close()
        guard audioSink.frameCount > 0 else { throw SpeechSynthesisError.noAudio }
        try Task.checkCancellation()
        let outputURL = try await SpeechAudioEncoder().encode(wavURL: wavURL, format: format)
        try Task.checkCancellation()
        succeeded = true
        return SpeechAudioArtifact(directory: directory, audioURL: outputURL, format: format)
    }

    private func write(_ utterance: AVSpeechUtterance, to sink: SpeechAudioSink) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                activeChunk = id
                continuation = pending
                sink.beginChunk(id)
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, self.activeChunk == id else { return }
                        if sink.isStalled(for: id, after: 30) {
                            sink.close()
                            self.complete(id, result: .failure(SpeechSynthesisError.timedOut))
                            self.synthesizer?.stopSpeaking(at: .immediate)
                            return
                        }
                    }
                }
                synthesizer?.write(utterance, toBufferCallback: sink.callback(for: id) { [weak self] result in
                    Task { @MainActor in self?.complete(id, result: result) }
                })
            }
        } onCancel: { [weak self] in
            // 先在取消线程封住写入；主 actor 随后停引擎并恢复等待方。
            sink.close()
            Task { @MainActor in
                guard let self, self.activeChunk == id else { return }
                self.complete(id, result: .failure(CancellationError()))
                self.synthesizer?.stopSpeaking(at: .immediate)
            }
        }
    }

    private func complete(_ id: UUID, result: Result<Void, Error>) {
        guard activeChunk == id, let continuation else { return }
        self.continuation = nil
        activeChunk = nil
        watchdog?.cancel()
        watchdog = nil
        continuation.resume(with: result)
    }
}

/// 同一任务的非主线程编码。仅流式读写小块 PCM，不把长篇音频加载进内存。
actor SpeechAudioEncoder {
    func encode(wavURL: URL, format: SpeechAudioFormat) async throws -> URL {
        try Task.checkCancellation()
        if format == .wav { return wavURL }
        if format == .mp3 && !SpeechAudioFormat.supportsMP3Encoding {
            throw SpeechSynthesisError.mp3Unavailable
        }
        let input = try AVAudioFile(forReading: wavURL)
        let pcmFormat = input.processingFormat
        let outputURL = wavURL.deletingPathExtension().appendingPathExtension(format.rawValue)
        var output: AVAudioFile? = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: format == .m4a ? kAudioFormatMPEG4AAC : kAudioFormatMPEGLayer3,
            AVSampleRateKey: pcmFormat.sampleRate,
            AVNumberOfChannelsKey: pcmFormat.channelCount
            // 让系统选择与音色采样率匹配的码率；例如 22.05 kHz 单声道
            // 不支持固定 96 kbps，强设会使原生 AAC 编码失败。
        ], commonFormat: pcmFormat.commonFormat, interleaved: pcmFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 32_768) else {
            throw SpeechSynthesisError.incompatibleAudio
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw SpeechSynthesisError.noAudio }
            try output?.write(from: buffer)
            await Task.yield()
        }
        output = nil // 先完成 AAC/MP3 容器，再交付可播放文件。
        let validation = try AVAudioFile(forReading: outputURL)
        guard validation.length > 0 else { throw SpeechSynthesisError.noAudio }
        return outputURL
    }
}
