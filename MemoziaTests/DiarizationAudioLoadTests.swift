import AVFoundation
import Foundation
import Testing

@testable import Memozia

/// `SpeakerDiarizationService.loadMonoSamples` 的分块读取回归测试。
///
/// 钉住的是让说话人分离与声纹自 9/16 起整体静默失效的那个缺陷：
/// macOS 27 beta (26A428) 上 `AVAudioFile.read(into:)` 读到文件末尾会抛
/// `NSOSStatusErrorDomain` 的 `eofErr(-39)`，而不是像旧系统那样返回 0 帧。
/// 9/15 提交把音频加载从「整文件一次读」改成「分块流式读」（为修长录音 2.7GB 内存问题），
/// 但循环只认「读到 0 帧」作为出口，于是**每一段音频都在全部帧已读出之后**被最后一次
/// EOF 读取判为失败；异常再被 `applySpeakers` 的 catch 吞成一条 warning，
/// 表现就是「转写正常、进度条走完、没有任何说话人标签，也不报错」。
///
/// 本机实测对照（同一份加载器源码，PCM 音频）：
/// - 修复前：48k/2ch、16k/1ch、44.1k 跨多块三种输入全部 `-39` 抛错；
/// - 修复后：三者采样覆盖均为 100%，空音频与缺失文件仍然报错。
struct DiarizationAudioLoadTests {

    // MARK: - 分离模型「首次使用时自动准备」

    /// 模型已就绪时必须零下载直接返回 true。
    ///
    /// 下载路径依赖网络，单测不触发；这里钉住「就绪短路」这一条，
    /// 避免以后把 `ensureModelsReady` 改成无条件重新下载（首次使用时才该下载）。
    @Test func ensureModelsReadyShortCircuitsWhenInstalled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaDiarModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent(SpeakerDiarizationService.segmentationFileName))
        try Data([0]).write(to: dir.appendingPathComponent(SpeakerDiarizationService.embeddingFileName))

        #expect(SpeakerDiarizationService.isModelReady(modelPath: dir.path))
        let ready = try await SpeakerDiarizationService.shared.ensureModelsReady(modelPath: dir.path)
        #expect(ready, "模型已就绪时必须短路返回，不得再走下载")

        // 缺任一文件都不算就绪：两个 onnx 必须同时存在
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(SpeakerDiarizationService.embeddingFileName)
        )
        #expect(!SpeakerDiarizationService.isModelReady(modelPath: dir.path))
    }

    // MARK: - 测试音频

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaDiarization-\(UUID().uuidString)-\(name)")
    }

    /// 写一段正弦波 PCM WAV（float32）。
    /// 缓冲必须按文件自身的 `processingFormat` 构造，否则 `write(from:)` 会以 -50 失败。
    private func writeWAV(
        sampleRate: Double,
        channels: Int,
        seconds: Double
    ) throws -> (url: URL, frames: AVAudioFrameCount) {
        let url = temporaryURL("tone.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: max(frames, 1)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        if frames > 0, let data = buffer.floatChannelData {
            let channelCount = Int(file.processingFormat.channelCount)
            for frame in 0..<Int(frames) {
                let value = Float(sin(2 * .pi * 220 * Double(frame) / sampleRate)) * 0.3
                for channel in 0..<channelCount { data[channel][frame] = value }
            }
            try file.write(from: buffer)
        }
        return (url, frames)
    }

    private func coverage(_ got: Int, _ expected: Double) -> Double {
        expected > 0 ? Double(got) / expected : 0
    }

    // MARK: - 分块读取必须读完整个文件

    /// 48k 立体声 → 16k 单声道：走 `AVAudioConverter` 重采样分支。
    /// 修复前这条必然抛 `-39`，是线上现象的直接复现。
    @Test func testResamplingPathReadsFullDuration() throws {
        let audio = try writeWAV(sampleRate: 48_000, channels: 2, seconds: 3)
        defer { try? FileManager.default.removeItem(at: audio.url) }

        let samples = try SpeakerDiarizationService.loadMonoSamples(
            audioURL: audio.url, sampleRate: 16_000)

        let ratio = coverage(samples.count, Double(audio.frames) / 48_000 * 16_000)
        #expect(ratio > 0.95 && ratio < 1.05, "重采样分支只读到 \(ratio * 100)% 的时长")
    }

    /// 16k 单声道 Float32：源格式即目标格式，走直拷分支——它同样有 EOF 出口问题。
    @Test func testPassthroughPathReadsFullDuration() throws {
        let audio = try writeWAV(sampleRate: 16_000, channels: 1, seconds: 2)
        defer { try? FileManager.default.removeItem(at: audio.url) }

        let samples = try SpeakerDiarizationService.loadMonoSamples(
            audioURL: audio.url, sampleRate: 16_000)

        let ratio = coverage(samples.count, Double(audio.frames))
        #expect(ratio > 0.95 && ratio < 1.05, "直拷分支只读到 \(ratio * 100)% 的时长")
    }

    /// 12 秒 44.1k：跨多个 48000 帧分块，块边界与收尾都不能丢样本
    @Test func testLongAudioSpansMultipleChunksWithoutLosingTail() throws {
        let audio = try writeWAV(sampleRate: 44_100, channels: 1, seconds: 12)
        defer { try? FileManager.default.removeItem(at: audio.url) }

        let samples = try SpeakerDiarizationService.loadMonoSamples(
            audioURL: audio.url, sampleRate: 16_000)

        let ratio = coverage(samples.count, 12.0 * 16_000)
        #expect(ratio > 0.95 && ratio < 1.05, "长音频只读到 \(ratio * 100)% 的时长")
    }

    // MARK: - EOF 兼容不能顺手放过真错误

    /// 无数据的合法 WAV 仍要报错，不能被「EOF 视为读完」伪装成成功
    @Test func testEmptyAudioStillThrows() throws {
        let audio = try writeWAV(sampleRate: 48_000, channels: 1, seconds: 0)
        defer { try? FileManager.default.removeItem(at: audio.url) }

        #expect(throws: (any Error).self) {
            _ = try SpeakerDiarizationService.loadMonoSamples(audioURL: audio.url, sampleRate: 16_000)
        }
    }

    /// 打不开的文件必须抛错，而不是返回空数组被上层当成「读完了」
    @Test func testMissingFileThrowsInsteadOfSilentEmpty() {
        #expect(throws: (any Error).self) {
            _ = try SpeakerDiarizationService.loadMonoSamples(
                audioURL: temporaryURL("missing.wav"), sampleRate: 16_000)
        }
    }
}
