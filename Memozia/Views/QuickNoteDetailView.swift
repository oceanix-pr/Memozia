import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

/// 快捷笔记详情视图
struct QuickNoteDetailView: View {
    let quickNote: QuickNote
    @Bindable var viewModel: QuickNoteViewModel
    let llmConfigs: [LLMConfig]
    @Binding var selectedLLMConfig: LLMConfig?
    var defaultReminderListID: String
    var isProMode: Bool = true
    /// 一键处理（概要总结 → 拆解待办），由宿主投递到处理队列
    var onOneClick: (() -> Void)? = nil
    var onCleanupImage: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @AppStorage(MenuBarController.appLanguageDefaultsKey) private var interfaceLanguage = ""
    @State private var systemLanguages = NoteSpeechAvailability.systemPreferredLanguages
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    /// 临时模式（不落盘）：禁用全部编辑入口，只保留浏览、复制与导出
    private var isReadOnly: Bool { viewModel.persistence.capability.isTransient }

    private var supportsNoteSpeech: Bool {
        NoteSpeechAvailability.isSupported(interfaceLanguage: interfaceLanguage, systemLanguages: systemLanguages)
    }

    // 待办编辑 Sheet 状态
    @State private var showTodoEdit = false
    @State private var editingTodoItem: TodoItem?

    // F-2: 清除待办确认对话框状态
    @State private var showClearTodosConfirmation = false

    // 总结编辑状态
    @State private var isEditingSummary = false
    @State private var summaryDraft = ""
    /// 流式「思考过程」折叠态（默认折叠，仅生成期间可见）
    @State private var isReasoningExpanded = false

    // 文字内容编辑状态（截图/文字笔记正文重新编辑）
    @State private var isEditingText = false
    @State private var textDraft = ""
    @State private var speechInput: SpeechNoteInput?

    // 图片缩放状态
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var showImageFullscreen = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerBar

            if !quickNote.isImageNote && supportsNoteSpeech {
                HStack {
                    Spacer()
                    Button {
                        guard supportsNoteSpeech else { return }
                        speechInput = SpeechNoteInput(title: quickNote.title,
                            body: quickNote.decryptedTextContent, summary: quickNote.decryptedSummaryText)
                    } label: {
                        Label("转为语音", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isEditingText || isEditingSummary ||
                        ((quickNote.textContent ?? "").isEmpty && (quickNote.summaryText ?? "").isEmpty))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // 内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 文字内容
                    if !quickNote.decryptedTextContent.isEmpty {
                        textContentSection
                    }

                    // 图片内容
                    if quickNote.hasImage, let imageURL = quickNote.sourceImageURL {
                        imageSection(url: imageURL)
                    } else if quickNote.isImageNote {
                        Label("图片原件已清理，文字、OCR、总结与待办已保留。", systemImage: "photo")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !quickNote.decryptedOcrText.isEmpty {
                        Text(quickNote.decryptedOcrText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // AI 总结区域
                    Divider()
                    summarySection

                    // 待办列表区域
                    Divider()
                    todoSection
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            viewModel.loadTodoDocument(for: quickNote)
            viewModel.loadSummary(for: quickNote)
        }
        .onChange(of: quickNote.id) { _, _ in
            viewModel.loadTodoDocument(for: quickNote)
            viewModel.loadSummary(for: quickNote)
        }
        .onChange(of: quickNote.sourceImageFileName) { _, _ in
            showImageFullscreen = false
        }
        .onChange(of: supportsNoteSpeech) { _, supported in
            if !supported { speechInput = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            systemLanguages = NoteSpeechAvailability.systemPreferredLanguages
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .screenshotReannotated)) { notification in
            handleReannotated(notification)
        }
        #endif
        .sheet(isPresented: $showTodoEdit) {
            TodoItemEditView(
                isPresented: $showTodoEdit,
                initialItem: editingTodoItem,
                onSave: { item in
                    if editingTodoItem != nil {
                        viewModel.updateTodoItem(item, for: quickNote)
                    } else {
                        viewModel.addTodoItem(item, for: quickNote)
                    }
                    editingTodoItem = nil
                }
            )
        }
        .sheet(item: $speechInput) { input in
            NoteSpeechView(input: input)
        }
    }

    // MARK: - 重新标注

    #if os(macOS)
    /// 启动重新标注：读取当前图片 → 交给 ScreenshotManager 进入标注界面
    private func startReannotate() {
        guard quickNote.hasImage,
              let imageURL = quickNote.sourceImageURL,
              let imageData = try? Data(contentsOf: imageURL) else {
            viewModel.errorMessage = String(localized: "无法加载图片文件")
            viewModel.showError = true
            return
        }
        ScreenshotManager.shared.reannotate(imageData: imageData)
    }

    /// 接收重新标注结果，覆盖保存到当前笔记
    private func handleReannotated(_ notification: Notification) {
        guard let markedPNG = (notification.userInfo?["markedPNG"] as? ScreenshotPayloadBox)?.data else { return }
        guard let url = quickNote.sourceImageURL else { return }
        do {
            try markedPNG.write(to: url, options: .atomic)
            // 触发视图刷新（通过 objectWillChange）
            viewModel.selectedQuickNote = quickNote
        } catch {
            viewModel.errorMessage = String(localized: "保存标注图片失败: \(UserFacingError.summary(for: error))")
            viewModel.showError = true
        }
    }
    #endif

    // MARK: - 标题栏

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            // 图片笔记橙色、文字笔记紫色，与列表行标识一致
            Image(systemName: quickNote.isImageNote ? "photo.fill" : "text.bubble.fill")
                .foregroundStyle(quickNote.isImageNote ? Color.orange : .purple)
                .font(.title3)

            if isEditingTitle {
                TextField("标题", text: $titleDraft, onCommit: commitTitle)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .focused($titleFieldFocused)
                    .onAppear { titleFieldFocused = true }
            } else {
                Text(quickNote.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .onTapGesture(count: 2) {
                        guard !isReadOnly else { return }
                        titleDraft = quickNote.title
                        isEditingTitle = true
                    }
            }

            Spacer()

            // LLM 配置选择
            if isProMode && !llmConfigs.isEmpty {
                Picker("模型", selection: $selectedLLMConfig) {
                    Text("选择模型").tag(nil as LLMConfig?)
                    ForEach(llmConfigs, id: \.id) { config in
                        Text(config.name).tag(config as LLMConfig?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            // 重新标注按钮（仅图片笔记显示）
            #if os(macOS)
            if isProMode && quickNote.hasImage {
                if let onCleanupImage {
                    Button(role: .destructive, action: onCleanupImage) {
                        Label("清理图片", systemImage: "trash.slash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly || MediaCleanupService.shared.isRunning || !ScreenshotManager.shared.isIdle)
                }
                Button {
                    startReannotate()
                } label: {
                    Label("重新标注", systemImage: "pencil.and.scribble")
                }
                .buttonStyle(.bordered)
                .disabled(ScreenshotManager.shared.isIdle == false || isReadOnly)
                .help("重新编辑标注")
            }
            #endif

            // 生成总结按钮
            Button {
                if let config = selectedLLMConfig {
                    viewModel.generateSummary(for: quickNote, llmConfig: config, context: modelContext)
                }
            } label: {
                Label("生成总结", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(
                selectedLLMConfig == nil ||
                viewModel.isGeneratingSummary ||
                isReadOnly
            )

            // 拆解待办按钮
            Button {
                if let config = selectedLLMConfig {
                    viewModel.extractTodos(from: quickNote, llmConfig: config, context: modelContext)
                }
            } label: {
                Label("拆解待办", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(
                selectedLLMConfig == nil ||
                viewModel.isExtractingTodos ||
                isReadOnly
            )

            // 一键处理：概要总结 → 拆解待办（投递到处理队列串行执行）
            if let onOneClick {
                Button {
                    onOneClick()
                } label: {
                    Label("一键处理", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .help("一键处理：概要总结 → 拆解待办")
                .disabled(isReadOnly)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - 文字内容

    @ViewBuilder
    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("文字内容", systemImage: "text.alignleft")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if isEditingText {
                    // 取消在保存左侧，二者一起居右（与总结/转写编辑态一致）
                    Button("取消") {
                        isEditingText = false
                        textDraft = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("保存") {
                        saveTextEdit()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button {
                        textDraft = quickNote.decryptedTextContent
                        isEditingText = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("重新编辑文字内容")
                    .disabled(isReadOnly)
                }
            }

            if isEditingText {
                // 固定高度：页面为整体滚动结构，框内自行滚动；
                // 编辑/替换内容时编辑框高度保持不变（与总结编辑一致）
                TextEditor(text: $textDraft)
                    .font(.body)
                    .frame(height: 240)
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // 编辑模式查找（⌘F）/替换（⌘R）支持
                    .textFindReplace(text: $textDraft)
            } else {
                Text(quickNote.decryptedTextContent)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - 图片内容

    @ViewBuilder
    private func imageSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("图片内容", systemImage: "photo")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                // 缩放控制
                Button {
                    withAnimation { imageScale = max(imageScale - 0.25, 0.5) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("缩小")
                .accessibilityLabel(Text("缩小"))

                // 百分比用 FormatStyle 格式化，避免字符串拼接 "%%" 触发本地化警告
                Text(Double(imageScale).formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)

                Button {
                    withAnimation { imageScale = min(imageScale + 0.25, 4.0) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("放大")
                .accessibilityLabel(Text("放大"))

                Button {
                    withAnimation {
                        imageScale = 1.0
                        imageOffset = .zero
                    }
                } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("重置缩放")
                .accessibilityLabel(Text("重置缩放"))

                Button {
                    showImageFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("全屏查看")
                .accessibilityLabel(Text("全屏查看"))
            }

            #if os(macOS)
            if let nsImage = loadNoteImage(at: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .scaleEffect(imageScale)
                    .offset(imageOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                imageOffset = value.translation
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if imageScale > 1.0 {
                                imageScale = 1.0
                                imageOffset = .zero
                            } else {
                                imageScale = 2.0
                            }
                        }
                    }
                    .cornerRadius(8)
                    .shadow(radius: 2)
                    .frame(maxHeight: 500)
                    .clipped()
            } else {
                ContentUnavailableView("图片加载失败", systemImage: "photo.bad")
            }
            #endif
        }
        .sheet(isPresented: $showImageFullscreen) {
            #if os(macOS)
            FullscreenImageView(url: url) {
                showImageFullscreen = false
            }
            #endif
        }
    }

    // MARK: - AI 总结区域

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                Text("总结")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                if viewModel.isGeneratingSummary {
                    ProgressView().controlSize(.small)
                    Text("AI 生成中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let date = quickNote.summaryGeneratedAt {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                SummaryHistoryButton(folder: quickNote.folderURL)
                if !viewModel.summaryText.isEmpty && !isEditingSummary {
                    // 一键复制完整总结：Markdown 按块渲染后拖选无法跨块，整段复制改走按钮
                    Button {
                        copyToClipboard(viewModel.summaryText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制总结")
                    .accessibilityLabel(Text("复制总结"))

                    Button {
                        summaryDraft = viewModel.summaryText
                        isEditingSummary = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("编辑总结")
                    .accessibilityLabel(Text("编辑总结"))
                    .disabled(isReadOnly)
                }

                if isEditingSummary {
                    // 取消在保存左侧，二者一起居右（与转写/文字内容编辑态一致）
                    Button("取消") {
                        isEditingSummary = false
                        summaryDraft = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("保存") {
                        // 保存失败时保留草稿与编辑态，避免用户输入丢失
                        if viewModel.updateSummary(summaryDraft, for: quickNote, context: modelContext) {
                            isEditingSummary = false
                            summaryDraft = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if isEditingSummary {
                TextEditor(text: $summaryDraft)
                    .font(.body)
                    // 固定高度：页面为整体滚动结构，框内自行滚动；
                    // 替换/全部替换改动内容时编辑框高度保持不变
                    .frame(height: 240)
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // 编辑模式查找（⌘F）/替换（⌘R）支持
                    .textFindReplace(text: $summaryDraft)
            } else if viewModel.isGeneratingSummary {
                VStack(alignment: .leading, spacing: 8) {
                    // 推理型模型的思考过程：默认折叠，仅生成期间可见
                    ReasoningDisclosureView(
                        text: viewModel.summaryReasoningText,
                        isExpanded: $isReasoningExpanded
                    )
                    if !viewModel.summaryText.isEmpty {
                        // 流式内容合批在后台解析，生成期间也展示 Markdown。
                        StreamingMarkdownView(markdown: viewModel.summaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("正在生成总结...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !viewModel.summaryText.isEmpty || !viewModel.summaryReasoningText.isEmpty {
                        AIContentDisclaimer()
                    }
                }
            } else if !viewModel.summaryText.isEmpty {
                // 已保存的总结用 Markdown 渲染（标题/列表/粗体/代码等）
                MarkdownView(markdown: viewModel.summaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // 图片笔记的总结同样由模型生成，提示与录音总结保持一致
                AIContentDisclaimer()
            } else {
                Text("点击「生成总结」按钮，AI 将自动分析笔记内容并生成概要总结")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 保存重新编辑的文字内容（含截图笔记 OCR 文本与纯文字笔记正文）
    private func saveTextEdit() {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 保存失败（加密/磁盘/数据库）时保留草稿并维持编辑态，避免用户输入丢失
        guard viewModel.updateTextContent(trimmed, for: quickNote, context: modelContext) else { return }
        isEditingText = false
        textDraft = ""
    }

    /// 复制文本到系统剪贴板（与其余视图的 copyToClipboard 保持一致）
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
                                    note: quickNote,
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
                        .disabled(viewModel.isWritingTodos)
                    }

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
                        .disabled(viewModel.isWritingTodos)
                        .confirmationDialog(
                            "确认清除所有待办？",
                            isPresented: $showClearTodosConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("清除所有待办", role: .destructive) {
                                viewModel.clearTodos(for: quickNote)
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
                                viewModel.deleteTodoItem(item, for: quickNote)
                            }
                        )
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

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

    // MARK: - 标题编辑

    private func commitTitle() {
        guard !isReadOnly else {
            isEditingTitle = false
            titleFieldFocused = false
            return
        }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != quickNote.title {
            viewModel.updateTitle(quickNote, newTitle: trimmed, context: modelContext)
        }
        isEditingTitle = false
        titleFieldFocused = false
    }
}

// MARK: - 全屏图片查看

#if os(macOS)

/// 笔记图片加载辅助（缩放/拖拽手势会触发 body 频繁重算，
/// 直接 NSImage(contentsOf:) 会导致同一张图每帧重复解码）
private final class NoteImageCacheBox: @unchecked Sendable {
    /// 按 URL 缓存解码结果：body 重算时命中缓存，避免重复解码；
    /// NSCache 在内存压力下自动驱逐
    let cache = NSCache<NSURL, NSImage>()
    init() {
        // 解码位图缓存上限 128MB（cost = 位图字节数估算）
        cache.totalCostLimit = 128 * 1024 * 1024
    }
}

private let noteImageCacheBox = NoteImageCacheBox()

/// 加载笔记图片：小图（≤10MB）保持原逻辑直接加载；
/// 大图（>10MB，通常是超高分辨率截图）用 CGImageSource 降采样到最大边 4096px，
/// 避免全尺寸解码造成内存峰值过高
private func loadNoteImage(at url: URL) -> NSImage? {
    if let cached = noteImageCacheBox.cache.object(forKey: url as NSURL) {
        return cached
    }

    let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0

    // 超过 10MB 才降采样，小图原样直出
    let image: NSImage?
    if fileSize > 10 * 1024 * 1024 {
        image = downsampledImage(at: url, maxPixelSize: 4096)
            ?? NSImage(contentsOf: url) // 降采样失败时回退原逻辑
    } else {
        image = NSImage(contentsOf: url)
    }

    if let image {
        let bitmapBytes = Int(image.size.width * image.size.height) * 4
        noteImageCacheBox.cache.setObject(image, forKey: url as NSURL, cost: bitmapBytes)
    }
    return image
}

/// CGImageSource 降采样：只解码目标尺寸，内存占用与 MaxPixelSize 挂钩而非原图分辨率
private func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
}

struct FullscreenImageView: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let nsImage = loadNoteImage(at: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = value.translation
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                    }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .accessibilityLabel("关闭")
                }
                Spacer()
            }
        }
        // 关闭只走按钮与 Esc：旧实现在整个 ZStack 上挂单击关闭，会与图片的双击缩放
        // 抢手势（双击时先触发一次单击直接关闭，缩放基本用不了）
        .onExitCommand { onClose() }
    }
}
#endif
