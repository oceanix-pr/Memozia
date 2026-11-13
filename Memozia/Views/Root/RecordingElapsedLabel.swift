import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 录音计时文本（独立子视图）

/// 录音时长文本。
///
/// 单独成视图的原因：`@Observable` 按每个 body 实际读取的属性建立依赖，
/// 旧写法直接在 `RootView.recordingStatusBadge` 里读 `viewModel.recordingElapsed`
/// （底层是 `MeetingRecorderService.elapsedSeconds`，1Hz 定时器写入），
/// 等于录音期间每秒把整棵根视图（列表全量行视图 + 详情 + 7 个 `.animation(value:)`）
/// 重算一次。关进最小子树后，每秒只有这个 Text 失效。
struct RecordingElapsedLabel: View {
    let viewModel: RecordingViewModel

    var body: some View {
        Text(Self.formatted(viewModel.recordingElapsed))
            .font(.caption.monospacedDigit())
    }

    /// mm:ss / h:mm:ss 格式化（供本视图与徽章复用）
    static func formatted(_ seconds: TimeInterval) -> String {
        // 负值钳到 0：计时器与 startDate 之间存在竞态窗口，
        // 直接 Int(负数) 会格式化成 "00:-05" 这类可见异常文本
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
