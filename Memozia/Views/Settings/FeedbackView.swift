import SwiftUI

// MARK: - 用户反馈视图
struct FeedbackView: View {
    let recipient: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var feedbackType: FeedbackType = .suggestion
    @State private var feedbackContent = ""
    @State private var contactEmail = ""
    @State private var showMailOpenError = false

    enum FeedbackType: String, CaseIterable, Identifiable {
        case suggestion = "功能建议"
        case bug = "问题报告"
        case other = "其他"

        var id: String { rawValue }

        /// 本地化显示名：rawValue 仅作稳定标识；展示统一走 String(localized:) 显式列出字面量，
        /// 便于 Xcode 从源码抽取（NSLocalizedString(变量) 属动态查表，无法抽取，会报 key 找不到引用）
        var localizedName: String {
            switch self {
            case .suggestion: return String(localized: "功能建议")
            case .bug:        return String(localized: "问题报告")
            case .other:      return String(localized: "其他")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("反馈类型") {
                    Picker("类型", selection: $feedbackType) {
                        ForEach(FeedbackType.allCases) { type in
                            Text(type.localizedName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("反馈内容") {
                    TextEditor(text: $feedbackContent)
                        .frame(minHeight: 120)
                }

                Section("联系方式（可选）") {
                    TextField("邮箱地址", text: $contactEmail)
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    Text("反馈邮箱：\(recipient)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("用户反馈")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开邮件草稿", action: openFeedbackEmail)
                        .disabled(feedbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("无法打开邮件应用", isPresented: $showMailOpenError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("反馈邮箱：\(recipient)")
            }
        }
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 400)
        #endif
    }

    private func openFeedbackEmail() {
        let subject = String(localized: "[Memozia 反馈] \(feedbackType.localizedName)")
        let body = String(localized: """
        反馈类型：\(feedbackType.localizedName)

        内容：
        \(feedbackContent)

        联系方式：\(contactEmail.isEmpty ? String(localized: "未提供") : contactEmail)
        """)

        guard let url = MemoziaContact.feedbackURL(to: recipient, subject: subject, body: body) else {
            showMailOpenError = true
            return
        }
        openURL(url) { accepted in
            if accepted {
                dismiss()
            } else {
                showMailOpenError = true
            }
        }
    }
}
