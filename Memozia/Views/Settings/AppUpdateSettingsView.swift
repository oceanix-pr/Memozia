#if os(macOS)
import SwiftUI

struct AppUpdateSettingsView: View {
    private let updates = AppUpdateService.shared

    private var isUnnotarizedBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "MemoziaUnnotarizedBuild")
        return value as? Bool == true || value as? String == "YES"
    }

    var body: some View {
        VStack(spacing: 8) {
            Button("检查更新…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates || updates.isPreparingToInstall)
            Toggle("自动检查更新", isOn: Binding(
                get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!updates.isStarted)
            Text("安装更新需要确认；录音、录屏或处理任务进行中时请稍后安装。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isUnnotarizedBuild {
                Text("此版本未经 Apple 公证。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 360)
    }
}
#endif
