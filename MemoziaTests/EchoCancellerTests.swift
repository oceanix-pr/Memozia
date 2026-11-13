import AVFoundation
import Foundation
import Testing

@testable import Memozia

/// 离线参考回声消除的确定性单测。
///
/// 用合成信号覆盖三件事：延迟估计能否找回参考领先量、单讲时回声能否被压下去、
/// 双讲时本地语音能否被保住。全部信号由固定种子的伪随机噪声生成，输入相同即输出相同，
/// 便于在无真实录音的环境下钉住行为。
struct EchoCancellerTests {

    // MARK: - 测试信号

    /// 确定性白噪（线性同余），避免每次运行结果不同导致阈值判定抖动。
    private struct Noise {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
            return (unit - 0.5) * 2
        }

        mutating func samples(_ count: Int, amplitude: Float) -> [Float] {
            (0..<count).map { _ in next() * amplitude }
        }
    }

    private let sampleRate: Double = 16_000

    private func meanEnergy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sum / Float(samples.count)
    }

    /// 回声返回损耗增强（dB）：麦克风能量 / 处理后能量。
    private func erle(mic: [Float], output: [Float]) -> Float {
        let tail = mic.count / 2
        let input = meanEnergy(mic[tail...])
        let residual = meanEnergy(output[tail...])
        guard input.isFinite, input > 0, residual.isFinite, residual > 0 else { return -.infinity }
        return 10 * log10(input / residual)
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var energyA: Float = 0
        var energyB: Float = 0
        for i in 0..<count {
            dot += a[i] * b[i]
            energyA += a[i] * a[i]
            energyB += b[i] * b[i]
        }
        guard energyA > 0, energyB > 0 else { return 0 }
        return dot / (energyA * energyB).squareRoot()
    }

    // MARK: - 延迟估计

    @Test("延迟估计能找回参考领先的样本数")
    func testEstimateDelay() throws {
        var noise = Noise(seed: 7)
        let count = Int(4 * sampleRate)
        let reference = noise.samples(count, amplitude: 0.3)
        let delay = 128

        // mic[n] = 0.5 * reference[n - delay] + 越小的自身噪声
        var mic = [Float](repeating: 0, count: count)
        for n in delay..<count {
            mic[n] = 0.5 * reference[n - delay]
        }
        let measurementNoise = noise.samples(count, amplitude: 1e-4)
        for n in 0..<count { mic[n] += measurementNoise[n] }

        let estimated = try #require(
            EchoCanceller.estimateDelay(mic: mic, reference: reference, sampleRate: sampleRate)
        )
        #expect(abs(estimated - delay) <= 2)
    }

    @Test("无相关信号时延迟估计返回 nil，不会给出行外结果")
    func testEstimateDelayRejectsSilenceAndMismatch() {
        // 全静音：没有可用的相关性
        #expect(
            EchoCanceller.estimateDelay(
                mic: [Float](repeating: 0, count: 16_000),
                reference: [Float](repeating: 0, count: 16_000),
                sampleRate: sampleRate
            ) == nil
        )
        // 两段互不相关的噪声：相关性低于阈值
        var noise = Noise(seed: 11)
        let mic = noise.samples(16_000, amplitude: 0.3)
        let reference = noise.samples(16_000, amplitude: 0.3)
        #expect(
            EchoCanceller.estimateDelay(mic: mic, reference: reference, sampleRate: sampleRate) == nil
        )
        // 过短与空输入
        #expect(EchoCanceller.estimateDelay(mic: [], reference: [], sampleRate: sampleRate) == nil)
        #expect(
            EchoCanceller.estimateDelay(mic: [1, 2, 3], reference: [1, 2, 3], sampleRate: sampleRate) == nil
        )
    }

    @Test("参考对齐：正延迟头部补零、负延迟丢弃开头")
    func testAlignReference() {
        let reference: [Float] = [1, 2, 3]
        #expect(EchoCanceller.alignReference(reference, delay: 0) == [1, 2, 3])
        #expect(EchoCanceller.alignReference(reference, delay: 2) == [0, 0, 1, 2, 3])
        #expect(EchoCanceller.alignReference(reference, delay: -2) == [3])
        // 负延迟超过参考长度时不会越界
        #expect(EchoCanceller.alignReference(reference, delay: -10).isEmpty)
    }

    // MARK: - 回声消除

    @Test("单讲时回声被显著抑制")
    func testSingleTalkSuppressesEcho() {
        var noise = Noise(seed: 23)
        let count = Int(4 * sampleRate)
        let reference = noise.samples(count, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }

        let output = EchoCanceller.cancel(mic: mic, reference: reference, delay: 0)
        #expect(output.count == mic.count)
        #expect(erle(mic: mic, output: output) > 15, "ERLE \(erle(mic: mic, output: output)) dB")
    }

    @Test("双讲时冻结权重更新，本地语音被保留")
    func testDoubleTalkPreservesLocalSpeech() {
        var noise = Noise(seed: 31)
        let oneSecond = Int(sampleRate)
        // 第一段：只有回声，让滤波器先收敛到 0.6 的增益
        let echoOnlyReference = noise.samples(oneSecond, amplitude: 0.3)
        // 第二段：回声 + 远大于回声的本地语音
        let doubleTalkReference = noise.samples(2 * oneSecond, amplitude: 0.3)
        let localSpeech = noise.samples(2 * oneSecond, amplitude: 1.2)

        let reference = echoOnlyReference + doubleTalkReference
        var mic = reference.map { $0 * 0.6 }
        for i in 0..<localSpeech.count { mic[oneSecond + i] += localSpeech[i] }

        let output = EchoCanceller.cancel(mic: mic, reference: reference, delay: 0)

        let tail = Array(output[oneSecond...])
        // 本地语音是主成分：处理后仍与它高度相关，且能量没有被削掉
        let speechCorrelation = correlation(tail, localSpeech)
        let tailEnergy = meanEnergy(tail[...])
        let speechEnergy = meanEnergy(localSpeech[...])
        #expect(speechCorrelation > 0.8, "与本地语音相关性 \(speechCorrelation)")
        #expect(tailEnergy > 0.6 * speechEnergy, "输出能量 \(tailEnergy) 本地语音能量 \(speechEnergy)")
    }

    @Test("全静音输入输出保持静音")
    func testSilenceStaysSilent() {
        var noise = Noise(seed: 41)
        let reference = noise.samples(32_000, amplitude: 0.3)
        let mic = [Float](repeating: 0, count: 32_000)

        let output = EchoCanceller.cancel(mic: mic, reference: reference, delay: 0)
        #expect(output.count == mic.count)
        let peak = output.map { abs($0) }.max() ?? 0
        #expect(peak < 1e-6, "静音输入产生了 \(peak) 的输出")
    }

    @Test("空输入不崩溃且原样返回")
    func testEmptyInput() {
        #expect(EchoCanceller.cancel(mic: [], reference: [], delay: 0).isEmpty)
        #expect(EchoCanceller.cancel(mic: [], reference: [1, 2, 3], delay: 0).isEmpty)
    }

    @Test("极短于一个分块的输入也能按原长度输出")
    func testShortInputKeepsLength() {
        var noise = Noise(seed: 53)
        let reference = noise.samples(100, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }
        let output = EchoCanceller.cancel(mic: mic, reference: reference, delay: 0)
        #expect(output.count == mic.count)
    }

    // MARK: - 偏好开关

    @Test("回声消除偏好默认开启且可关闭")
    func testPreferenceDefaultsToEnabled() {
        let suiteName = "app.memozia.echo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(EchoReductionPreference.isEnabled(in: defaults))
        EchoReductionPreference.set(false, in: defaults)
        #expect(!EchoReductionPreference.isEnabled(in: defaults))
        EchoReductionPreference.set(true, in: defaults)
        #expect(EchoReductionPreference.isEnabled(in: defaults))
    }

    // MARK: - IO 编排

    @Test("双轨分片逐片清理：帧数一致且回声下降")
    func testReductionServiceCleansPairedSegments() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-reduction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rate: Double = 48_000
        let frameCount = Int(rate)
        var noise = Noise(seed: 67)
        let reference = noise.samples(frameCount, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }

        let micURL = folder.appendingPathComponent("20260101000000_mic_tmp_0001.caf")
        let sysURL = folder.appendingPathComponent("20260101000000_sys_tmp_0001.wav")
        try writeMicrophoneSegment(mic, sampleRate: rate, to: micURL)
        try writeSystemSegment(reference, sampleRate: rate, to: sysURL)

        let reduced = await EchoReductionService.reduceEcho(micURLs: [micURL], sysURLs: [sysURL])
        let result = try #require(reduced)
        #expect(result.createdURLs.count == 1)
        #expect(result.micURLs.count == 1)

        let cleanURL = try #require(result.createdURLs.first)
        #expect(cleanURL != micURL)
        // 原始分片保持不动（合并成功后由调用方一并清理）
        #expect(FileManager.default.fileExists(atPath: micURL.path))

        let cleaned = try readSamples(cleanURL)
        #expect(cleaned.count == mic.count)
        let input = try readSamples(micURL)
        let reduction = erle(mic: input, output: cleaned)
        #expect(reduction > 3, "回声抑制 \(reduction) dB")
    }

    @Test("缺少配对参考时不处理，返回 nil 由调用方沿用原片")
    func testReductionServiceRequiresBothTracks() async {
        let micURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("20260101000000_mic_tmp_0001.caf")
        #expect(await EchoReductionService.reduceEcho(micURLs: [micURL], sysURLs: []) == nil)
        #expect(await EchoReductionService.reduceEcho(micURLs: [], sysURLs: [micURL]) == nil)
    }

    @Test("取消标记置位后不处理，返回 nil 且不生成清理分片")
    func testReductionServiceSkipsWhenCancelled() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rate: Double = 48_000
        let frameCount = Int(rate / 5)
        var noise = Noise(seed: 21)
        let reference = noise.samples(frameCount, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }

        let micURL = folder.appendingPathComponent("20260101000000_mic_tmp_0001.caf")
        let sysURL = folder.appendingPathComponent("20260101000000_sys_tmp_0001.wav")
        try writeMicrophoneSegment(mic, sampleRate: rate, to: micURL)
        try writeSystemSegment(reference, sampleRate: rate, to: sysURL)

        let reduced = await EchoReductionService.reduceEcho(
            micURLs: [micURL],
            sysURLs: [sysURL],
            isCancelled: { true }
        )
        #expect(reduced == nil)
        let cleanURL = folder.appendingPathComponent("20260101000000_mic_clean_0001.caf")
        #expect(!FileManager.default.fileExists(atPath: cleanURL.path))
    }

    @Test("超出截止时间后不处理，返回 nil 由调用方沿用原片")
    func testReductionServiceSkipsWhenDeadlinePassed() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rate: Double = 48_000
        let frameCount = Int(rate / 5)
        var noise = Noise(seed: 22)
        let reference = noise.samples(frameCount, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }

        let micURL = folder.appendingPathComponent("20260101000000_mic_tmp_0001.caf")
        let sysURL = folder.appendingPathComponent("20260101000000_sys_tmp_0001.wav")
        try writeMicrophoneSegment(mic, sampleRate: rate, to: micURL)
        try writeSystemSegment(reference, sampleRate: rate, to: sysURL)

        let reduced = await EchoReductionService.reduceEcho(
            micURLs: [micURL],
            sysURLs: [sysURL],
            deadline: Date().addingTimeInterval(-1)
        )
        #expect(reduced == nil)
    }

    @Test("进度回调按已处理片数递增，总数恒为配对片数")
    func testReductionServiceReportsProgress() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rate: Double = 48_000
        let frameCount = Int(rate / 5)
        var noise = Noise(seed: 23)
        let reference = noise.samples(frameCount, amplitude: 0.3)
        let mic = reference.map { $0 * 0.6 }

        var micURLs: [URL] = []
        var sysURLs: [URL] = []
        for index in 1...2 {
            let micURL = folder.appendingPathComponent(
                String(format: "20260101000000_mic_tmp_%04d.caf", index)
            )
            let sysURL = folder.appendingPathComponent(
                String(format: "20260101000000_sys_tmp_%04d.wav", index)
            )
            try writeMicrophoneSegment(mic, sampleRate: rate, to: micURL)
            try writeSystemSegment(reference, sampleRate: rate, to: sysURL)
            micURLs.append(micURL)
            sysURLs.append(sysURL)
        }

        let recorder = ProgressRecorder()
        let reduced = await EchoReductionService.reduceEcho(
            micURLs: micURLs,
            sysURLs: sysURLs,
            onProgress: { done, total in recorder.record(done, total) }
        )
        #expect(reduced != nil)
        let events = recorder.events
        #expect(events.map(\.0) == [1, 2])
        #expect(events.allSatisfy { $0.1 == 2 })
    }

    /// 线程安全的进度记录器：`onProgress` 是 @Sendable，可能在协作线程池回调
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(Int, Int)] = []

        func record(_ done: Int, _ total: Int) {
            lock.lock()
            storage.append((done, total))
            lock.unlock()
        }

        var events: [(Int, Int)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - 文件读写辅助（与采集端规格一致）

    private func writeMicrophoneSegment(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// 系统音频分片：48kHz 立体声（两声道内容相同，下混后等于单声道参考）
    private func writeSystemSegment(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channelIndex in 0..<Int(file.processingFormat.channelCount) {
            let channel = try #require(buffer.floatChannelData?[channelIndex])
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}