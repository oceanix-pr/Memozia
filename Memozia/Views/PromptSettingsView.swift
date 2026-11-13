import SwiftUI

/// 「设置 → 提示词」（仅专业模式）：集中管理各场景使用的 LLM 提示词。
///
/// 交互取向：
/// - 列表按「总结 / 提取与生成 / 判定」分组，每行展示名称、生效场景与「已自定义」标记，
///   让用户一眼看清哪些模板偏离了内置默认；
/// - 编辑放在独立弹窗内，长文本有足够空间，并提供一键「恢复默认」，降低改坏后无法回退的风险；
/// - 对格式敏感的模板（待办 JSON、会议判定单字输出）给出显式警告；
/// - 提示词属模型指令，不做本地化。
struct PromptsSettingsView: View {
    /// 正在编辑的模板（nil 表示未打开弹窗）
    @State private var editingKind: PromptTemplateKind?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("自定义提示词会覆盖内置模板，仅影响本机的生成结果。", systemImage: "info.circle")
                        .font(.subheadline)
                    Text("修改后从下一次总结、待办拆解或标题生成开始生效；留空或点「恢复默认」即可还原。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(PromptTemplateKind.Category.allCases) { category in
                Section(category.localizedName) {
                    ForEach(PromptTemplateKind.allCases.filter { $0.category == category }) { kind in
                        promptRow(kind)
                    }
                }
            }
        }
        .navigationTitle("提示词")
        .sheet(item: $editingKind) { kind in
            PromptEditorView(kind: kind)
        }
    }

    private func promptRow(_ kind: PromptTemplateKind) -> some View {
        Button {
            editingKind = kind
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(kind.displayName)
                        if PromptTemplateStore.isCustomized(kind) {
                            Text("已自定义")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(kind.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 提示词编辑弹窗：编辑单个模板，支持保存与一键恢复默认。
struct PromptEditorView: View {
    let kind: PromptTemplateKind

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    /// 当前已保存的生效文本（自定义优先，否则内置默认）
    private var storedValue: String {
        PromptTemplateStore.override(for: kind) ?? kind.defaultText
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDefaultText: Bool {
        trimmedDraft == kind.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有实际改动且非空白才允许保存
    private var hasChanges: Bool {
        draft != storedValue
    }

    private var canSave: Bool {
        hasChanges && !trimmedDraft.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 560, minHeight: 380)
                    .padding(8)
                Divider()
                footer
            }
            .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 640)
            .navigationTitle(kind.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            draft = storedValue
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind.isFormatSensitive {
                Label(
                    "该提示词直接决定输出格式，请保留原有的字段、结构与格式说明，否则生成结果可能无法解析。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("\(draft.count) 字")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("恢复默认") { draft = kind.defaultText }
                .disabled(isDefaultText)
        }
        .padding(16)
    }

    private func save() {
        // 与内置默认一致（含用户清空后点恢复默认）即删除覆盖，回到默认
        if isDefaultText {
            PromptTemplateStore.restoreDefault(kind)
        } else {
            PromptTemplateStore.setOverride(draft, for: kind)
        }
        dismiss()
    }
}
