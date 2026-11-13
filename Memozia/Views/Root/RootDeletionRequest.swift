import Foundation

/// 删除确认的统一载荷（单选录音 / 单选快捷笔记 / 批量混合）。
///
/// 旧实现用三个布尔量驱动三个 `confirmationDialog`：混合选中时「两个 isPresented
/// 同帧置位」会让 SwiftUI 只呈现其中一个，另一类条目被静默跳过——用户以为都删了。
/// 改为单载荷后，「同一时刻只可能有一个删除确认框」由类型保证，不再依赖注释里
/// 的人际约定；展示与否也从载荷派生（`pendingDeletion != nil`），不存在
/// 「标记已置位、载荷为空」的中间态。
///
/// 展示文案在「提出删除请求」时就固定成字符串：动作执行后 `@Model` 可能已被从
/// 上下文删除，若 message 闭包届时再去读 `recording.fileName`，读到的是脏值甚至
/// 触发 SwiftData 断言。凭据（kind）只用于分流动作，不参与文案渲染。
struct RootDeletionRequest {
    /// 对话框标题（提出请求时算好）
    let title: String
    /// 对话框正文（提出请求时算好，之后不再触碰 @Model）
    let message: String
    /// 动作分流凭据
    let kind: Kind

    enum Kind {
        case recording(AudioRecording)
        case quickNote(QuickNote)
        /// 批量删除：目标集合仍在 RootView 的 recordingsToDelete / quickNotesToDelete 里
        case batch
    }
}

extension RootDeletionRequest {
    /// 单选录音
    static func recording(_ recording: AudioRecording) -> RootDeletionRequest {
        RootDeletionRequest(
            title: String(localized: "确认删除录音？"),
            message: String(
                localized: "确定要删除「\(recording.fileName)」吗？\n录音文件和转写记录将一并删除，删除后无法恢复。"
            ),
            kind: .recording(recording)
        )
    }

    /// 单选快捷笔记
    static func quickNote(_ note: QuickNote) -> RootDeletionRequest {
        RootDeletionRequest(
            title: String(localized: "确认删除快捷笔记？"),
            message: String(
                localized: "确定要删除「\(note.title)」吗？\n笔记内容和相关待办将一并删除，删除后无法恢复。"
            ),
            kind: .quickNote(note)
        )
    }

    /// 批量删除：录音与快捷笔记可混合选中，故同一次确认里按类型各给一个破坏性按钮
    static func batch(recordings: [AudioRecording], quickNotes: [QuickNote]) -> RootDeletionRequest {
        let title: String
        let message: String
        switch (recordings.isEmpty, quickNotes.isEmpty) {
        case (false, true):
            title = String(localized: "确认删除选中的录音？")
            message = String(localized: "选中的录音及其录音文件将一并删除，删除后无法恢复。")
        case (true, false):
            title = String(localized: "确认删除选中的快捷笔记？")
            message = String(localized: "选中的快捷笔记及其文件和待办将一并删除，删除后无法恢复。")
        default:
            title = String(localized: "确认删除选中的条目？")
            message = String(localized: "选中的录音与快捷笔记及其文件和待办将一并删除，删除后无法恢复。")
        }
        return RootDeletionRequest(title: title, message: message, kind: .batch)
    }
}
