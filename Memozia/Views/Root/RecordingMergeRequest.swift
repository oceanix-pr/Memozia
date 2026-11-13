import Foundation

/// 确认框文案在请求时固定，异步删除后不再访问已失效的模型。
@MainActor
struct RecordingMergeRequest {
    let recordings: [AudioRecording]
    let message: String

    init(recordings: [AudioRecording]) {
        self.recordings = recordings
        let title = recordings.last?.fileName ?? ""
        message = String(localized: "将选中的 \(recordings.count) 笔录音按时间从早到晚合并到最新的「\(title)」。保留转写、总结和待办，随后删除较早的录音。此操作无法撤销。")
    }
}
