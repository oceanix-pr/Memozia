import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 隐私政策详情视图

/// 设置内的完整协议页。
///
/// 正文与首次同意页共用 `MemoziaPrivacyPolicy.sections`，避免两处文案漂移；
/// 同时承载两项同意管理：声纹单独同意、撤回总体同意。
struct PrivacyPolicyDetailView: View {
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.accepted) private var hasAccepted = false
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.acceptedAt) private var acceptedAt: Double = 0
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.acceptedVersion) private var acceptedVersion = ""
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.voiceprintConsent) private var voiceprintConsent = false

    @State private var showRevokeConfirm = false

    private var needsConsent: Bool {
        MemoziaPrivacyPolicy.needsConsent(accepted: hasAccepted, storedVersion: acceptedVersion)
    }

    private var acceptedDateText: String {
        guard acceptedAt > 0 else { return "—" }
        return Date(timeIntervalSince1970: acceptedAt)
            .formatted(date: .numeric, time: .shortened)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                consentStatusCard
                policySections
                consentActions
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("隐私政策")
        .confirmationDialog(
            "确认撤回隐私同意？",
            isPresented: $showRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("撤回并退出", role: .destructive) {
                MemoziaPrivacyPolicy.revoke()
                #if os(macOS)
                // 同意是使用前提：撤回后立即退出，下次启动重新走同意页。
                // 不在这里顺手删数据——撤回同意不等于删除数据，用户可在数据管理里自行清理。
                NSApplication.shared.terminate(nil)
                #endif
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("撤回后应用将退出，下次启动需要重新阅读并同意隐私政策。已保存在本机的数据不会因此删除。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memozia 隐私政策")
                .font(.title)
                .fontWeight(.bold)

            Text(MemoziaPrivacyPolicy.versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("本政策以简体中文版本为准。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 同意状态

    private var consentStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if needsConsent {
                Label("需要重新确认本政策", systemImage: "exclamationmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("已同意的版本与当前版本不一致。下次启动或重新打开应用时会再次展示同意页。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("已同意当前版本", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("同意时间：\(acceptedDateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: $voiceprintConsent) {
                Text("声纹处理单独同意")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityHint(Text("敏感个人信息，可单独撤回"))

            Text(voiceprintConsent
                 ? "已允许在本机生成并保存声纹特征，用于下次转写时识别说话人。"
                 : "未同意：不会生成声纹，也不会用声纹库比对说话人。录音、转写、总结与待办不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("关闭后不会自动删除已有声纹；如需删除，请到「设置 → 声纹库」逐条移除。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 正文

    private var policySections: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(MemoziaPrivacyPolicy.sections) { section in
                privacySection(title: section.title, content: section.body)
            }
        }
    }

    private var consentActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("撤回隐私同意", role: .destructive) {
                showRevokeConfirm = true
            }
            .disabled(needsConsent)

            Text("撤回后应用将退出；已保存的本机数据不会被删除。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// 政策正文以简体中文为权威版本，因此按 verbatim 渲染：只本地化标题而正文仍是中文
    /// 会造成语言混排。若将来补齐正文译文，再改回 `LocalizedStringKey`。
    private func privacySection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
            Text(verbatim: content)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
