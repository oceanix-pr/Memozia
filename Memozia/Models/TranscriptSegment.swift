import Foundation
import SwiftData

/// 转写片段模型
@Model
final class TranscriptSegment {
    var id: UUID
    var startTime: TimeInterval  // 秒
    var endTime: TimeInterval    // 秒
    var speaker: String?         // 发言人（可选）
    var text: String             // 文本内容

    /// 关联的录音
    var recording: AudioRecording?

    init(startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil, text: String) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - 计算属性（@Model 宏要求放在 extension 中）
extension TranscriptSegment {
    /// 格式化的时间范围显示，例如 "01:23.4 - 02:45.6" 或 "1:01:23.4 - 1:02:45.6"
    /// 转写时间戳保留 0.1 秒精度，便于区分相邻片段与精确定位
    var formattedTimeRange: String {
        "\(startTime.formattedAsDuration(fractionDigits: 1)) - \(endTime.formattedAsDuration(fractionDigits: 1))"
    }

    /// 解密后的文本内容
    var decryptedText: String {
        EncryptionService.decryptSafely(text)
    }
}
