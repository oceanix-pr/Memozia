import AVFoundation
import Foundation
import os.log

/// 离线参考回声消除的 IO 编排。
///
/// 把「麦克风分片 + 系统音频分片」逐片配对处理：**以系统音频为参考**，消除麦克风轨里
/// 泄漏进来的远端声音（本地扬声器外放被麦克风采回），输出与输入同边界、同采样率的
/// 清理后麦克风分片，交给原有合并流程，下游零改动。
///
/// 设计约束：
/// - 不处理「自己声音绕网络回来」那条路径（远端编码与网络抖动无法用线性滤波建模），
///   那条路径由双轨分离转写去重解决。
/// - 配对失败/处理失败一律回退为原始分片，绝不阻断录音入库或丢音频。
/// - 逐片处理（不把整段录音读进内存）；片内不做时钟漂移补偿，5 分钟片内的漂移量
///   （典型 50ppm → 15ms）远小于滤波器尾长，不需要额外补偿。
///
/// 线程：全部是非隔离的静态入口，重活跑在协作线程池上，不会占用主线程。
enum EchoReductionService {

    private static let logger = Logger(subsystem: "app.memozia", category: "EchoReduction")

    /// 处理结果。
    struct Result: Sendable {
        /// 供后续合并使用的麦克风分片：已处理的替换为清理分片，未处理的保持原样
        let micURLs: [URL]
        /// 新建的清理分片，合并成功后需要一并清理（合并失败时保留供手动处理）
        let createdURLs: [URL]
    }

    /// 对麦克风分片逐片做回声消除。
    ///
    /// 可观察、可中断：逐片处理，每片前检查取消与截止时间，片内每块也检查取消；
    /// 被中断的尾部（含数量分叉的尾部）一律沿用原始麦克风分片，保证音频完整、
    /// 且不阻断后续合并入库。
    ///
    /// - Parameters:
    ///   - deadline: 时间预算上限；到点后停止处理剩余分片并回退原始音轨（nil 表示不设限）
    ///   - isCancelled: 跨隔离取消标记的查询闭包；返回 true 时停止处理剩余分片
    ///   - onProgress: 每处理完一片回调 (已完成数, 总数)
    /// - Returns: 处理结果；无可处理条件（缺任一轨、全部失败）时返回 nil，
    ///   调用方按原始分片继续走合并流程。
    static func reduceEcho(
        micURLs: [URL],
        sysURLs: [URL],
        config: EchoCancellerConfig = EchoCancellerConfig(),
        maxDelaySeconds: Double = 1.5,
        deadline: Date? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Result? {
        guard !micURLs.isEmpty, !sysURLs.isEmpty else { return nil }

        let pairCount = min(micURLs.count, sysURLs.count)
        if micURLs.count != sysURLs.count {
            // 两条轨各自独立轮转，轮转失败会让数量分叉；无法配对的尾部没有参考信号，
            // 只能原样保留（保持音频完整，只是那一片不消除）
            logger.warning("双轨分片数量不一致（mic=\(micURLs.count) sys=\(sysURLs.count)），仅处理配对的前 \(pairCount) 片")
        }

        var micResult: [URL] = []
        var created: [URL] = []
        var processed = 0
        var aborted = false

        for index in 0..<pairCount {
            if isCancelled() {
                aborted = true
                logger.warning("回声消除被取消，剩余 \(pairCount - index) 片回退原始音轨")
                break
            }
            if let deadline, Date() >= deadline {
                aborted = true
                logger.warning("回声消除超出时间预算，剩余 \(pairCount - index) 片回退原始音轨")
                break
            }
            let micURL = micURLs[index]
            let outputURL = cleanedURL(for: micURL)
            if let cleanURL = await reducePair(
                micURL: micURL,
                sysURL: sysURLs[index],
                outputURL: outputURL,
                config: config,
                maxDelaySeconds: maxDelaySeconds,
                isCancelled: isCancelled
            ) {
                micResult.append(cleanURL)
                created.append(cleanURL)
            } else {
                logger.warning("第 \(index + 1) 片回声消除未完成，沿用原始麦克风分片")
                micResult.append(micURL)
            }
            processed = index + 1
            onProgress?(processed, pairCount)
        }

        // 未处理（含被取消/超时中断）的尾部一律沿用原始麦克风分片，保证音频完整。
        // `micResult` 此刻恰好持有已处理的前 processed 片（成功=清理片，失败=原始片）
        if processed < micURLs.count {
            micResult.append(contentsOf: micURLs[processed...])
        }

        guard !created.isEmpty else { return nil }
        if aborted {
            logger.info("回声消除中断：已完成 \(created.count)/\(pairCount) 片，其余沿用原始音轨")
        } else {
            logger.info("回声消除完成：\(created.count)/\(pairCount) 片已清理")
        }
        return Result(micURLs: micResult, createdURLs: created)
    }

    // MARK: - 单分片处理

    /// 处理一对分片。
    /// - Parameter isCancelled: 取消标记查询；返回 true 时放弃本片（清理半成品后返回 nil）
    /// - Returns: 清理后的分片 URL；失败返回 nil（调用方沿用原始分片）。
    private static func reducePair(
        micURL: URL,
        sysURL: URL,
        outputURL: URL,
        config: EchoCancellerConfig,
        maxDelaySeconds: Double,
        isCancelled: @Sendable () -> Bool
    ) async -> URL? {
        let startedAt = Date()
        guard !isCancelled() else { return nil }

        // 采样率以麦克风分片为准（系统音频固定 48kHz，由读取端重采样对齐），
        // 输出直接用麦克风原始采样率，避免处理后还要再转一次
        guard let micProbeFile = try? AVAudioFile(forReading: micURL) else {
            logger.error("麦克风分片无法打开: \(micURL.lastPathComponent)")
            return nil
        }
        let sampleRate = micProbeFile.processingFormat.sampleRate
        guard sampleRate > 0, micProbeFile.length > 0 else {
            logger.error("麦克风分片为空或采样率无效: \(micURL.lastPathComponent)")
            return nil
        }

        // 阶段一：延迟估计。延迟里混着两路启动时间差、扬声器到麦克风的声学延迟与
        // 会议软件的播放缓冲，必须实测。用独立的只读前缀，避免污染流式读取的游标。
        let delay: Int
        do {
            guard let micProbe = SegmentReader(url: micURL),
                  let sysProbe = SystemAudioMonoReader(url: sysURL, targetSampleRate: sampleRate) else {
                logger.error("无法建立延迟探测读取器: mic=\(micURL.lastPathComponent) sys=\(sysURL.lastPathComponent)")
                return nil
            }
            // 参考侧多读一段，供「参考滞后于麦克风」的负延迟搜索
            let micPrefix = micProbe.read(min(Int(micProbeFile.length), Int(8.0 * sampleRate)))
            let sysPrefix = sysProbe.read(Int((8.0 + maxDelaySeconds + 2.0) * sampleRate))
            guard !micPrefix.isEmpty, !sysPrefix.isEmpty else {
                logger.error("延迟探测读不到样本: mic=\(micPrefix.count) sys=\(sysPrefix.count)")
                return nil
            }
            delay = EchoCanceller.estimateDelay(
                mic: micPrefix,
                reference: sysPrefix,
                sampleRate: sampleRate,
                maxDelaySeconds: maxDelaySeconds
            ) ?? 0
        }

        guard let filter = FrequencyDomainAdaptiveFilter(config: config) else {
            logger.error("无法建立自适应滤波器，跳过本片回声消除")
            return nil
        }
        guard let micReader = SegmentReader(url: micURL),
              let sysReader = SystemAudioMonoReader(url: sysURL, targetSampleRate: sampleRate),
              let writer = PCMWriter(url: outputURL, sampleRate: sampleRate) else {
            logger.error("无法建立流式读取/写入器: \(outputURL.lastPathComponent)")
            return nil
        }

        // 阶段二：流式处理。参考按延迟平移：延迟为正时头部补零，为负时先丢弃参考开头，
        // 两路此后逐块一一对应地喂给滤波器
        var pendingPreludeZeros = max(0, delay)
        if delay < 0 { _ = sysReader.read(-delay) }

        let block = filter.blockSize
        var micBlock = [Float](repeating: 0, count: block)
        var refBlock = [Float](repeating: 0, count: block)
        var outBlock = [Float](repeating: 0, count: block)
        var writtenFrames = 0
        var sysEndedEarly = false

        while true {
            // 取消在块边界生效（块长约 85ms @48kHz，响应足够及时）：放弃本片、
            // 删除半成品后回退原始分片，绝不让不完整文件替换原片
            if isCancelled() {
                logger.warning("回声消除在分片处理中途取消: \(micURL.lastPathComponent)")
                writer.close()
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            let micChunk = micReader.read(block)
            if micChunk.isEmpty { break }
            let count = micChunk.count

            // 麦克风块（末尾不足一块补零，超出部分的结果由 count 截断）
            for i in 0..<block { micBlock[i] = i < count ? micChunk[i] : 0 }

            // 参考块：先吐延迟补偿的前置零，再从系统音频顺序读取
            for i in 0..<block { refBlock[i] = 0 }
            var offset = 0
            while offset < block && pendingPreludeZeros > 0 {
                pendingPreludeZeros -= 1
                offset += 1
            }
            if offset < block {
                let refChunk = sysReader.read(block - offset)
                if refChunk.isEmpty {
                    sysEndedEarly = true
                } else {
                    for i in 0..<min(refChunk.count, block - offset) { refBlock[offset + i] = refChunk[i] }
                }
            }

            filter.process(micBlock: micBlock, referenceBlock: refBlock, into: &outBlock, count: block)
            guard writer.write(outBlock, count: count) else {
                logger.error("清理分片写入失败: \(outputURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            writtenFrames += count
        }

        // 完整写出才认账：写到一半的分片绝不能替换原片，否则就是丢音频
        guard writtenFrames >= Int(micProbeFile.length) else {
            logger.error("清理分片不完整（\(writtenFrames)/\(micProbeFile.length) 帧），沿用原始分片")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        writer.close()
        if sysEndedEarly {
            // 参考提前耗尽只会降低后半段消除效果，不影响音频完整性
            logger.warning("系统音频参考提前结束，\(outputURL.lastPathComponent) 后半段未做消除")
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        logger.info("回声消除: \(micURL.lastPathComponent) 延迟 \(delay) 样本, 耗时 \(String(format: "%.2f", elapsed))s")
        return outputURL
    }

    /// 清理分片命名：{base}_mic_tmp_%04d.caf → {base}_mic_clean_%04d.caf
    ///
    /// 刻意不带 `_mic_tmp`/`_sys_tmp` 标记：崩溃恢复流程按这两个标记收集待合并分片，
    /// 若沿用旧标记会在恢复时被当成另一份待拼接素材而重复入库。
    private static func cleanedURL(for micURL: URL) -> URL {
        let name = micURL.lastPathComponent.replacingOccurrences(of: "_mic_tmp", with: "_mic_clean")
        return micURL.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// 顺序读取 PCM 音频文件为 Float32 单声道样本（麦克风分片用）。
/// 麦克风采集本身就是单声道 Float 可读格式，不需要重采样。
private final class SegmentReader {
    private let file: AVAudioFile
    private var reachedEnd = false

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.file = file
    }

    /// 读取至多 count 个样本；到文件末尾后返回空数组。
    func read(_ count: Int) -> [Float] {
        guard count > 0, !reachedEnd else { return [] }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)
        ) else { return [] }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        } catch {
            reachedEnd = true
            return []
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else {
            reachedEnd = true
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: frames))
    }
}

/// 顺序读取系统音频分片并转成目标采样率的 Float32 单声道样本。
///
/// 系统音频是 48kHz 立体声，麦克风可能是 44.1kHz；声道下混与重采样都交给
/// `AVAudioConverter`，避免自己写重采样。
private final class SystemAudioMonoReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let sourceChunkFrames: AVAudioFrameCount = 4096
    private var reachedEnd = false

    init?(url: URL, targetSampleRate: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        self.file = file
        self.targetFormat = target
        self.converter = converter
    }

    /// 读取至多 count 个目标采样率样本；到文件末尾后返回空数组。
    func read(_ count: Int) -> [Float] {
        guard count > 0, !reachedEnd else { return [] }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(count)
        ) else { return [] }

        let sourceFormat = file.processingFormat
        // 一次调用只喂一块输入，转换器内部会保留不足一帧的余量供下次继续
        var suppliedInput = false
        var attempts = 0
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, inputStatus in
            attempts += 1
            guard !suppliedInput, attempts <= 4 else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: sourceChunkFrames
            ) else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: sourceChunkFrames)
            } catch {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                inputStatus.pointee = .endOfStream
                return nil
            }
            // 必须显式声明 .haveData：返回非 nil 缓冲并不会自动被当成「有数据」，
            // 缺了它转换器会按 .noDataNow 丢弃这一块，表现为「喂了数据却 0 帧输出」
            inputStatus.pointee = .haveData
            return input
        }

        if status == .endOfStream || status == .error { reachedEnd = true }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// 按固定 PCM 规格写出清理后的麦克风分片（与麦克风采集同为 16-bit 单声道 CAF）。
private final class PCMWriter {
    private var file: AVAudioFile?

    init?(url: URL, sampleRate: Double) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return nil }
        self.file = file
    }

    /// 写入前 count 个样本。
    func write(_ samples: [Float], count: Int) -> Bool {
        guard count > 0 else { return true }
        guard let file else { return false }
        let capacity = AVAudioFrameCount(count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = capacity
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: count)
        }
        do {
            try file.write(from: buffer)
        } catch {
            return false
        }
        return true
    }

    /// 关闭文件：置空 AVAudioFile 触发 flush 并 finalize 容器头部，
    /// 否则调用方按 URL 去解析时可能读到尚未写完的容器。
    func close() {
        file = nil
    }
}