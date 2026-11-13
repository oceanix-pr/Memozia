import SwiftUI
import SwiftData

/// 总结展示视图（支持流式输出 + Markdown 渲染 + 编辑）
struct SummaryView: View {
    let recording: AudioRecording
    @Bindable var viewModel: RecordingViewModel
    @Binding var selectedLLMConfig: LLMConfig?
    /// 默认提醒事项列表 ID（从 SettingsVM 传入，避免引入整个 SettingsVM）
    var defaultReminderListID: String
    var isProMode: Bool = true
    /// 临时模式（不落盘）：禁用总结编辑与待办增删改，仅保留浏览与复制
    var isReadOnly: Bool = false

    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false
    @State private var editDraft = ""
    /// 流式「思考过程」折叠态（默认折叠）
    @State private var isReasoningExpanded = false

    // 待办编辑 Sheet 状态
    @State private var showTodoEdit = false
    @State private var editingTodoItem: TodoItem?

    // F-2: 清除待办确认对话框状态
    @State private var showClearTodosConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // 模型选择条已归并到 RecordingDetailView 页签下方的共享 LLMModelSelectorBar

            // 内容区域
            if isEditing {
                // 编辑模式脱离 ScrollView：编辑框占满父容器高度（内建滚动），
                // 替换/全部替换改动内容时编辑框高度保持不变（与录音转写编辑态一致）
                VStack(spacing: 0) {
                    editingContentView
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)

                    // 待办列表区域
                    Divider().padding(.vertical, 8)
                    todoSection
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    Group {
                        let decryptedSummary = recording.decryptedSummary
                        if viewModel.isSummarizing {
                            // 流式输出中
                            streamingContentView
                        } else if !decryptedSummary.isEmpty {
                            // 已有总结
                            summaryContentView(decryptedSummary)
                        } else {
                            // 空状态
                            emptyStateView
                        }

                        // 待办列表区域
                        Divider().padding(.vertical, 8)
                        todoSection
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }

            // 底部操作栏
            if viewModel.isSummarizing {
                cancelBar
            } else if isEditing {
                editingActionBar
            } else {
                bottomActionBar
            }
        }
        .onAppear {
            viewModel.loadTodoDocument(for: recording)
        }
        .onChange(of: recording.id) { _, newID in
            viewModel.loadTodoDocument(for: recording)
        }
        .sheet(isPresented: $showTodoEdit) {
            TodoItemEditView(
                isPresented: $showTodoEdit,
                initialItem: editingTodoItem,
                onSave: { item in
                    if editingTodoItem != nil {
                        viewModel.updateTodoItem(item, for: recording)
                    } else {
                        viewModel.addTodoItem(item, for: recording)
                    }
                    editingTodoItem = nil
                }
            )
        }
    }

    // MARK: - 流式输出内容

    private var streamingContentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成总结...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 推理型模型（Qwen3 / DeepSeek-R1 等）先输出思考过程再给正文：把思考折叠展示，
            // 预算被思考吃掉导致正文为空时，用户能直接看到原因（默认折叠，不干扰正常阅读）
            ReasoningDisclosureView(
                text: viewModel.summaryReasoningText,
                isExpanded: $isReasoningExpanded
            )

            // 流式内容合批在后台解析，生成期间也展示 Markdown。
            StreamingMarkdownView(markdown: viewModel.summaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            AIContentDisclaimer()
        }
    }

    // MARK: - 总结内容

    private func summaryContentView(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 生成时间
            if let generatedAt = recording.summaryGeneratedAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("生成于 \(generatedAt, format: .dateTime.hour().minute())")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
            }

            // Markdown 渲染的总结内容
            MarkdownView(markdown: summary)

            // 模型产出的总结可能出错：提示紧贴正文，隐私政策里另有完整说明
            AIContentDisclaimer()
        }
    }

    // MARK: - 编辑模式内容

    private var editingContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.caption2)
                Text("编辑模式（支持 Markdown）")
                    .font(.caption)
            }
            .foregroundStyle(.tint)

            TextEditor(text: $editDraft)
                .font(.body)
                .frame(minHeight: 240)
                .padding(8)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.tint.opacity(0.5), lineWidth: 1)
                )
                // 编辑模式查找（⌘F）/替换（⌘R）支持
                .textFindReplace(text: $editDraft)
        }
    }

    // MARK: - 空状态

    @ViewBuilder
    private var emptyStateView: some View {
        if recording.transcriptionStatus != .completed {
            ContentUnavailableView(
                "尚未生成总结",
                systemImage: "text.badge.plus",
                description: Text("请先完成录音转写，再生成总结")
            )
        } else {
            ContentUnavailableView(
                "尚未生成总结",
                systemImage: "text.badge.plus",
                description: Text("点击下方按钮，使用 LLM 对转写内容进行分析总结")
            )
        }
    }

    // MARK: - 取消栏

    private var cancelBar: some View {
        HStack {
            Spacer()
            Button {
                viewModel.cancelSummary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                    Text("取消生成")
                }
                .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 底部操作栏

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            SummaryHistoryButton(folder: recording.folderURL)
            Spacer()

            // 会议/概要双按钮：模板由用户显式选择（不再自动判定），
            // 已有总结时变为「重新生成会议/概要总结」
            let summaryEmpty = recording.decryptedSummary.isEmpty
            let summaryDisabled = recording.transcriptionStatus != .completed
                || selectedLLMConfig == nil
                || viewModel.isSummarizing

            if isProMode {
                Button {
                    generateSummary(asMeeting: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: summaryEmpty ? "person.3.fill" : "arrow.clockwise")
                        Text(summaryEmpty ? "会议总结" : "重新生成会议总结")
                    }
                    .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .disabled(summaryDisabled)

                Button {
                    generateSummary(asMeeting: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: summaryEmpty ? "text.justify" : "arrow.clockwise")
                        Text(summaryEmpty ? "概要总结" : "重新生成概要总结")
                    }
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .disabled(summaryDisabled)
            } else {
                Button {
                    generateSummary(asMeeting: nil)
                } label: {
                    Label(
                        summaryEmpty ? "生成总结" : "重新生成总结",
                        systemImage: summaryEmpty ? "sparkles" : "arrow.clockwise"
                    )
                    .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .disabled(summaryDisabled)
            }

            // 复制按钮
            let decryptedSummary = recording.decryptedSummary
            if !decryptedSummary.isEmpty {
                Button {
                    copyToClipboard(decryptedSummary)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                // 编辑按钮
                if isProMode {
                    Button {
                        editDraft = decryptedSummary
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReadOnly)
                }
            }

            // 拆解为待办按钮（仅在总结非空、未在生成总结时可用）
            if !recording.decryptedSummary.isEmpty {
                Divider().frame(height: 18)

                Button {
                    if let config = selectedLLMConfig {
                        viewModel.extractTodos(from: recording, llmConfig: config)
                    }
                } label: {
                    Label("拆解待办", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(
                    isReadOnly ||
                    selectedLLMConfig == nil ||
                    viewModel.isSummarizing ||
                    viewModel.isExtractingTodos
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 待办列表区域

    @ViewBuilder
    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                Text("待办事项")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if viewModel.isExtractingTodos {
                    ProgressView().controlSize(.small)
                    Text(viewModel.todoExtractionProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let doc = viewModel.currentTodoDocument {
                    let exportedCount = doc.items.filter { $0.status == .exported }.count
                    if exportedCount > 0 {
                        Text("已写入提醒事项 \(exportedCount)/\(doc.items.count)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                // 新增待办按钮（手动添加）
                if isProMode && !viewModel.isExtractingTodos && !viewModel.isWritingTodos {
                    Button {
                        editingTodoItem = nil
                        showTodoEdit = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("手动新增待办")
                    .accessibilityLabel(Text("手动新增待办"))
                    .disabled(isReadOnly)
                }

                // 写入提醒事项按钮
                if !viewModel.isExtractingTodos,
                   let doc = viewModel.currentTodoDocument,
                   !doc.items.isEmpty {
                    let hasPending = doc.items.contains { $0.status != .exported }
                    if hasPending {
                        Button {
                            Task {
                                await viewModel.writeTodosToReminders(
                                    recording: recording,
                                    defaultListID: defaultReminderListID
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if viewModel.isWritingTodos {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "list.bullet.rectangle.portrait")
                                }
                                Text(viewModel.isWritingTodos ? "写入中..." : "写入提醒事项")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .disabled(viewModel.isWritingTodos || isReadOnly)
                    }

                    // 清除待办（含已写入提醒事项的记录）
                    if isProMode {
                        Button {
                            // F-2: 通过确认对话框避免误删（含已写入提醒事项的记录）
                            showClearTodosConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("清除待办（同时从提醒事项中删除）")
                        .accessibilityLabel(Text("清除待办（同时从提醒事项中删除）"))
                        .disabled(viewModel.isWritingTodos || isReadOnly)
                        .confirmationDialog(
                            "确认清除所有待办？",
                            isPresented: $showClearTodosConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("清除所有待办", role: .destructive) {
                                viewModel.clearTodos(for: recording)
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将删除所有待办项，包括已写入系统提醒事项的记录。此操作不可撤销。")
                        }
                    }
                }
            }

            // 待办列表
            if let doc = viewModel.currentTodoDocument {
                VStack(spacing: 6) {
                    ForEach(doc.items) { item in
                        TodoItemRow(
                            item: item,
                            allowsEditing: isProMode && !isReadOnly,
                            onEdit: {
                                editingTodoItem = item
                                showTodoEdit = true
                            },
                            onDelete: {
                                viewModel.deleteTodoItem(item, for: recording)
                            }
                        )
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 写入状态提示
                let allExported = doc.items.allSatisfy { $0.status == .exported }
                if allExported && !doc.items.isEmpty {
                    Label("所有待办已写入提醒事项", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if doc.items.contains(where: { $0.status == .failed }) {
                    Label("部分待办写入失败，点击「写入提醒事项」重试", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !doc.items.isEmpty {
                    Text("生成于 \(doc.generatedAt, format: .dateTime.hour().minute()) · 模型 \(doc.model)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // 手动创建的待办文档不属于模型生成内容。
                    if doc.source != "manual" {
                        AIContentDisclaimer()
                    }
                }
            } else if isProMode && !viewModel.isExtractingTodos {
                // 空状态：无待办时提供手动新增入口
                Button {
                    editingTodoItem = nil
                    showTodoEdit = true
                } label: {
                    Label("手动新增待办", systemImage: "plus.circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 编辑模式操作栏

    private var editingActionBar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                isEditing = false
                editDraft = ""
            } label: {
                Label("取消", systemImage: "xmark")
            }
            .buttonStyle(.bordered)

            Button {
                saveSummaryEdit()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("保存")
                }
                .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 操作

    private func saveSummaryEdit() {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.updateRecordingSummary(recording, newSummary: trimmed, context: modelContext)
        isEditing = false
        editDraft = ""
    }

    private func generateSummary(asMeeting: Bool?) {
        guard let config = selectedLLMConfig else { return }
        viewModel.generateSummary(
            recording: recording,
            llmConfig: config,
            context: modelContext,
            asMeeting: asMeeting
        )
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        UIPasteboard.general.string = text
        */
        #endif
    }
}

// MARK: - 思考过程折叠展示

/// 推理型模型（Qwen3 / DeepSeek-R1 等）的「思考过程」折叠展示。
///
/// 三处总结（录音/会议总结、快捷笔记总结、画面要点）统一复用；默认折叠，仅在生成
/// 期间可见——调用方在生成收尾时会清空对应文本，因此结束后自然隐藏。思考内容只用于
/// 展示与诊断（推理型模型可能把输出预算耗在思考上导致正文为空），不参与总结内容。
struct ReasoningDisclosureView: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        if !text.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label("思考过程", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 待办项行视图

struct TodoItemRow: View {
    let item: TodoItem
    var allowsEditing: Bool = true
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 状态图标
            statusIcon

            // 内容区（点击进入编辑）
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isUserConfirmed ? String(localized: "已确认") : String(localized: "待核对"))
                    .font(.caption).foregroundStyle(.secondary)
                if let owner = item.owner { Text(verbatim: owner).font(.caption).foregroundStyle(.secondary) }
                if let quote = item.evidenceQuote { Text(verbatim: quote).font(.caption).textSelection(.enabled) }
                if let raw = item.sourceSeekURL, let url = URL(string: raw) {
                    Link("定位原文", destination: url).font(.caption)
                }
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.status == .exported, color: .secondary)

                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let url = item.url, !url.isEmpty, let parsedURL = URL(string: url) {
                    Link(destination: parsedURL) {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                            Text(url)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    }
                }

                if let due = item.dueDate {
                    HStack(spacing: 4) {
                        Text(due, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.orange)
                        if let offset = item.alarmOffsetMinutes, offset > 0 {
                            Text("· 提前 \(formatOffset(offset)) 提醒")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if allowsEditing { onEdit() }
            }

            Spacer()

            // 优先级标签（不设优先级时不显示）
            if item.priority != .none {
                Image(systemName: item.priority.iconName)
                    .foregroundStyle(priorityColor)
                    .font(.caption)
                    .help("优先级：\(item.priority.displayName)")
                    // 纯图标：VoiceOver 只会读到 SF Symbol 名
                    .accessibilityLabel(Text("优先级"))
            }

            // 删除按钮
            if allowsEditing {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red.opacity(0.7))
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("删除此待办")
                // .help 只提供鼠标 tooltip；补语义标签供 VoiceOver 使用
                .accessibilityLabel(Text("删除此待办"))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .exported:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.body)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.body)
        }
    }

    private var priorityColor: Color {
        switch item.priority {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        case .none:   return .secondary
        }
    }

    /// 格式化提前提醒偏移（单位文案走本地化，数字用系统格式化）
    private func formatOffset(_ minutes: Int) -> String {
        if minutes >= 1440 && minutes % 1440 == 0 {
            return String(format: String(localized: "%@ 天"), (minutes / 1440).formatted())
        } else if minutes >= 60 && minutes % 60 == 0 {
            return String(format: String(localized: "%@ 小时"), (minutes / 60).formatted())
        } else {
            return String(format: String(localized: "%@ 分钟"), minutes.formatted())
        }
    }
}

// MARK: - 待办编辑表单（新增 / 编辑共用）

extension DatePicker {
    /// 平台适配的日期选择器样式：macOS 用字段样式，iOS 用紧凑样式（.field 在 iOS 不可用）
    /// 标注 @MainActor：macOS 上 FieldDatePickerStyle.field 为 MainActor 隔离
    @MainActor
    func platformDatePickerStyle() -> some View {
        #if os(macOS)
        return self.datePickerStyle(.field)
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        return self.datePickerStyle(.compact)
        */
        #endif
    }
}

struct TodoItemEditView: View {
    @Binding var isPresented: Bool
    /// 传入已有 item 则为编辑模式，nil 为新增
    var initialItem: TodoItem?
    var onSave: (TodoItem) -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var url = ""
    @State private var hasDueDate = false
    /// 截止时间拆分：日期部分与时间部分分开选择，保存时合并
    @State private var dueDatePart = Date()
    @State private var dueTimePart = Date()
    /// 提前提醒默认勾选，提前 15 分钟
    @State private var hasEarlyReminder = true
    @State private var earlyReminderValue = 15
    @State private var earlyReminderUnit = EarlyReminderUnit.minute
    /// 优先级默认不设
    @State private var priority: TodoPriority = .none
    /// 目标提醒事项列表（空 = 跟随设置中的默认列表）
    @State private var targetListID = ""
    @State private var isUserConfirmed = false
    @ObservedObject private var remindersService = RemindersService.shared

    private var isEditing: Bool { initialItem != nil }

    /// 提前提醒单位
    private enum EarlyReminderUnit: String, CaseIterable, Identifiable {
        case minute = "分钟"
        case hour = "小时"
        case day = "天"
        var id: String { rawValue }

        /// 本地化显示名：rawValue 仅作稳定标识；Text(变量) 走 StringProtocol 重载按 verbatim 渲染，
        /// 既不查翻译表也无法被 Xcode 抽取，展示必须显式走 String(localized:) 列出字面量
        var localizedName: String {
            switch self {
            case .minute: return String(localized: "分钟")
            case .hour:   return String(localized: "小时")
            case .day:    return String(localized: "天")
            }
        }

        /// 转换为分钟数
        func toMinutes(_ value: Int) -> Int {
            switch self {
            case .minute: return value
            case .hour:   return value * 60
            case .day:    return value * 60 * 24
            }
        }

        /// 从分钟数反推最合适的单位和值
        static func from(minutes: Int) -> (value: Int, unit: EarlyReminderUnit) {
            if minutes >= 1440 && minutes % 1440 == 0 {
                return (minutes / 1440, .day)
            } else if minutes >= 60 && minutes % 60 == 0 {
                return (minutes / 60, .hour)
            } else {
                return (minutes, .minute)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 标题
                VStack(alignment: .leading, spacing: 6) {
                    Text("标题")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("待办标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // 备注
                VStack(alignment: .leading, spacing: 6) {
                    Text("备注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("负责人、来源等（可选）", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }

                // 相关链接
                VStack(alignment: .leading, spacing: 6) {
                    Text("相关链接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://（可选）", text: $url, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...2)
                        #if os(macOS)
                        .autocorrectionDisabled()
                        #endif
                }

                Toggle("我已核对待办内容、负责人和时间", isOn: $isUserConfirmed)
                if let quote = initialItem?.evidenceQuote { Text(verbatim: quote).font(.caption).textSelection(.enabled) }

                // 截止时间：拆分为日期、时间两个栏位
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("设置日期时间", isOn: $hasDueDate)
                        .font(.caption)
                    if hasDueDate {
                        HStack(spacing: 15) {
                            DatePicker(
                                "日期",
                                selection: $dueDatePart,
                                displayedComponents: .date
                            )
                            .platformDatePickerStyle()
                            .layoutPriority(1)

                            DatePicker(
                                "时间",
                                selection: $dueTimePart,
                                displayedComponents: .hourAndMinute
                            )
                            .platformDatePickerStyle()
                        }
                    }
                }

                // 提前提醒：常显（仅在有截止时间时生效），默认勾选提前 15 分钟
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("提前提醒", isOn: $hasEarlyReminder)
                        .font(.caption)
                    if hasEarlyReminder {
                        HStack(spacing: 8) {
                            TextField("提前", value: $earlyReminderValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Picker("单位", selection: $earlyReminderUnit) {
                                ForEach(EarlyReminderUnit.allCases) { u in
                                    Text(u.localizedName).tag(u)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            Text("提醒")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                // 优先级
                VStack(alignment: .leading, spacing: 6) {
                    Text("优先级")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("优先级", selection: $priority) {
                        ForEach(TodoPriority.allCases) { p in
                            Label(p.displayName, systemImage: p.iconName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 提醒事项列表：写入提醒事项时的目标列表，默认跟随设置中的默认列表
                VStack(alignment: .leading, spacing: 6) {
                    Text("提醒事项列表")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("提醒事项列表", selection: $targetListID) {
                        Text("默认列表").tag("")
                        ForEach(remindersService.availableLists, id: \.calendarIdentifier) { calendar in
                            Text(calendar.title).tag(calendar.calendarIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                // 操作按钮
                HStack {
                    Button("取消") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        save()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text(isEditing ? "保存" : "添加")
                        }
                        .fontWeight(.medium)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        // 最小尺寸而非固定尺寸：大字号 / 长文案下允许自适应增长，避免关键操作被截断
        .frame(minWidth: 430, minHeight: 480)
        .onAppear { loadInitial() }
        .task {
            remindersService.refreshAuthorizationStatus()
            if remindersService.isAuthorized {
                await remindersService.refreshAvailableLists()
            }
        }
    }

    /// 合并日期栏与时间栏为完整截止时间
    private var combinedDueDate: Date {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day], from: dueDatePart)
        let timeComps = calendar.dateComponents([.hour, .minute], from: dueTimePart)
        comps.hour = timeComps.hour
        comps.minute = timeComps.minute
        return calendar.date(from: comps) ?? dueDatePart
    }

    private func loadInitial() {
        if let item = initialItem {
            title = item.title
            isUserConfirmed = item.isUserConfirmed
            notes = item.notes ?? ""
            url = item.url ?? ""
            hasDueDate = item.dueDate != nil
            dueDatePart = item.dueDate ?? Date()
            dueTimePart = item.dueDate ?? Date()
            if let offset = item.alarmOffsetMinutes, offset > 0 {
                hasEarlyReminder = true
                let (v, u) = EarlyReminderUnit.from(minutes: offset)
                earlyReminderValue = v
                earlyReminderUnit = u
            } else {
                // 已有待办未设提醒：尊重原状态；新建时保持默认勾选 15 分钟
                hasEarlyReminder = false
            }
            priority = item.priority
            targetListID = item.targetListID ?? ""
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let alarmOffset: Int? = (hasDueDate && hasEarlyReminder && earlyReminderValue > 0)
            ? earlyReminderUnit.toMinutes(earlyReminderValue)
            : nil

        let item = TodoItem(
            id: initialItem?.id ?? UUID().uuidString,
            title: trimmedTitle,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            url: trimmedURL.isEmpty ? nil : trimmedURL,
            dueDate: hasDueDate ? combinedDueDate : nil,
            alarmOffsetMinutes: alarmOffset,
            priority: priority,
            reminderIdentifier: initialItem?.reminderIdentifier,
            status: initialItem?.status ?? .pending,
            targetListID: targetListID.isEmpty ? nil : targetListID,
            evidenceQuote: initialItem?.evidenceQuote,
            sourceSeekURL: initialItem?.sourceSeekURL,
            owner: initialItem?.owner,
            isUserConfirmed: isUserConfirmed
        )
        onSave(item)
        isPresented = false
    }
}
