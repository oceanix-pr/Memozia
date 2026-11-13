import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 用户反馈视图
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackType: FeedbackType = .suggestion
    @State private var feedbackContent = ""
    @State private var contactEmail = ""

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
                        #if os(iOS)
                        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
                        .keyboardType(.emailAddress)
                        */
                        #endif
                }

                Section {
                    Text("感谢您的反馈！我们将认真阅读每一条建议。\n点击发送将通过系统邮件应用提交。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("用户反馈")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        sendFeedback()
                        dismiss()
                    }
                    .disabled(feedbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 400)
        #endif
    }

    private func sendFeedback() {
        guard let email = MemoziaContact.email else { return }
        let subject = "[Memozia 反馈] \(feedbackType.localizedName)"
        let body = """
        反馈类型：\(feedbackType.localizedName)

        内容：
        \(feedbackContent)

        联系方式：\(contactEmail.isEmpty ? String(localized: "未提供") : contactEmail)
        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:\(email)?subject=\(encodedSubject)&body=\(encodedBody)") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
            UIApplication.shared.open(url)
            */
            #endif
        }
    }
}
