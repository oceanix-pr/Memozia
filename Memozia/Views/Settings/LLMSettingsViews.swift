import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

private let settingsLogger = Logger(subsystem: "app.memozia", category: "Settings")

// MARK: - LLM 配置行视图
struct LLMConfigRowView: View {
    let config: LLMConfig
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.subheadline)
                // 纯装饰：选中态由整行的 .isSelected 语义传达，避免 VoiceOver 读成 SF Symbol 名
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(config.name).font(.subheadline).fontWeight(.medium)
                    Image(systemName: config.isLocal ? "house.fill" : "cloud.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(config.modelName) · \(config.baseURL)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            // 纯图标按钮：VoiceOver 只会读到 SF Symbol 名，需显式语义标签
            Button { onEdit() } label: {
                Image(systemName: "pencil.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("编辑配置"))

            // 显式删除入口（macOS 上滑动删除不易发现），实际删除前会弹确认
            Button { onDelete() } label: {
                Image(systemName: "trash.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("删除"))
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button { onEdit() } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
        // 选中态不能只靠实心/空心配色：以容器元素承载 .isSelected 供 VoiceOver 播报
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // 点击选中原本不暴露为无障碍动作，补一个命名动作供 VoiceOver 用户切换活动配置
        .accessibilityAction(named: Text("选择")) { onSelect() }
    }
}


// MARK: - 模型下拉选择器

/// 模型选择控件：内置建议清单 + 「从服务获取」实时清单 + 手动输入兜底。
/// 两种体验模式共用，避免模型清单与获取逻辑在两处各自漂移。
///
/// 只绑定 `modelName` 这一路可变状态（通常是编辑器的草稿 Binding），
/// 端点/本地标记/API Key 都是只读入参——控件本身不持有也不回写持久化模型。
struct LLMModelPickerView: View {
    @Binding var modelName: String
    /// 端点只读值：用于「从服务获取」与端点反查
    let baseURL: String
    /// 是否本地模型：决定明文 HTTP 是否放行
    let isLocal: Bool
    /// 当前服务商的建议模型清单；空表示未知服务商，只能手动输入
    let suggestedModels: [String]
    /// 刚输入但尚未保存的 API Key。不带上的话，用户「填了 Key 点获取仍 401」很难理解
    var apiKeyOverride: String?
    /// 专业模式保留直接编辑模型名；普通模式只给下拉加「其他」兜底
    var showsFreeText: Bool = false
    var allowInsecureLAN: Bool = false

    /// 下拉里代表「手动输入」的哨兵值，不会作为模型名提交
    private static let customOption = "__Memozia_custom_model__"

    @State private var selection: String = ""
    @State private var customName: String = ""
    @State private var fetchedModels: [String] = []
    @State private var isFetching = false
    @State private var message: String?

    /// 实时清单优先（服务商模型迭代快），没有则回退到内置建议
    private var options: [String] {
        fetchedModels.isEmpty ? suggestedModels : fetchedModels
    }

    var body: some View {
        Group {
            if showsFreeText || options.isEmpty {
                TextField("模型名称", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                if !options.isEmpty {
                    Menu {
                        ForEach(options, id: \.self) { name in
                            Button(name) { modelName = name }
                        }
                    } label: {
                        Label("从建议清单选择", systemImage: "list.bullet")
                    }
                }
            } else {
                Picker("模型", selection: $selection) {
                    ForEach(options, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Text("其他（手动输入）").tag(Self.customOption)
                }
                if selection == Self.customOption {
                    TextField("模型名称", text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            fetchButton

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: syncFromConfig)
        .onChange(of: selection) { _, newValue in
            // 选到「其他」时不动模型名，交给下面的文本框驱动
            if newValue != Self.customOption { modelName = newValue }
        }
        .onChange(of: customName) { _, newValue in
            if selection == Self.customOption { modelName = newValue }
        }
    }

    private var fetchButton: some View {
        Button {
            Task { await fetchModels() }
        } label: {
            if isFetching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在获取模型列表…")
                }
            } else {
                Label("从服务获取模型列表", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(isFetching)
    }

    /// 把已保存的模型名对齐到下拉的两种状态：命中清单就选中它，否则落到「其他」
    private func syncFromConfig() {
        let list = options
        if list.isEmpty || list.contains(modelName) {
            selection = list.isEmpty ? Self.customOption : modelName
            customName = ""
        } else {
            selection = Self.customOption
            customName = modelName
        }
    }

    /// 拉取服务端模型清单。失败只提示，不改动已保存的配置：
    /// 网络不通或端点不支持时，用户仍可手动填模型名继续使用
    private func fetchModels() async {
        isFetching = true
        message = nil
        defer { isFetching = false }

        // 优先用编辑器里刚输入、尚未保存的 Key；没有就按「无 Key」请求
        let key = apiKeyOverride ?? ""
        do {
            let models = try await LLMService.fetchAvailableModels(
                baseURL: baseURL,
                apiKey: key,
                isLocal: isLocal,
                allowInsecureLAN: allowInsecureLAN
            )
            fetchedModels = models
            // 拿到权威清单后重新对齐选择状态
            selection = models.contains(modelName) ? modelName : Self.customOption
            if selection == Self.customOption { customName = modelName }
            message = String(format: String(localized: "已获取 %d 个可用模型。"), models.count)
        } catch {
            message = String(format: String(localized: "获取模型列表失败：%@"), error.localizedDescription)
        }
    }
}


// MARK: - LLM 配置编辑目标

/// 编辑器打开目标：区分「新建」（只有草稿，尚未入库）与「编辑已有」（持久化对象）。
/// 每次打开生成新的 `id`，保证 sheet 身份唯一；取消时草稿直接丢弃，
/// 数据库与 Keychain 都不会被改动。
struct LLMConfigEditTarget: Identifiable {
    enum Kind {
        case new(LLMConfigDraft)
        case existing(LLMConfig)
    }

    let id = UUID()
    let kind: Kind
    /// 保存成功后是否把该配置设为当前激活（供「快捷添加/选择服务商」入口使用）：
    /// 编辑已有配置时保持原激活态不动
    var activatesOnSave = false

    static func new(_ draft: LLMConfigDraft, activatesOnSave: Bool = false) -> LLMConfigEditTarget {
        LLMConfigEditTarget(kind: .new(draft), activatesOnSave: activatesOnSave)
    }

    static func existing(_ config: LLMConfig) -> LLMConfigEditTarget {
        LLMConfigEditTarget(kind: .existing(config))
    }
}


// MARK: - LLM 配置编辑视图
struct LLMConfigEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: LLMConfigEditTarget
    var simplified = false
    /// 保存成功后的回调（取消不会触发），例如把新配置设为激活
    var onSaved: ((LLMConfig) -> Void)?

    /// 编辑器只改草稿：取消 = 丢弃草稿，数据库与 Keychain 都不动
    @State private var draft: LLMConfigDraft
    @State private var errorMessage: String?
    @State private var showError = false

    init(target: LLMConfigEditTarget, simplified: Bool = false, onSaved: ((LLMConfig) -> Void)? = nil) {
        self.target = target
        self.simplified = simplified
        self.onSaved = onSaved
        switch target.kind {
        case .existing(let config):
            _draft = State(initialValue: LLMConfigDraft(from: config))
        case .new(let newDraft):
            _draft = State(initialValue: newDraft)
        }
    }

    /// 由端点反查服务商：决定下拉给哪些模型。反查不到就只给手动输入，不猜
    private var preset: LLMPreset? { LLMPreset.matching(baseURL: draft.baseURL) }

    var body: some View {
        NavigationStack {
            Form {
                if simplified {
                    Section {
                        SecureField("API Key", text: $draft.apiKey)
                            .textFieldStyle(.roundedBorder)
                        if preset?.requiresAPIKey == false {
                            Text("该服务通常无需 API Key，可以留空。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(draft.name)
                    } footer: {
                        Text("API Key 只保存在本机钥匙串中，不会写入设置文件或日志。")
                    }

                    Section {
                        LLMModelPickerView(
                            modelName: $draft.modelName,
                            baseURL: draft.baseURL,
                            isLocal: draft.isLocal,
                            suggestedModels: preset?.suggestedModels ?? [],
                            apiKeyOverride: draft.apiKey,
                            allowInsecureLAN: draft.allowInsecureLAN
                        )
                    } footer: {
                        Text("模型名称会随服务商更新。列表里没有想要的模型时可选择「其他」手动填写，或点「从服务获取」读取该账号实际可用的模型。")
                    }

                    Section {
                        DisclosureGroup("高级选项") {
                            TextField("Base URL", text: $draft.baseURL)
                                .textFieldStyle(.roundedBorder)
                            Toggle("支持视觉（图片输入）", isOn: $draft.supportsVision)
                            if let endpoint = LLMConfig.endpointURL(forBaseURL: draft.baseURL, appending: "chat/completions")?.absoluteString {
                                Text("实际请求：\(endpoint)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Section("基本信息") {
                        TextField("名称", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                        Toggle("本地模型", isOn: $draft.isLocal)
                        Toggle("支持视觉（图片输入）", isOn: $draft.supportsVision)
                            .help("开启后，快捷笔记中的图片将直接发送给此模型进行待办拆解；否则使用本地 Vision OCR 识别文字后再拆解")
                    }

                    Section("连接设置") {
                        TextField("Base URL", text: $draft.baseURL)
                            .textFieldStyle(.roundedBorder)

                        SecureField("API Key（本地可为空）", text: $draft.apiKey)
                            .textFieldStyle(.roundedBorder)

                        LLMModelPickerView(
                            modelName: $draft.modelName,
                            baseURL: draft.baseURL,
                            isLocal: draft.isLocal,
                            suggestedModels: preset?.suggestedModels ?? [],
                            apiKeyOverride: draft.apiKey,
                            allowInsecureLAN: draft.allowInsecureLAN
                        )
                    }

                    Section {
                        Text("示例：\n• LM Studio: http://localhost:1234\n• Ollama: http://localhost:11434\n• OpenAI: https://api.openai.com")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("允许内网地址使用明文 HTTP", isOn: $draft.allowInsecureLAN)
                    Toggle("也对本机回环服务的文本脱敏", isOn: $draft.scrubLoopbackText)
                    Text("内网 HTTP 会明文传输内容和 API Key，仅支持可信的私有 IPv4 地址。公网必须使用 HTTPS；远端文本脱敏与本地模型标记无关。图片和视频帧不做文本脱敏。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .onChange(of: draft.baseURL) { _, _ in
                // Consent belongs to the endpoint being edited, not to any future address.
                draft.allowInsecureLAN = false
            }
            .navigationTitle(simplified ? "连接智能服务" : "编辑配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 400)
        #endif
    }

    /// 保存：本地校验 → 写 Keychain → 更新/插入模型 → save → 成功才 dismiss。
    ///
    /// Keychain 与 SwiftData 无法原子提交：写 Keychain 前先记下旧值，
    /// 若模型保存失败就尽力恢复旧值；恢复失败必须明确报错，不能静默。
    /// 日志只记错误类别，绝不包含 API Key。
    private func save() {
        do {
            try draft.validate()
        } catch {
            presentError(error.localizedDescription)
            return
        }

        let isNew: Bool
        let config: LLMConfig
        /// 编辑已有配置时用于回滚的模型字段快照（不含 Key）
        var rollbackSnapshot: LLMConfigDraft?
        switch target.kind {
        case .existing(let existing):
            config = existing
            isNew = false
            rollbackSnapshot = LLMConfigDraft(from: existing)
        case .new:
            config = LLMConfig(
                name: draft.name,
                baseURL: draft.baseURL,
                modelName: draft.modelName,
                isLocal: draft.isLocal,
                supportsVision: draft.supportsVision
            )
            // 沿用草稿预分配的身份：Keychain 条目与即将入库的记录共用同一 id
            config.id = draft.id
            isNew = true
        }

        // 写 Keychain 前先记下旧值用于回滚。读失败不阻塞保存，
        // 但必须留痕：此时回滚只能退化为删除本次写入
        let previousKey: String?
        do {
            previousKey = try LLMKeychainStore.readAPIKey(for: config.id)
        } catch {
            settingsLogger.error("保存 LLM 配置：读取钥匙串旧值失败（\(String(describing: error))）")
            previousKey = nil
        }
        let trimmedKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmedKey.isEmpty {
                try LLMKeychainStore.removeAPIKey(for: config.id)
            } else {
                try LLMKeychainStore.writeAPIKey(trimmedKey, for: config.id)
            }
        } catch {
            settingsLogger.error("保存 LLM 配置失败：写钥匙串出错（\(String(describing: error))）")
            presentError(String(
                format: String(localized: "配置保存失败：%@。请重试。"),
                error.localizedDescription
            ))
            return
        }

        draft.apply(to: config)
        if isNew { modelContext.insert(config) }
        do {
            try modelContext.save()
        } catch {
            settingsLogger.error("保存 LLM 配置失败：数据库保存出错（\(String(describing: error))）")
            if isNew {
                modelContext.delete(config)
                try? modelContext.save()
            } else {
                rollbackSnapshot?.apply(to: config)
            }
            var message = String(
                format: String(localized: "配置保存失败：%@。请重试。"),
                error.localizedDescription
            )
            if !restoreAPIKey(previousKey, for: config.id) {
                message += String(localized: " 注意：钥匙串中的 API Key 未能恢复原值，请在配置中重新填写。")
            }
            presentError(message)
            return
        }

        onSaved?(config)
        dismiss()
    }

    /// 回滚 Keychain：把保存前记下的旧值写回；旧值不存在则删除本次写入
    private func restoreAPIKey(_ previousKey: String?, for id: UUID) -> Bool {
        do {
            if let previousKey, !previousKey.isEmpty {
                try LLMKeychainStore.writeAPIKey(previousKey, for: id)
            } else {
                try LLMKeychainStore.removeAPIKey(for: id)
            }
            return true
        } catch {
            settingsLogger.error("恢复 LLM 配置的钥匙串条目失败（\(String(describing: error))）")
            return false
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
