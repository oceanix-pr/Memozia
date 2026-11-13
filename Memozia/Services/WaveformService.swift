import Foundation
import AVFoundation
import os.log

/// 录音声波包络（用于详情页播放条下方的声波图）。
///
/// 只保存「每列一个 0...1 的峰值」，不保存原始采样：一分钟 48kHz 单声道音频
/// 样本数约 288 万，而 1200 列的包络只有 1200 个 Float。
struct AudioWaveform: Sendable, Equatable {
    /// 每列归一化峰值（0 = 静音，1 = 全曲最响处）
    let peaks: [Float]

    /// 该列是否可视为「有声音」（与 `WaveformAnalyzer.silenceThreshold` 同口径）
    func isAudible(_ index: Int) -> Bool {
        guard peaks.indices.contains(index) else { return false }
        return peaks[index] > WaveformAnalyzer.silenceThreshold
    }
}

/// 声波图计算：离线解码音频 → 分列取峰值 → 归一化。
///
/// 解码用 `AVAssetReader`（不经过播放器，不影响正在播放的 `AVPlayer`），
/// 该 API 本身是阻塞式的，因此整个流程放在后台任务里执行。
enum WaveformAnalyzer {
    /// 绝对幅度低于 -54 dBFS 的底噪不当成有声段；只按全曲最大值归一化时，
    /// 一段几乎无声的录音也会被画成满格波形。
    static let absoluteSilenceFloor: Float = 0.002

    /// 归一化峰值的静音阈值：低于此值视为「这里没有声音」。
    ///
    /// 归一化后峰值等于「相对全曲最响处的比例」，因此阈值与录音音量无关：
    /// 0.04 ≈ 全曲最响处的 -28dB，正常说话声远高于此，底噪与静音段低于此。
    static let silenceThreshold: Float = 0.04

    /// 每列对应的音频时长（秒）。列数 = 时长 / 该值，并夹在 `minColumns...maxColumns`。
    ///
    /// 先以 0.25s 一列提取峰值，再压缩到 `maxColumns`，保留长录音里的短促响声。
    /// 上限避免一小时以上的录音让播放进度刷新时重复绘制上万个圆角路径。
    static let secondsPerColumn: Double = 0.25
    static let minColumns = 60
    static let maxColumns = 2400

    /// 目标列数（按时长估算，供视图在分析完成前占位使用）
    static func columnCount(forDuration duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return minColumns }
        let estimate = (duration / secondsPerColumn).rounded(.up)
        return min(max(Int(min(estimate, Double(maxColumns))), minColumns), maxColumns)
    }

    /// 分析音频文件的声波包络。
    ///
    /// - Parameters:
    ///   - url: 音频文件（m4a / wav / mp3 / 视频文件的音轨均可）
    ///   - columns: 期望列数，默认按时长估算
    /// - Returns: 归一化峰值；文件无法解码时返回 nil
    static func analyze(url: URL, columns: Int? = nil) async -> AudioWaveform? {
        guard !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        let targetColumns: Int
        if let columns {
            targetColumns = max(1, columns)
        } else {
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            targetColumns = columnCount(forDuration: duration)
        }
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：加载音轨失败 \(error.localizedDescription, privacy: .private)")
            return nil
        }
        guard let track = tracks.first else {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：文件没有音轨")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        // 统一转成单声道 Float32 PCM：跨格式（m4a/wav/mp3/视频音轨）解码结果一致，
        // 也免去逐样本处理 Int16 的位宽差异
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000
        ]

        let peaks: [Float]?
        if #available(macOS 26.0, *) {
            peaks = await readPeaksModern(asset: asset, track: track, settings: settings)
        } else {
            peaks = await readPeaksLegacy(asset: asset, track: track, settings: settings)
        }

        guard !Task.isCancelled, let rawPeaks = peaks, !rawPeaks.isEmpty else { return nil }
        return AudioWaveform(peaks: normalize(rawPeaks, limit: targetColumns))
    }

    /// macOS 26 起的并发 Reader API（与 `AudioConverter` 同一写法，避开 macOS 27 已弃用的 add/copy 接口）
    @available(macOS 26.0, *)
    private static func readPeaksModern(
        asset: AVURLAsset,
        track: AVAssetTrack,
        settings: [String: Any]
    ) async -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：无法挂载音频读取输出")
            return nil
        }
        let provider = reader.outputProvider(for: output)

        var accumulator = PeakAccumulator()
        do {
            try reader.start()
            while let sampleBuffer = try await provider.next() {
                try Task.checkCancellation()
                guard sampleBuffer.withUnsafeSampleBuffer({ accumulator.consume($0) }) else {
                    Logger(subsystem: "app.memozia", category: "Waveform")
                        .debug("声波分析：读取 PCM 缓冲失败")
                    reader.cancelReading()
                    return nil
                }
            }
        } catch {
            if !Task.isCancelled {
                Logger(subsystem: "app.memozia", category: "Waveform")
                    .debug("声波分析：读取失败 \(error.localizedDescription, privacy: .private)")
            }
            reader.cancelReading()
            return nil
        }
        guard !Task.isCancelled else {
            reader.cancelReading()
            return nil
        }
        if reader.status == .failed {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：读取器失败 \(reader.error?.localizedDescription ?? "-", privacy: .private)")
            return nil
        }
        return accumulator.finish()
    }

    /// 兼容 macOS 15–25：旧 API 隔离在有效系统范围内，避免 macOS 27 SDK 构建报弃用
    @available(macOS, deprecated: 26.0)
    private static func readPeaksLegacy(
        asset: AVURLAsset,
        track: AVAssetTrack,
        settings: [String: Any]
    ) async -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：无法挂载音频读取输出")
            return nil
        }
        reader.add(output)
        guard reader.startReading() else {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：读取器启动失败 \(reader.error?.localizedDescription ?? "-", privacy: .private)")
            return nil
        }

        var accumulator = PeakAccumulator()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard accumulator.consume(sampleBuffer) else {
                Logger(subsystem: "app.memozia", category: "Waveform")
                    .debug("声波分析：读取 PCM 缓冲失败")
                reader.cancelReading()
                return nil
            }
        }
        let failed = reader.status == .failed
        let failureMessage = reader.error?.localizedDescription
        reader.cancelReading()
        guard !Task.isCancelled else { return nil }
        if failed {
            Logger(subsystem: "app.memozia", category: "Waveform")
                .debug("声波分析：读取器失败 \(failureMessage ?? "-", privacy: .private)")
            return nil
        }
        return accumulator.finish()
    }

    /// 归一化到 0...1，并压缩到 `limit` 列以内。
    /// 全静音文件保持全 0（视图因此显示一条静音基线）。
    static func normalize(_ peaks: [Float], limit: Int) -> [Float] {
        let limit = max(1, limit)
        let sampled = peaks.count > limit ? downsample(peaks, to: limit) : peaks
        guard let maximum = sampled.max(), maximum > absoluteSilenceFloor else {
            return Array(repeating: 0, count: sampled.count)
        }
        return sampled.map { $0 <= absoluteSilenceFloor ? 0 : min(1, $0 / maximum) }
    }

    /// 按块取最大值把数组压缩到 `target` 列（保留短促的响声，不做平均）
    private static func downsample(_ values: [Float], to target: Int) -> [Float] {
        guard target > 0, values.count > target else { return values }
        var result: [Float] = []
        result.reserveCapacity(target)
        for index in 0..<target {
            let start = values.count * index / target
            let end = max(start + 1, values.count * (index + 1) / target)
            var peak: Float = 0
            for value in values[start..<min(end, values.count)] where value > peak {
                peak = value
            }
            result.append(peak)
        }
        return result
    }
}

/// 把 PCM 采样缓冲累加成「每列一个峰值」。
///
/// 采样率固定为 16kHz（由调用方的 audioSettings 决定），每列样本数据此换算。
private struct PeakAccumulator {
    private var peaks: [Float] = []
    private var columnPeak: Float = 0
    private var columnSampleCount = 0
    private let samplesPerColumn = max(1, Int((WaveformAnalyzer.secondsPerColumn * 16_000).rounded()))

    mutating func consume(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let byteCount = length / MemoryLayout<Float>.size * MemoryLayout<Float>.size
        guard byteCount > 0 else { return true }

        var data = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return false }

        for sample in data {
            let magnitude = sample.isFinite ? abs(sample) : 0
            if magnitude > columnPeak { columnPeak = magnitude }
            columnSampleCount += 1
            if columnSampleCount >= samplesPerColumn {
                peaks.append(columnPeak)
                columnPeak = 0
                columnSampleCount = 0
            }
        }
        return true
    }

    /// 收尾：尾部不足一列的声音也要保留，否则最后一段会被「吞掉」
    mutating func finish() -> [Float] {
        if columnSampleCount > 0 { peaks.append(columnPeak) }
        return peaks
    }
}

/// 声波包络的进程内缓存：切换条目/重新打开详情页时不必重复解码。
///
/// 以「文件路径 + 修改时间 + 大小」为键，录音被替换或清理后自动失效。
@MainActor
final class WaveformCache {
    static let shared = WaveformCache()

    private var storage: [String: AudioWaveform] = [:]
    private var insertionOrder: [String] = []
    private let limit = 24

    /// 取缓存或分析当前文件。调用方取消时，分析也会停止，不留下后台解码任务。
    func waveform(for url: URL) async -> AudioWaveform? {
        let key = Self.cacheKey(for: url)
        if let cached = storage[key] { return cached }
        guard let waveform = await WaveformAnalyzer.analyze(url: url),
              !Task.isCancelled,
              !waveform.peaks.isEmpty,
              Self.cacheKey(for: url) == key else { return nil }

        if let cached = storage[key] { return cached }
        storage[key] = waveform
        insertionOrder.append(key)
        if insertionOrder.count > limit {
            let oldest = insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return waveform
    }

    private static func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(url.path)|\(modified)|\(size)"
    }
}
