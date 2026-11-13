import AVFoundation
import Foundation

/// 两路采集共用 host clock；只保存文件名和相对时间，不保存设备标识或会议内容。
struct RecordingSegmentTimeline: Codable, Sendable, Equatable {
    static let fileName = "capture_timeline.json"
    var version = 1
    var starts: [String: TimeInterval] = [:]
    var end: TimeInterval?

    private var origin: TimeInterval { starts.values.min() ?? 0 }

    func offset(for url: URL) throws -> TimeInterval {
        guard let start = starts[url.lastPathComponent] else { throw CocoaError(.fileReadCorruptFile) }
        return start - origin
    }

    var duration: TimeInterval? { end.map { max(0, $0 - origin) } }

    static func canReduceEcho(mic: [URL], system: [URL], timeline: Self?) async -> Bool {
        guard let timeline, !mic.isEmpty, mic.count == system.count else { return false }
        for (micURL, sysURL) in zip(mic, system) {
            guard let micStart = try? timeline.offset(for: micURL),
                  let sysStart = try? timeline.offset(for: sysURL), abs(micStart - sysStart) < 0.1,
                  let micDuration = try? await AVURLAsset(url: micURL).load(.duration),
                  let sysDuration = try? await AVURLAsset(url: sysURL).load(.duration),
                  abs(micDuration.seconds - sysDuration.seconds) < 0.1 else { return false }
        }
        return true
    }

    static func load(in folder: URL) throws -> Self? {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent(fileName)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1,
              value.starts.allSatisfy({ name, time in
                  !name.isEmpty && URL(fileURLWithPath: name).lastPathComponent == name
                      && time.isFinite && time >= 0
              }), value.end.map({ $0.isFinite && $0 >= (value.starts.values.max() ?? 0) }) != false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    /// 没有 sidecar 的旧录音沿用顺序拼接；新录音缺少时间证据时失败并保留原片，不能压缩缺口。
    @discardableResult
    static func append(_ urls: [URL], to track: AVMutableCompositionTrack?,
                       timeline: Self?, temporaryFiles: inout [URL]) async throws -> TimeInterval {
        guard let track else { throw CocoaError(.fileWriteUnknown) }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let duration = try await asset.load(.duration)
            let target = try timeline.map { CMTime(seconds: try $0.offset(for: url), preferredTimescale: 48_000) } ?? cursor
            // 毫秒级采集抖动可以重叠；顺延以完整保留样本，不覆盖已插入的声音。
            let start = max(cursor, target)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: start)
            cursor = start + duration
        }
        if let seconds = timeline?.duration, seconds > cursor.seconds, let folder = urls.first?.deletingLastPathComponent() {
            // AAC 导出会丢弃纯 empty edit 的末尾；插入真实零采样，保证缺失尾段也保留时长。
            let silenceURL = folder.appendingPathComponent("capture_silence_\(UUID()).caf")
            temporaryFiles.append(silenceURL)
            try writeSilence(to: silenceURL)
            let asset = AVURLAsset(url: silenceURL)
            guard let silence = try await asset.loadTracks(withMediaType: .audio).first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let length = min(seconds - cursor.seconds, 1024.0 / 48_000)
            let start = CMTime(seconds: seconds - length, preferredTimescale: 48_000)
            try track.insertTimeRange(CMTimeRange(start: .zero,
                duration: CMTime(seconds: length, preferredTimescale: 48_000)), of: silence, at: start)
            cursor = track.timeRange.end
        }
        return cursor.seconds
    }
    private static func writeSilence(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = 1024
        buffer.floatChannelData?[0].update(repeating: 0, count: 1024)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

}

/// 回调只在锁内登记首包，磁盘写入由 MainActor 节拍/停止负责，绝不在实时音频线程写 JSON。
/// 所有可变状态受 lock 保护；持久化只有一个 MainActor 调用方。
final class RecordingSegmentTimelineStore: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void = {}) { self.onChange = onChange }
    private let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    private var value = RecordingSegmentTimeline()
    private var revision = 0
    @MainActor private var savedRevision = -1

    func noteWrite(to url: URL, hostTime: TimeInterval, frames: Int) {
        guard frames > 0, hostTime.isFinite else { return }
        lock.lock()
        guard value.starts[url.lastPathComponent] == nil else { lock.unlock(); return }
        value.starts[url.lastPathComponent] = max(0, hostTime - origin)
        revision += 1
        lock.unlock()
        onChange()
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        value.end = max(value.starts.values.max() ?? 0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - origin)
        revision += 1
    }

    private func snapshot() -> (RecordingSegmentTimeline, Int) {
        lock.lock(); defer { lock.unlock() }
        return (value, revision)
    }

    @MainActor func save(in folder: URL) throws {
        let (snapshot, currentRevision) = snapshot()
        guard currentRevision != savedRevision else { return }
        try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent(RecordingSegmentTimeline.fileName), options: .atomic)
        savedRevision = currentRevision
    }
}
