import SwiftUI

/// 等待系统录音授权和设备启动时显示状态，失败后在主窗口提供恢复操作。
struct RecordingPermissionBanner: View {
    let notice: RecordingPermissionNotice
    let openSettings: () -> Void
    let recordMicrophone: () -> Void
    let dismiss: () -> Void
    @State private var showsHelp = false

    var body: some View {
        Group {
            if notice == .waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备系统录音…").fontWeight(.medium)
                    Text("录音尚未开始").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("录音尚未开始").font(.headline)
                        Text((notice == .timedOut ? SystemAudioError.startTimedOut : .permissionNotGranted).localizedDescription)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { actions }.fixedSize()
                            VStack(alignment: .leading, spacing: 6) { actions }
                        }
                        .padding(.vertical, 3)
                        DisclosureGroup("已授权仍无法录音？", isExpanded: $showsHelp) {
                            Text("请检查声音输出设备，重新打开 Memozia，再开始录音。")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                    .help("关闭")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var actions: some View {
        Button("打开系统设置", action: openSettings)
            .buttonStyle(.borderedProminent)
        Button("本次仅录麦克风", action: recordMicrophone)
            .buttonStyle(.bordered)
    }
}
