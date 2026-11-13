import Foundation

/// 仅记录采集状态与处理结果，不包含会议内容、窗口标题或凭据。
/// 文件是权威源；不新增 SwiftData 字段，旧录音没有此文件时视为无记录。
struct RecordingCaptureReport: Codable, Sendable, Equatable {
    enum Track: String, Codable, Sendable { case microphone, systemAudio }
    struct Interruption: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        let track: Track
        let observedStart: Date
        var observedEnd: Date?
        var recovered = false
        /// 只说明整个观察区间是否处于用户静音；不据此保证时间轴没有缺口。
        var mutedThroughout = false
        var lastSuccessfulWriteAt: Date? = nil

        var message: String {
            switch (track, recovered, mutedThroughout) {
            case (.microphone, true, true):
                return String(localized: "麦克风采集曾在静音期间中断，随后已恢复。")
            case (.microphone, true, false):
                return String(localized: "麦克风采集曾短暂中断，随后已恢复；期间的声音可能缺失。")
            case (.microphone, false, _):
                return String(localized: "麦克风采集尚未确认恢复，部分麦克风声音可能缺失。")
            case (.systemAudio, true, _):
                return String(localized: "系统音频曾中断，随后已恢复；中断期间可能存在静音或缺失。")
            case (.systemAudio, false, _):
                return String(localized: "系统音频中断后未确认恢复，录音可能缺少中断后的系统声音。")
            }
        }
    }
    enum Issue: String, Codable, Sendable {
        case sleep, systemWriterFailure, samplesDropped, captureWarning, audioDegraded, videoDegraded

        var message: String {
            switch self {
            case .sleep: return String(localized: "录音期间发生系统睡眠，睡眠期间未采集音频。")
            case .systemWriterFailure: return String(localized: "系统音频曾写入失败，部分系统音频分片可能不完整。")
            case .samplesDropped: return String(localized: "系统音频曾丢弃样本，录音可能存在短暂缺口。")
            case .captureWarning: return String(localized: "录音期间出现采集提醒，请回听确认内容。")
            case .audioDegraded: return String(localized: "音频处理发生降级，部分音轨可能缺失。")
            case .videoDegraded: return String(localized: "视频处理发生异常，音频已保留，视频或其声音可能不完整。")
            }
        }
    }

    /// Optional 字段兼容既有 version 1 报告。
    var skippedSegments: [String]?
    /// 仅在修复副本校验并成功合入最终录音后填写；不表示补回了未采集的声音。
    var repairedSegments: [String]?
    var retainedOriginals: Bool?
    var microphoneLastSuccessfulWriteAt: Date?
    var microphoneWrittenFrames: Int64?
    var version = 1
    var interruptions: [Interruption] = []
    var issues: [Issue] = []
    var isEmpty: Bool { interruptions.isEmpty && issues.isEmpty && (repairedSegments ?? []).isEmpty }
    var hasWarning: Bool {
        !issues.isEmpty || interruptions.contains {
            !($0.track == .microphone && $0.recovered && $0.mutedThroughout)
        }
    }
    var summary: String? {
        var seen = Set<String>()
        let repairs = (repairedSegments ?? []).isEmpty ? [] : [String(localized: "音频分片已自动修复并合入录音。")]
        let messages = (interruptions.map(\.message) + issues.map(\.message) + repairs).filter { seen.insert($0).inserted }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

enum RecordingCaptureReportStore {
    static let fileName = "capture_report.json"

    static func save(_ report: RecordingCaptureReport, in folder: URL) throws {
        guard !report.isEmpty else { return }
        let data = try JSONEncoder().encode(report)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static func load(in folder: URL) throws -> RecordingCaptureReport? {
        let url = folder.appendingPathComponent(fileName)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let report = try JSONDecoder().decode(RecordingCaptureReport.self, from: data)
        guard report.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return report
    }
}

/// 只有音频、详情、元数据与数据库均确认成功后才发布保存完成反馈。
struct RecordingFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isWarning: Bool
    var folderName: String? = nil
}
