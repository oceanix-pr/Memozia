import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 隐私政策同意视图（首次启动与政策主版本升级后展示）
///
/// 正文不在本文件里：唯一事实来源是 `MemoziaPrivacyPolicy.sections`。
/// 这样改协议只需要改一处，并由 `privacyPolicyVersion` 决定是否重新征求同意。
struct PrivacyConsentView: View {
    /// 声纹（敏感个人信息）的单独同意。
    /// 用本地草稿而不是直接写 `@AppStorage`：用户勾选后又选择“不同意并退出”时，
    /// 不能把一次未完成的同意落盘。只有点「同意并继续」才由 `accept` 写入。
    @State private var voiceprintConsent: Bool

    init() {
        _voiceprintConsent = State(
            initialValue: MemoziaPrivacyPolicy.voiceprintConsentGranted()
        )
    }

    @Environment(\.dismiss) private var dismiss

    @State private var hasScrolledToBottom = false
    /// 拒绝隐私政策是"退出应用"级别的破坏性动作，旧实现点一下就直接 terminate，
    /// 误触无任何挽回机会；这里补一次确认
    @State private var showDeclineConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            policyContent
            Divider()
            footer
        }
        .confirmationDialog(
            "确认不同意并退出？",
            isPresented: $showDeclineConfirm,
            titleVisibility: .visible
        ) {
            Button("不同意并退出", role: .destructive) {
                // 用户拒绝，退出应用
                #if os(macOS)
                NSApplication.shared.terminate(nil)
                #else
                /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
                exit(0)
                */
                #endif
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不同意将退出 Memozia，且未同意前无法使用录音、转写与总结功能。")
        }
        #if os(macOS)
        .frame(width: 600, height: 640)
        #endif
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("隐私政策与数据使用")
                .font(.title2)
                .fontWeight(.bold)

            Text("请阅读以下内容并确认同意")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 版本号是合规可核对项：用户需要知道当前同意的是哪一版
            Text(MemoziaPrivacyPolicy.versionLine)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // 协议正文当前只有简体中文，明确语言优先顺序，避免用户误以为是本地化缺失
            Text("本政策以简体中文版本为准。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    // MARK: - 正文

    private var policyContent: some View {
        ScrollViewReader { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(MemoziaPrivacyPolicy.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            privacySection(title: section.title, content: section.body)

                            if section.requiresSeparateConsent {
                                separateConsentControl
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(24)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 真正阅读到底部才解锁「同意并继续」。
                // 旧实现 onAppear 后 0.3s 无条件滚到底并置 hasScrolledToBottom = true，
                // 使阅读门槛形同虚设（用户看到按钮瞬间可点）
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 24
            } action: { _, reachedBottom in
                if reachedBottom { hasScrolledToBottom = true }
            }
        }
    }

    /// PIPL 的「单独同意」不能混在总体同意里：敏感个人信息要有独立、可拒绝的勾选项。
    private var separateConsentControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $voiceprintConsent) {
                Text("声纹处理单独同意")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityHint(Text("敏感个人信息，可单独拒绝；拒绝后仅声纹功能不可用"))

            Text("勾选后才允许在本机生成并保存声纹特征；不勾选不影响录音、转写、总结与待办。你可以稍后在「设置 → 关于 → 隐私政策」更改。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                // 一次写入同意时间、政策版本与声纹单独同意
                MemoziaPrivacyPolicy.accept(voiceprintConsent: voiceprintConsent)
                dismiss()
            } label: {
                Text("同意并继续")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasScrolledToBottom)

            if !hasScrolledToBottom {
                Text("请先阅读完整内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("不同意") {
                // 退出应用前先确认（旧实现误触即退出，且这是首次启动页、无法返回）
                showDeclineConfirm = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(24)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
