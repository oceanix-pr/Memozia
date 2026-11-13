import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 词典设置视图
struct DictionarySettingsView: View {
    @Bindable var settingsVM: SettingsViewModel
    /// 全部录音（供“更新去标识化”逐条扫描转写记录）
    let recordings: [AudioRecording]
    private let dictionaryService = TranscriptDictionaryService.shared

    /// 本地模型列表（扫描仅允许本地模型，避免敏感信息上云）
    @Query private var llmConfigs: [LLMConfig]

    /// 正在编辑的词典文件（nil 表示未打开编辑器）
    @State private var editingFile: DictionaryFile?
    /// 新建词典编辑器
    @State private var showNewFileSheet = false
    /// 待确认删除的词典文件：删除的是磁盘上不可恢复的词表文件，需二次确认
    @State private var pendingDeleteFile: DictionaryFile?

    // 去标识化操作状态
    @State private var isScanningPII = false
    @State private var piiScanProgress = ""
    @State private var piiScanTask: Task<Void, Never>?
    /// 操作结果提示（声纹同步/扫描完成，nil 表示不显示）
    @State private var piiResultMessage: String?

    /// 扫描处理未脱敏原文，仅接受本地标记且使用本机回环端点的配置。
    private var localLLMConfig: LLMConfig? {
        llmConfigs.first { config in
            guard config.isLocal, let url = URL(string: config.baseURL) else { return false }
            return EndpointPolicy.trust(for: url) == .loopback
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settingsVM.enableDictionaryCorrection) {
                    Label("转写后应用词典纠正", systemImage: "character.book.closed")
                }
                Text("转写完成后自动纠正专有名词误写：读音与词典术语相同的片段会被替换为词典写法（如“语义识别”→“语音识别”）；也可用表格/箭头格式做精确替换。对已完成的转写不生效，重新转写后应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("功能")
            }

            Section {
                Toggle(isOn: $settingsVM.enablePIIScrub) {
                    Label("云端处理前去标识化", systemImage: "lock.shield")
                }
                Button {
                    let added = PIIScrubService.syncFromVoiceprints()
                    piiResultMessage = added > 0
                        ? String(format: String(localized: "已从声纹库新增 %lld 个人员姓名。"), added)
                        : String(localized: "声纹库中的姓名均已在词典中，无需新增。")
                } label: {
                    Label("从声纹同步", systemImage: "waveform")
                }
                Button {
                    startPIIScan()
                } label: {
                    if isScanningPII {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(piiScanProgress)
                        }
                    } else {
                        Label("更新去标识化", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .disabled(isScanningPII || localLLMConfig == nil)
                .help(localLLMConfig == nil
                      ? String(localized: "去标识化扫描仅允许本机回环地址（localhost、127.0.0.1 或 ::1），不会因模型标记为本地而放行内网或公网地址。")
                      : String(localized: "用本地大模型逐条分析全部转写记录，提取敏感词写入词典"))
                Text("去标识化扫描仅允许本机回环地址（localhost、127.0.0.1 或 ::1），不会因模型标记为本地而放行内网或公网地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("去标识化")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("词典文件夹")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(dictionaryService.folderURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.open(dictionaryService.folderURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中打开词典文件夹")
                    .accessibilityLabel(Text("在 Finder 中打开词典文件夹"))
                    #endif
                }

                ForEach(dictionaryService.files) { file in
                    Button {
                        editingFile = file
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if let modified = file.modifiedAt {
                                    Text(modified, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(file.termCount) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeleteFile = file
                        } label: {
                            Label("删除词典", systemImage: "trash")
                        }
                    }
                    .confirmationDialog(
                        "删除词典",
                        isPresented: Binding(
                            get: { pendingDeleteFile != nil },
                            set: { if !$0 { pendingDeleteFile = nil } }
                        ),
                        presenting: pendingDeleteFile
                    ) { target in
                        Button("删除", role: .destructive) {
                            dictionaryService.delete(target)
                        }
                        Button("取消", role: .cancel) { }
                    }
                }

                Button {
                    showNewFileSheet = true
                } label: {
                    Label("新建词典", systemImage: "plus")
                }

                if !dictionaryService.files.isEmpty {
                    Text("共 \(dictionaryService.files.count) 个词典文件，\(dictionaryService.totalTermCount) 条术语。词典为 Markdown 格式：每行一条，支持 “- 术语”（拼音自动纠正）、“| 错误词 | 正确词 |” 与 “错误词 -> 正确词”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("词典文件")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("词典")
        .onAppear {
            dictionaryService.reload()
        }
        .sheet(item: $editingFile) { file in
            DictionaryFileEditorView(file: file)
        }
        .sheet(isPresented: $showNewFileSheet) {
            DictionaryFileEditorView(file: nil)
        }
        .alert(
            String(localized: "去标识化"),
            isPresented: Binding(
                get: { piiResultMessage != nil },
                set: { if !$0 { piiResultMessage = nil } }
            )
        ) {
            Button("确定") { piiResultMessage = nil }
        } message: {
            Text(piiResultMessage ?? "")
        }
        .onDisappear {
            // 离开页面时中止未完成的扫描，避免后台持续占用本地模型
            piiScanTask?.cancel()
        }
    }

    /// 更新去标识化：用本地大模型逐条分析全部已完成转写的录音，
    /// 提取敏感词（带 #去标识化 标记）写入词典；单条失败不中断整体扫描
    private func startPIIScan() {
        guard let config = localLLMConfig else { return }
        piiScanTask?.cancel()
        isScanningPII = true
        piiScanTask = Task { @MainActor in
            defer { isScanningPII = false }
            do {
                let snapshot = try LLMConfigSnapshot(config: config)
                let completed = recordings.filter { $0.transcriptionStatus == .completed }
                guard !completed.isEmpty else {
                    piiResultMessage = String(localized: "没有已完成转写的录音，无法扫描。")
                    return
                }
                var collected: [(text: String, category: PIICategory)] = []
                var seen = Set<String>()
                for (index, recording) in completed.enumerated() {
                    if Task.isCancelled { return }
                    piiScanProgress = String(
                        format: String(localized: "正在用本地模型分析（%lld/%lld）…"),
                        index + 1, completed.count)
                    let text = recording.transcriptMarkdown
                    guard !text.isEmpty else { continue }
                    // 单条失败（模型未启动/超时等）仅跳过，不中断整体扫描
                    let items = (try? await PIIScanService.extract(from: text, config: snapshot)) ?? []
                    for item in items where seen.insert(item.text).inserted {
                        collected.append((item.text, item.category))
                    }
                }
                if Task.isCancelled { return }
                let added = dictionaryService.addPIIEntries(collected)
                piiResultMessage = String(
                    format: String(localized: "扫描完成，新增 %lld 条去标识化词条。"), added)
            } catch {
                piiResultMessage = String(localized: "扫描启动失败，请检查本地模型配置。")
            }
        }
    }
}


// MARK: - 词典文件编辑视图
struct DictionaryFileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// 待编辑的词典文件（nil 表示新建）
    let file: DictionaryFile?
    private let dictionaryService = TranscriptDictionaryService.shared

    @State private var fileName: String
    @State private var content: String
    @State private var showSaveError = false

    init(file: DictionaryFile?) {
        self.file = file
        // 注意：不能在属性未初始化完成时通过 self 访问 dictionaryService（闭包捕获 self 报错），
        // 这里直接使用单例
        let initialContent: String
        if let file {
            initialContent = TranscriptDictionaryService.shared.content(of: file)
        } else {
            initialContent = "# 词典\n\n- \(String(localized: "术语一"))\n- \(String(localized: "术语二"))\n"
        }
        _fileName = State(initialValue: file?.fileName ?? "新词典")
        _content = State(initialValue: initialContent)
    }

    /// 当前内容的条目数预览（含去标识化条目，与词典列表计数口径一致）
    private var previewTermCount: Int {
        TranscriptDictionaryService.countEntries(in: content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("词典名称", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 260)
                } header: {
                    Text("内容（Markdown）")
                } footer: {
                    Text("每行一条，三种写法：\n- 术语　（按拼音自动纠正，无需知道错误写法）\n| 错误词 | 正确词 |　（精确替换）\n错误词 -> 正确词　（精确替换）\n当前共 \(previewTermCount) 条有效条目。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(file == nil ? "新建词典" : "编辑词典")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if dictionaryService.save(fileName: fileName, content: content) {
                            dismiss()
                        } else {
                            showSaveError = true
                        }
                    }
                    .disabled(fileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("保存失败", isPresented: $showSaveError) {
                Button("确定") {}
            } message: {
                Text("无法写入词典文件，请检查文件夹权限。")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }
}
