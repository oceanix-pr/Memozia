import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
/* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
import UIKit
*/
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

/// 设置页诊断日志：只记错误类别与阶段，绝不记录 API Key 或用户内容
private let settingsLogger = Logger(subsystem: "app.memozia", category: "Settings")

/// 设置页视图
/// 同步统计目录内文件总字节数（供后台任务调用）。
/// DirectoryEnumerator 的迭代不可在异步上下文直接使用（makeIterator 标记 noasync），
/// 必须封装在同步函数体内执行；maxEntries 兑底巨大目录，避免无界枚举
private func storageDirectoryTotalBytes(directory: URL, maxEntries: Int) -> Int? {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    var total = 0
    var visited = 0
    for case let url as URL in enumerator {
        visited += 1
        if visited > maxEntries { break }
        let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isRegular else { continue }
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return total
}

struct SettingsView: View {
    var isTransientMode: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var settingsVM: SettingsViewModel
    @Bindable var experienceStore: AppExperienceStore
    @Query private var llmConfigs: [LLMConfig]
    @Query(sort: \AudioRecording.createdAt, order: .reverse) private var allRecordings: [AudioRecording]
    @State private var syncService = CloudSyncService()

    /// 麦克风偏好：与菜单栏「麦克风」子菜单读写同一组键
    /// （空串 = 跟随系统默认输入设备），与录屏声源/质量同样走 AppStorage 保持双向同步
    @AppStorage(MicrophoneDeviceRegistry.selectionDefaultsKey) private var microphoneDeviceUID: String = ""

    /// 声纹单独同意：未同意时“自动识别声纹”开关不可用（敏感个人信息不能被普通偏好替代同意）
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.voiceprintConsent) private var voiceprintConsentGranted = false

    /// 录音开始时静音麦克风：与截图会话工具栏的麦克风菜单读写同一份偏好，
    /// 录音中可随时从录音徽章菜单或菜单栏「麦克风」解除
    @AppStorage(MicrophoneStartMutePreference.defaultsKey) private var microphoneStartMuted: Bool = false

    /// 离线参考回声消除：默认开启，仅专业模式的录音页暴露
    @AppStorage(EchoReductionPreference.defaultsKey) private var echoReductionEnabled: Bool = true

    @State private var selectedSection: SettingsSection? = .stt
    /// 设置搜索词：同时匹配设置页名称与应用命令（名称 / 当前快捷键）
    @State private var commandSearchText = ""
    /// detail 列导航路径：页内 NavigationLink（如“管理声纹库”“管理词典”）推入的层级；
    /// 切换侧边栏项时清空以弹回根视图，否则 detail 会卡在推入页导致菜单点击看似无响应
    @State private var detailPath: [DetailRoute] = []

    /// detail 列内可推入的子页面路由（值驱动导航，受 detailPath 控制）
    enum DetailRoute: Hashable {
        case privacyPolicy
    }
    /// LLM 配置编辑器目标：区分「新建」（仅草稿，未入库）与「编辑已有」（持久化对象），
    /// 取消时草稿直接丢弃，数据库与 Keychain 都不动
    @State private var editingTarget: LLMConfigEditTarget?
    /// 待删除的 LLM 配置（确认对话框）
    @State private var configToDelete: LLMConfig?
    @State private var showDeleteConfigConfirmation = false
    /// 大模型配置导入导出：导出文档在点按钮时先行序列化，导入结果统一走一个 alert
    @State private var llmExportDocument: LLMConfigExportDocument?
    @State private var showLLMExporter = false
    @State private var showLLMImporter = false
    @State private var llmTransferMessage = ""
    @State private var showLLMTransferAlert = false
    private let whisperService = WhisperLocalService.shared
    @State private var isDownloadingModel = false
    @State private var showModelError = false
    /// 存储目录总占用统计状态。
    /// 旧实现是 `String?`，统计失败与"正在统计"共用 nil → 界面永久停在「统计中…」，
    /// 既不告知失败也无法重试。
    private enum StorageSizeState: Equatable {
        case loading
        case loaded(String)
        case failed
    }
    @State private var storageSizeState: StorageSizeState = .loading
    /// 手动重试计数：参与 `.task(id:)` 以便失败后重新统计
    @State private var storageSizeRetry = 0
    /// 标记最近一次失败是"仅加载"还是"下载"，用于显示不同的 Alert 标题
    @State private var lastFailureWasLoadOnly = false
    @State private var showFeedback = false
    @State private var showHelp = false

    /// 从 Bundle 读取当前应用版本号
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
    @State private var showStorageFolderPicker = false
    @State private var showStorageResetAlert = false
    @State private var showStorageChangedAlert = false
    @State private var showStorageErrorAlert = false
    // 切换数据文件夹二次确认（切换不迁移旧数据，需用户明确知晓）
    @State private var showStorageSwitchConfirm = false
    @State private var pendingStorageURL: URL?
    @State private var viewModelErrorMessage = ""

    // 说话人分离模型下载状态
    @State private var isDownloadingDiarizationModel = false
    @State private var diarizationDownloadProgress: Double = 0
    @State private var showDiarizationError = false
    @State private var diarizationErrorText = ""

    // Whisper 模型下载状态（下载源与档位为界面态，选中源本身持久化在 SettingsViewModel）
    @State private var selectedWhisperVariant = WhisperModelOption.defaultVariant
    @State private var isDownloadingWhisperModel = false
    @State private var whisperDownloadProgress: Double = 0
    @State private var showWhisperDownloadError = false
    @State private var whisperDownloadErrorText = ""

    // 系统语音识别（macOS 26+）语言模型状态：模型由系统经 AssetInventory 管理，
    // 因此这里只有「已安装 / 待下载 / 不支持」三态，没有可配置的模型路径
    @State private var systemLocaleStatus: SystemTranscriptionLocaleStatus?
    @State private var isPreparingSystemLocale = false
    @State private var showSystemTranscriptionError = false
    @State private var systemTranscriptionErrorText = ""

    enum SettingsSection: String, CaseIterable, Identifiable {
        case stt = "语音转写"
        case llm = "大模型"
        case prompts = "提示词"
        case recording = "录音"
        case screenshot = "捕获"
        case hotkeys = "热键"
        case todo = "待办"
        case dictionary = "词典"
        case voiceprints = "声纹库"
        case data = "数据管理"
        case mcp = "MCP 集成"
        case about = "关于"

        var id: String { rawValue }

        /// 本地化显示名：rawValue 即 Localizable.xcstrings 的源键（各语言的翻译已存在），
        /// 运行时按当前界面语言解析，切换语言重启后侧边栏文字随之更新。
        /// 注意：不能直接渲染 rawValue——那会被 SwiftUI 当作 verbatim 文本，永不翻译
        var localizedName: String {
            NSLocalizedString(rawValue, comment: "")
        }

        var icon: String {
            switch self {
            case .stt:       return "waveform"
            case .llm:       return "brain"
            case .prompts:   return "text.quote"
            case .recording: return "mic.fill"
            case .screenshot: return "camera.viewfinder"
            case .hotkeys:   return "keyboard"
            case .todo:      return "checklist"
            case .dictionary: return "character.book.closed"
            case .voiceprints: return "person.text.rectangle"
            case .data:      return "externaldrive"
            case .mcp:       return "point.3.connected.trianglepath.dotted"
            case .about:     return "info.circle"
            }
        }
    }

    private var visibleSections: [SettingsSection] {
        if experienceStore.isPro { return SettingsSection.allCases }
        // 热键页两种模式都显示：录音热键与截图热键都是普通模式也在用的能力
        // （全屏直拍热键仅在专业模式注册，进而在页内隐藏对应行）
        return [.stt, .llm, .recording, .hotkeys, .data, .mcp, .about]
    }

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        iOSLayout
        */
        #endif
    }

    // MARK: - macOS 布局
    #if os(macOS)
    private var macOSLayout: some View {
        NavigationSplitView {
            settingsSidebar
                .navigationTitle("设置")
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
                .listStyle(.sidebar)
        } detail: {
            NavigationStack(path: $detailPath) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: DetailRoute.self) { route in
                        switch route {
                        case .privacyPolicy: PrivacyPolicyDetailView()
                        }
                    }
            }
        }
        // 切换侧边栏项时先弹回根视图（避免停留在“管理声纹库”等推入页）
        .onChange(of: selectedSection) {
            if !detailPath.isEmpty { detailPath.removeAll() }
        }
        .onAppear { ensureVisibleSelection() }
        .onChange(of: experienceStore.current) { ensureVisibleSelection() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    settingsVM.saveSettings()
                    dismiss()
                }
            }
        }
    }
    #endif

    // MARK: - iOS 布局
    #if os(iOS)
    /* iOS 专属布局（工程已改为仅 macOS，注释保留以备不时之需）
    private var iOSLayout: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        NavigationLink {
                            detailContent(for: section)
                                .navigationTitle(section.localizedName)
                        } label: {
                            Label(section.localizedName, systemImage: section.icon)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        settingsVM.saveSettings()
                        dismiss()
                    }
                }
            }
        }
    }
    */
    #endif

    // MARK: - Detail 内容
    @ViewBuilder
    private var detailContent: some View {
        if let section = selectedSection {
            detailContent(for: section)
        } else {
            ContentUnavailableView("选择设置项", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private func detailContent(for section: SettingsSection) -> some View {
        switch section {
        case .stt:       experienceStore.isPro ? AnyView(sttSettingsView) : AnyView(standardSTTSettingsView)
        case .llm:       experienceStore.isPro ? AnyView(llmSettingsView) : AnyView(standardLLMSettingsView)
        case .prompts:   PromptsSettingsView()
        case .recording: experienceStore.isPro ? AnyView(recordingSettingsView) : AnyView(standardRecordingSettingsView)
        case .screenshot: ScreenshotSettingsView()
        case .hotkeys:    HotkeySettingsView(isPro: experienceStore.isPro)
        case .todo:      TodoSettingsView(settingsVM: settingsVM)
        case .dictionary: DictionarySettingsView(settingsVM: settingsVM, recordings: allRecordings)
        case .voiceprints: VoiceprintLibraryView()
        case .data:      dataManagementView
        case .mcp:       MCPSettingsView(isTransient: isTransientMode)
        case .about:     aboutView
        }
    }

    private func ensureVisibleSelection() {
        guard let selectedSection, visibleSections.contains(selectedSection) else {
            self.selectedSection = visibleSections.first
            detailPath.removeAll()
            return
        }
    }

    // MARK: - 设置侧边栏（设置与命令搜索）

    /// 设置侧边栏：搜索同时覆盖「设置页」与「应用命令」。
    ///
    /// 命令结果的名称与当前快捷键来自 `AppCommandCatalog`（与菜单栏、应用菜单、帮助页同一份描述），
    /// 所以搜索里显示的组合键就是此刻真正生效的那一个；点选命令直接跳到相关设置页。
    private var settingsSidebar: some View {
        List(selection: $selectedSection) {
            if !commandSearchText.isEmpty && !matchingCommands.isEmpty {
                Section("命令") {
                    ForEach(matchingCommands) { command in
                        if command.settingsDestination != nil {
                            Button {
                                openSettingsDestination(of: command)
                            } label: {
                                commandRowLabel(command)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // 没有对应设置项的命令（如 ⌘N 新建笔记）只做名称与快捷键展示
                            commandRowLabel(command)
                        }
                    }
                }
            }
            Section {
                ForEach(matchingSections, id: \.self) { section in
                    Label(section.localizedName, systemImage: section.icon)
                        .tag(section)
                }
            }
        }
        .searchable(text: $commandSearchText, placement: .sidebar, prompt: Text("搜索设置与命令"))
    }

    /// 搜索命中的设置页（未输入搜索词时展示全部可见页）
    private var matchingSections: [SettingsView.SettingsSection] {
        let query = commandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleSections }
        return visibleSections.filter { $0.localizedName.localizedCaseInsensitiveContains(query) }
    }

    /// 搜索命中的命令：按本地化名称或当前快捷键匹配；普通模式不列出仅专业模式可用的命令
    private var matchingCommands: [AppCommandDescriptor] {
        let query = commandSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return AppCommandCatalog.all.filter { command in
            if command.proOnly && !experienceStore.isPro { return false }
            if command.localizedTitleString.localizedCaseInsensitiveContains(query) { return true }
            if let display = command.shortcut.display, display.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }
    }

    private func commandRowLabel(_ command: AppCommandDescriptor) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.icon ?? "command")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(command.localizedTitle)
            Spacer(minLength: 8)
            if let display = command.shortcut.display {
                Text(display)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 跳到命令对应的设置页（目标页在当前模式下不可见时保持原位，不静默跳错页）
    private func openSettingsDestination(of command: AppCommandDescriptor) {
        guard let destination = command.settingsDestination,
              let section = SettingsSection(rawValue: destination.rawValue),
              visibleSections.contains(section) else { return }
        detailPath.removeAll()
        selectedSection = section
    }

    // MARK: - 数据管理
    private var dataManagementView: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("数据文件夹")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(settingsVM.pendingStorageDirectoryPath ?? settingsVM.storageDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    if experienceStore.policy.allows(.customStorage) {
                        Button {
                            showStorageFolderPicker = true
                        } label: {
                            Label("更改", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showStorageResetAlert = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("重置为默认路径")
                        .accessibilityLabel(Text("重置为默认路径"))
                        .disabled(settingsVM.storageDirectoryPath == AudioRecording.defaultStorageDirectory.path)
                    }
                }

                Text("所有录音文件、转写和总结将保存在此文件夹中。更改后需要重启应用以重新加载数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("数据文件夹")
            }

            PortableBackupSection(isReadOnly: isTransientMode)

            Section("存储信息") {
                LabeledContent("录音数量", value: "\(allRecordings.count)")
                LabeledContent("已完成转写", value: "\(allRecordings.filter { $0.transcriptionStatus == .completed }.count)")
                switch storageSizeState {
                case .loaded(let totalSize):
                    LabeledContent("总占用空间", value: totalSize)
                case .loading:
                    LabeledContent("总占用空间", value: String(localized: "统计中…"))
                case .failed:
                    // 失败不再伪装成"统计中"：明确告知并提供重试入口
                    LabeledContent("总占用空间") {
                        HStack(spacing: 8) {
                            Text("统计失败")
                                .foregroundStyle(.secondary)
                            Button("重试") { storageSizeRetry += 1 }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .task(id: "\(settingsVM.storageDirectoryPath)#\(storageSizeRetry)") {
                // 递归统计移出主线程：存储目录内文件多或位于慢速卷时，
                // 同步枚举会冻结整个应用（原实现为视图计算属性，每次渲染都重新遍历）
                storageSizeState = .loading
                let dir = AudioRecording.storageDirectory
                let text: String? = await Task.detached(priority: .utility) { () -> String? in
                    guard let total = storageDirectoryTotalBytes(directory: dir, maxEntries: 200_000) else { return nil }
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useKB, .useMB, .useGB]
                    formatter.countStyle = .file
                    return formatter.string(fromByteCount: Int64(total))
                }.value
                guard !Task.isCancelled else { return }
                storageSizeState = text.map(StorageSizeState.loaded) ?? .failed
            }

            if experienceStore.policy.allows(.hiddenItems) {
                Section {
                    Toggle(isOn: Binding(
                        get: { settingsVM.showHiddenRecordings },
                        set: { newValue in
                            settingsVM.showHiddenRecordings = newValue
                            settingsVM.saveSettings()
                        }
                    )) {
                        Label("显示隐藏的条目", systemImage: "eye.slash")
                    }

                    Text("开启后，左侧列表将显示被隐藏的录音与笔记（文字颜色较浅）。可在列表中右键取消隐藏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("隐藏条目")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("数据管理")
        #if os(macOS)
        .fileImporter(
            isPresented: $showStorageFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleStorageFolderPick(result)
        }
        #endif
        .alert("切换数据文件夹", isPresented: $showStorageSwitchConfirm) {
            Button("取消", role: .cancel) {
                pendingStorageURL = nil
            }
            #if os(macOS)
            // 迁移向导的最小可用形态：先让用户看清两个目录里各有什么，再决定是否切换。
            // 自动迁移涉及复制/校验/回滚，需要运行时验证，暂不在此处执行（见 PRD Backlog）
            Button(String(localized: "在 Finder 中打开当前目录")) {
                NSWorkspace.shared.open(AudioRecording.storageDirectory)
            }
            Button(String(localized: "在 Finder 中打开新目录")) {
                if let url = pendingStorageURL { NSWorkspace.shared.open(url) }
            }
            #endif
            Button("切换", role: .destructive) {
                confirmStorageSwitch()
            }
        } message: {
            Text("切换后现有录音、转写与总结不会自动迁移，仍保留在原文件夹（切回原路径即可恢复显示）。新数据将保存到：\n\n\(pendingStorageURL?.path ?? "")\n\n确认切换并重启应用。")
        }
        .alert("重置数据文件夹", isPresented: $showStorageResetAlert) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                // 同样只记「待生效」，重启后生效，避免运行期改根
                AudioRecording.setPendingStorageDirectory(AudioRecording.defaultStorageDirectory)
                showStorageChangedAlert = true
            }
        } message: {
            Text("将数据文件夹重置为默认路径：\(AudioRecording.defaultStorageDirectory.path)\n\n注意：自定义路径下的现有数据不会迁移，仍保留在原文件夹。重置后需要重启应用以重新加载数据。")
        }
        .alert("数据文件夹已更改", isPresented: $showStorageChangedAlert) {
            Button("确定") {}
        } message: {
            Text("数据文件夹已更改，请重启应用以重新加载数据。")
        }
        .alert("路径无效", isPresented: $showStorageErrorAlert) {
            Button("确定") {}
        } message: {
            Text(viewModelErrorMessage)
        }
        .alert(lastFailureWasLoadOnly ? "模型加载失败" : "模型下载失败",
               isPresented: $showModelError) {
            Button("确定") {}
        } message: {
            Text(whisperService.lastError ?? "未知错误")
        }
        .alert("错误", isPresented: $settingsVM.showError) {
            Button("确定") {}
        } message: {
            Text(settingsVM.errorMessage ?? "未知错误")
        }
    }

    /// 处理文件夹选择
    private func handleStorageFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 限制数据文件夹范围：禁止选择系统关键目录
            let path = url.path
            let forbiddenPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/dev", "/private"]
            if forbiddenPrefixes.contains(where: { path.hasPrefix($0) }) {
                showStorageFolderPicker = false
                viewModelErrorMessage = String(localized: "不能选择系统目录作为数据文件夹")
                showStorageErrorAlert = true
                return
            }
            // 已是当前目录则无需切换
            if path == settingsVM.storageDirectoryPath { return }
            // 先确认再切换：切换不迁移旧数据，避免用户误以为旧录音丢失
            pendingStorageURL = url
            showStorageSwitchConfirm = true
        case .failure:
            viewModelErrorMessage = String(localized: "文件夹选择失败，请重试。")
            showStorageErrorAlert = true
        }
    }

    /// 确认切换数据文件夹：预检通过后**只记 pending**，重启应用才生效。
    /// 不在运行期改根——那会让锁、队列与旧条目的 folderURL 与新根脱节（双根目录）。
    private func confirmStorageSwitch() {
        guard let url = pendingStorageURL else { return }
        // macOS fileImporter 返回的 URL 可能需要访问权限
        #if os(macOS)
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        #endif

        // 录音/录屏进行中：重启会打断本次会话，先让用户停止
        if MeetingRecorderService.shared.isRecording {
            viewModelErrorMessage = String(localized: "正在录音或录屏，请先停止后再更改数据文件夹。")
            showStorageErrorAlert = true
            return
        }
        // 仍有后台任务待续跑：它们在旧根下的目标文件夹不会随切换迁移
        if BackgroundTaskQueue.hasEntries() {
            viewModelErrorMessage = String(localized: "仍有后台任务待处理，请等队列清空后再更改数据文件夹。")
            showStorageErrorAlert = true
            return
        }
        // 目录预检：可创建、可原子写删、卷在线
        let preflight = StoragePreflight.evaluate(url)
        guard preflight.isPassing else {
            viewModelErrorMessage = preflight.blockers.joined(separator: "\n")
            showStorageErrorAlert = true
            return
        }

        // 只记「待生效」；本进程根目录不变，下次启动提升为 active
        AudioRecording.setPendingStorageDirectory(url)
        pendingStorageURL = nil
        showStorageChangedAlert = true
    }

    // MARK: - 普通模式设置

    private var isStandardWhisperModelReady: Bool {
        whisperService.isModelLoadedFor(path: settingsVM.standardWhisperModelPath)
            || (try? WhisperLocalService.resolveModelFolder(at: settingsVM.standardWhisperModelPath)) != nil
    }

    // MARK: - 系统语音识别状态（macOS 26+）

    /// 系统语音识别的语言模型状态行。
    /// - Parameter language: 设置中的语言值；空串表示跟随系统语言（普通模式即此语义）
    @ViewBuilder
    private func systemTranscriptionStatusRow(language: String) -> some View {
        switch systemLocaleStatus {
        case .some(.ready):
            Label("系统语音识别已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(.needsDownload):
            if isPreparingSystemLocale {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在下载系统语音模型…")
                }
            } else {
                Button {
                    prepareSystemLocale(language: language)
                } label: {
                    Label("下载系统语音模型", systemImage: "arrow.down.circle")
                }
            }
        case .some(.unsupported):
            Label("系统不支持该语言，请改选其他语言或改用本地 Whisper 组件",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .none:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查系统语音识别…")
            }
        }
    }

    /// 查询系统语音模型状态（不做下载）
    private func refreshSystemLocaleStatus(language: String) {
        guard SystemTranscription.isSupported else {
            systemLocaleStatus = nil
            return
        }
        Task {
            systemLocaleStatus = await SystemTranscription.localeStatus(language: language)
        }
    }

    /// 触发系统语音模型下载（幂等：已安装时直接返回）
    private func prepareSystemLocale(language: String) {
        isPreparingSystemLocale = true
        Task {
            do {
                try await SystemTranscription.prepareLocale(language: language)
            } catch {
                systemTranscriptionErrorText = UserFacingError.summary(for: error)
                showSystemTranscriptionError = true
            }
            systemLocaleStatus = await SystemTranscription.localeStatus(language: language)
            isPreparingSystemLocale = false
        }
    }

    private var standardSTTSettingsView: some View {
        Form {
            Section("语音转写") {
                Label("录音会在本机转成文字，不上传原始音频。", systemImage: "lock.shield.fill")
                    .font(.subheadline)

                if SystemTranscription.isSupported {
                    // macOS 26 起普通模式默认走系统语音识别：无需下载 465 MB 模型，
                    // 只需确认当前系统语言的模型是否已安装
                    systemTranscriptionStatusRow(language: "")
                } else if isStandardWhisperModelReady {
                    Label("转写组件已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isDownloadingWhisperModel {
                    HStack {
                        ProgressView(value: whisperDownloadProgress, total: 1)
                            .frame(maxWidth: 220)
                        Button("取消") { cancelWhisperModelDownload() }
                    }
                } else {
                    Button {
                        downloadStandardWhisperModel()
                    } label: {
                        Label("下载转写组件（约 465 MB）", systemImage: "arrow.down.circle")
                    }
                }
            }

            Section("说话人区分") {
                if isDiarizationModelReady {
                    Label("说话人区分已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isDownloadingDiarizationModel {
                    ProgressView(value: diarizationDownloadProgress, total: 1)
                        .frame(maxWidth: 220)
                } else {
                    Button {
                        downloadDiarizationModel()
                    } label: {
                        Label("下载说话人区分组件（约 33 MB）", systemImage: "person.2.wave.2")
                    }
                }
                Text("组件未下载时仍可正常转写，只是不会区分不同说话人。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("语音转写")
        .alert("模型下载失败", isPresented: $showWhisperDownloadError) {
            Button("确定") {}
        } message: {
            Text(whisperDownloadErrorText)
        }
        .alert("说话人分离模型下载失败", isPresented: $showDiarizationError) {
            Button("确定") {}
        } message: {
            Text(diarizationErrorText)
        }
        .alert("系统语音模型下载失败", isPresented: $showSystemTranscriptionError) {
            Button("确定") {}
        } message: {
            Text(systemTranscriptionErrorText)
        }
        .task { refreshSystemLocaleStatus(language: "") }
    }

    private var standardRecordingSettingsView: some View {
        Form {
            Section("会议类型") {
                Picker("会议类型", selection: $settingsVM.standardRecordingMode) {
                    ForEach(StandardRecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsVM.standardRecordingMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自动设置") {
                Label("Memozia 会自动选择录音来源、检测系统静音并在设备变化后继续录音。", systemImage: "wand.and.stars")
                    .font(.subheadline)
                Text("需要选择具体麦克风或单独录制系统声音时，可以开启专业模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("录音")
        .onChange(of: settingsVM.standardRecordingMode) { settingsVM.saveSettings() }
    }

    /// 当前生效配置对应的服务商。用于「选择服务商」列表打勾：
    /// 按端点反查而不是比名字，用户改过配置名称也不会错位
    private var activeLLMPreset: LLMPreset? {
        settingsVM.getActiveLLMConfig(from: llmConfigs)
            .flatMap { LLMPreset.matching(baseURL: $0.baseURL) }
    }

    private var standardLLMSettingsView: some View {
        Form {
            Section("智能服务") {
                if let active = settingsVM.getActiveLLMConfig(from: llmConfigs) {
                    LabeledContent("已连接服务", value: active.name)
                    Label(
                        active.isLocal ? "在本机处理" : "通过云端处理",
                        systemImage: active.isLocal ? "house.fill" : "cloud.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // 添加了多个服务商时给出切换入口，否则用户会被钉在最后添加的那个上
                    if llmConfigs.count > 1 {
                        Picker("当前服务", selection: Binding(
                            get: { settingsVM.getActiveLLMConfig(from: llmConfigs)?.id },
                            set: { newValue in
                                if let id = newValue, let picked = llmConfigs.first(where: { $0.id == id }) {
                                    settingsVM.setActiveLLMConfig(picked)
                                }
                            }
                        )) {
                            ForEach(llmConfigs) { config in
                                Text(config.name).tag(Optional(config.id))
                            }
                        }
                    }

                    Button {
                        editingTarget = .existing(active)
                    } label: {
                        Label(
                            active.isLocal ? "选择模型" : "设置 API Key 与模型",
                            systemImage: active.isLocal ? "slider.horizontal.3" : "key.fill"
                        )
                    }
                } else {
                    Label("尚未连接智能服务", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text("选择下方任意服务商，填写 API Key 并挑选模型后即可生成总结、标题和待办。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("选择服务商") {
                ForEach(LLMPreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        openLLMConfig(for: preset)
                    } label: {
                        HStack {
                            Image(systemName: preset.icon)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName).font(.subheadline)
                                Text(preset.description).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if activeLLMPreset == preset {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Text("需要自定义服务地址、多模型切换或视觉模型时，可以开启专业模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("智能服务")
        .sheet(item: $editingTarget) { target in
            LLMConfigEditView(target: target, simplified: true) { saved in
                settingsVM.setActiveLLMConfig(saved)
            }
        }
    }

    /// 简化模式选服务商：已有同端点配置就直接编辑它，否则开一份新草稿。
    /// 草稿不落库，用户取消时不会在列表里留下半成品配置
    private func openLLMConfig(for preset: LLMPreset) {
        if let existing = llmConfigs.first(where: { LLMPreset.matching(baseURL: $0.baseURL) == preset }) {
            settingsVM.setActiveLLMConfig(existing)
            editingTarget = .existing(existing)
        } else {
            editingTarget = .new(LLMConfigDraft(
                name: preset.displayName,
                baseURL: preset.baseURL,
                modelName: preset.defaultModel,
                isLocal: preset.isLocal,
                supportsVision: preset.supportsVisionByDefault
            ))
        }
    }

    // MARK: - STT 设置
    private var sttSettingsView: some View {
        Form {
            Section("转写模式") {
                Picker("模式", selection: $settingsVM.sttMode) {
                    ForEach(STTMode.pickerModes(current: settingsVM.sttMode), id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch settingsVM.sttMode {
                case .local:
                    // 模型文件夹路径（内含完整 Whisper CoreML 模型或单个模型子文件夹）
                    HStack {
                        TextField("模型文件夹", text: $settingsVM.whisperModelPath)
                            .textFieldStyle(.roundedBorder)
                        #if os(macOS)
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = String(localized: "选择")
                            let startURL = URL(fileURLWithPath: (settingsVM.whisperModelPath as NSString).expandingTildeInPath)
                            if FileManager.default.fileExists(atPath: startURL.path) {
                                panel.directoryURL = startURL
                            }
                            if panel.runModal() == .OK, let url = panel.url {
                                settingsVM.whisperModelPath = url.path
                                settingsVM.saveSettings()
                            }
                        } label: {
                            Text("选择…")
                        }
                        #endif
                    }

                    // 模型加载状态与操作
                    HStack {
                        if whisperService.isModelLoadedFor(path: settingsVM.whisperModelPath) {
                            Label("加载完成", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else if isDownloadingModel {
                            // 加载中：显示转圈
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("加载中...")
                                    .font(.caption)
                                if whisperService.isLoadingModel {
                                    Button {
                                        whisperService.cancelModelLoad()
                                        isDownloadingModel = false
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("取消加载")
                                    .accessibilityLabel(Text("取消加载"))
                                }
                            }
                        } else {
                            // 未加载：显示"加载模型"按钮
                            Button {
                                isDownloadingModel = true
                                Task {
                                    do {
                                        try await whisperService.loadModel(fromPath: settingsVM.whisperModelPath)
                                    } catch is CancellationError {
                                        // 用户取消，无需处理
                                    } catch {
                                        if whisperService.lastError == nil {
                                            whisperService.lastError = UserFacingError.summary(for: error)
                                        }
                                        lastFailureWasLoadOnly = true
                                        showModelError = true
                                    }
                                    isDownloadingModel = false
                                }
                            } label: {
                                Label("加载模型", systemImage: "arrow.clockwise.circle")
                            }
                            .font(.caption)
                        }
                    }

                    Text("请将完整的 Whisper CoreML 模型放在该文件夹下（直接包含或放在单个子文件夹中）：AudioEncoder.mlmodelc、MelSpectrogram.mlmodelc、TextDecoder.mlmodelc 及 tokenizer.json 等文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .cloud:
                    Label("该模式已隐藏，仅对已保存此配置的用户保留；一旦切换为其他模式将无法再选回。",
                          systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API Key", text: $settingsVM.whisperAPIKey)
                        .textFieldStyle(.roundedBorder)

                    TextField("Base URL", text: $settingsVM.whisperBaseURL)
                        .textFieldStyle(.roundedBorder)
                    if !settingsVM.isWhisperBaseURLSecure {
                        Label("非 HTTPS 地址，API Key 和音频数据将以明文传输，仅建议用于本地服务",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("默认：https://api.openai.com/v1。如需中转可自定义。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .system:
                    Label("使用 macOS 系统语音识别：纯本地推理、长音频无时长上限，无需下载 Whisper 模型。",
                          systemImage: "lock.shield.fill")
                        .font(.subheadline)
                    // .task 只在选中系统语音识别时挂载，进入该模式即刷新一次状态
                    systemTranscriptionStatusRow(language: settingsVM.whisperLanguage)
                        .task { refreshSystemLocaleStatus(language: settingsVM.whisperLanguage) }
                    Text("识别语言取下方「转写语言」；选择「自动检测」时使用系统语言。系统语音识别不提供说话人标签，说话人区分仍由本地分离组件按时间轴标注。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settingsVM.sttMode == .local {
                whisperModelDownloadSection
                    .alert("模型下载失败", isPresented: $showWhisperDownloadError) {
                        Button("确定") {}
                    } message: {
                        Text(whisperDownloadErrorText)
                    }
            }

            Section("语言设置") {
                Picker("转写语言", selection: $settingsVM.whisperLanguage) {
                    ForEach(WhisperLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                Text("选择音频中的语言以提升识别精度，默认简体中文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("说话人分离") {
                Toggle(isOn: $settingsVM.enableSpeakerDiarization) {
                    Label("区分不同说话人", systemImage: "person.2.wave.2")
                }
                if settingsVM.enableSpeakerDiarization {
                    diarizationModelRow
                    cpuCoreRow
                    precisionRow
                    Toggle(isOn: Binding(
                        get: { voiceprintConsentGranted && settingsVM.enableVoiceprintRecognition },
                        set: { settingsVM.enableVoiceprintRecognition = $0 }
                    )) {
                        Label("自动识别声纹", systemImage: "person.wave.2")
                    }
                    .disabled(!voiceprintConsentGranted)
                    // 声纹库已有独立侧边栏 section：直接切换选中项而非推入导航层，
                    // 避免推入页导致侧边栏菜单点击看似无响应
                    Button {
                        selectedSection = .voiceprints
                    } label: {
                        Label("管理声纹库", systemImage: "person.text.rectangle")
                    }
                    if !voiceprintConsentGranted {
                        Label("声纹处理需要单独同意。请到「设置 → 关于 → 隐私政策」开启「声纹处理单独同意」。", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("转写完成后自动区分会议中的不同说话人（基于 pyannote 分段模型，CPU 推理，完全本地运行，说话人数量自动识别）。开启后转写耗时略有增加；模型未就绪时自动跳过，不影响转写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if voiceprintConsentGranted && settingsVM.enableVoiceprintRecognition {
                        Text("分离完成后与声纹库比对，命中的说话人直接标注为注册姓名（在转写页点“声纹”按钮标记）；未命中保留“说话人 N”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

//            Section("语音解析词典") {
//                Toggle(isOn: $settingsVM.enableDictionaryCorrection) {
//                    Label("词典纠正", systemImage: "character.book.closed")
//                }
//                // 词典已有独立侧边栏 section：直接切换选中项而非推入导航层
//                Button {
//                    selectedSection = .dictionary
//                } label: {
//                    Label("管理词典", systemImage: "folder")
//                }
//                Text("转写后自动纠正专有名词误写：读取 ~/Documents/Memozia/Dictionary 下的 Markdown 词典，按拼音匹配替换，无需预先枚举错误写法。")
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//            }
        }
        .formStyle(.grouped)
        .navigationTitle("语音转写")
        .onChange(of: settingsVM.diarizationThreadCount) { settingsVM.saveSettings() }
        .onChange(of: settingsVM.diarizationPrecision) { settingsVM.saveSettings() }
        .alert("说话人分离模型下载失败", isPresented: $showDiarizationError) {
            Button("确定") {}
        } message: {
            Text(diarizationErrorText)
        }
    }

    // MARK: - Whisper 模型下载行（语音转写页 · 本地模式）
    /// 当前选中的下载档位（界面态；默认 small）
    private var selectedWhisperOption: WhisperModelOption {
        WhisperModelOption.option(for: selectedWhisperVariant) ?? WhisperModelOption.catalog[0]
    }

    /// 档位标签：已就绪的档位追加「已下载」，避免用户重复下载
    private func whisperOptionLabel(_ option: WhisperModelOption) -> String {
        let base = "\(option.displayName) · \(option.sizeText)"
        guard WhisperModelDownloader.isModelPresent(
            option: option,
            modelRootPath: settingsVM.whisperModelPath
        ) else { return base }
        return "\(base) · \(String(localized: "已下载"))"
    }

    @ViewBuilder
    private var whisperModelDownloadSection: some View {
        Section("下载模型") {
            Picker("下载源", selection: $settingsVM.whisperModelSource) {
                ForEach(WhisperModelSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .onChange(of: settingsVM.whisperModelSource) { _, _ in
                // 立即持久化：加载模型时的 tokenizer 回退按该源读取 HF_ENDPOINT
                settingsVM.saveSettings()
            }

            Picker("模型档位", selection: $selectedWhisperVariant) {
                ForEach(WhisperModelOption.catalog) { option in
                    Text(whisperOptionLabel(option)).tag(option.variant)
                }
            }

            HStack {
                if isDownloadingWhisperModel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下载中…")
                            .font(.caption)
                        ProgressView(value: whisperDownloadProgress, total: 1.0)
                            .frame(width: 180)
                    }
                    Button {
                        cancelWhisperModelDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("取消下载")
                    .accessibilityLabel(Text("取消下载"))
                } else {
                    Button {
                        downloadWhisperModel()
                    } label: {
                        Label("下载并加载", systemImage: "arrow.down.circle")
                    }
                    .font(.caption)
                    .disabled(isDownloadingModel)
                }

                Spacer()

                #if os(macOS)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: settingsVM.whisperModelPath))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("打开模型文件夹：\(settingsVM.whisperModelPath)")
                .accessibilityLabel(Text("打开模型文件夹"))
                #endif
            }

            Text("下载的模型会保存到模型文件夹下的同名子文件夹；也可以自行准备好模型后用「选择…」指定文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 下载所选档位：投递到处理队列（可在右上角队列面板暂停/取消/继续），
    /// 完成后把模型文件夹指向该档位并直接加载
    private func downloadWhisperModel() {
        let option = selectedWhisperOption
        let source = settingsVM.whisperModelSource
        let rootPath = settingsVM.whisperModelPath
        isDownloadingWhisperModel = true
        whisperDownloadProgress = 0

        let job = TaskCenter.whisperDownloadJob(
            option: option,
            source: source,
            modelRootPath: rootPath,
            title: option.variant,
            onProgress: { progress in
                whisperDownloadProgress = progress
            },
            onFinished: { result in
                isDownloadingWhisperModel = false
                switch result {
                case .success(let modelPath):
                    settingsVM.whisperModelPath = modelPath
                    settingsVM.saveSettings()
                    // 下载完立即加载，省掉一次手动点击
                    isDownloadingModel = true
                    Task {
                        do {
                            try await whisperService.loadModel(fromPath: modelPath)
                        } catch is CancellationError {
                            // 用户取消加载，无需处理
                        } catch {
                            if whisperService.lastError == nil {
                                whisperService.lastError = UserFacingError.summary(for: error)
                            }
                            lastFailureWasLoadOnly = true
                            showModelError = true
                        }
                        isDownloadingModel = false
                    }
                case .failure(let error):
                    // 取消 / 暂停：已下载分片保留，下次可续传
                    if error is CancellationError { return }
                    whisperDownloadErrorText = UserFacingError.summary(for: error)
                    showWhisperDownloadError = true
                }
            }
        )
        TaskCenter.shared.enqueue(job)
    }

    /// 普通模式始终下载经过默认评估的 small 档位，并把结果写入
    /// 独立路径；不修改 Pro 中保存的模型档位、云端模式或自定义路径。
    private func downloadStandardWhisperModel() {
        let option = WhisperModelOption.option(for: WhisperModelOption.defaultVariant)
            ?? WhisperModelOption.catalog[0]
        isDownloadingWhisperModel = true
        whisperDownloadProgress = 0

        let job = TaskCenter.whisperDownloadJob(
            option: option,
            source: WhisperModelSourceStore.current,
            modelRootPath: WhisperModelFolder.resolvedPath,
            title: option.variant,
            onProgress: { progress in
                whisperDownloadProgress = progress
            },
            onFinished: { result in
                isDownloadingWhisperModel = false
                switch result {
                case .success(let modelPath):
                    settingsVM.standardWhisperModelPath = modelPath
                    settingsVM.saveSettings()
                    isDownloadingModel = true
                    Task {
                        do {
                            try await whisperService.loadModel(fromPath: modelPath)
                        } catch is CancellationError {
                            // 用户取消时保留可续传分片。
                        } catch {
                            whisperDownloadErrorText = UserFacingError.summary(for: error)
                            showWhisperDownloadError = true
                        }
                        isDownloadingModel = false
                    }
                case .failure(let error):
                    if error is CancellationError { return }
                    whisperDownloadErrorText = UserFacingError.summary(for: error)
                    showWhisperDownloadError = true
                }
            }
        )
        TaskCenter.shared.enqueue(job)
    }

    /// 取消下载（不清理已落盘的分片，重复下载时按 Range 续传）：
    /// 取消对应处理队列 Job
    private func cancelWhisperModelDownload() {
        TaskCenter.shared.cancelJobs(folderName: "model:\(selectedWhisperOption.variant)")
        isDownloadingWhisperModel = false
        whisperDownloadProgress = 0
    }

    // MARK: - 说话人分离模型行（语音转写页）
    /// 说话人分离模型状态（每次渲染直接探测文件，代价仅为两次 fileExists）
    private var isDiarizationModelReady: Bool {
        SpeakerDiarizationService.isModelReady(modelPath: settingsVM.diarizationModelPath)
    }

    @ViewBuilder
    private var diarizationModelRow: some View {
        HStack {
            if isDiarizationModelReady {
                Label("模型已就绪", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if isDownloadingDiarizationModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载中…")
                        .font(.caption)
                    ProgressView(value: diarizationDownloadProgress, total: 1.0)
                        .frame(width: 180)
                }
            } else {
                Button {
                    downloadDiarizationModel()
                } label: {
                    Label("下载模型（约 33MB）", systemImage: "arrow.down.circle")
                }
                .font(.caption)
                Text("未下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            #if os(macOS)
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: settingsVM.diarizationModelPath))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("打开模型文件夹：\(settingsVM.diarizationModelPath)")
            .accessibilityLabel(Text("打开模型文件夹"))
            #endif
        }
    }

    /// 说话人分离的 CPU 核心数调节行（专业模式）：范围 2 ~（逻辑核心数 - 1）
    private var cpuCoreRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("CPU 核心数", systemImage: "cpu")
                Spacer()
                Text("\(settingsVM.diarizationThreadCount) 核")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Stepper(
                    "",
                    value: $settingsVM.diarizationThreadCount,
                    in: DiarizationThreads.minAllowed...DiarizationThreads.maxAllowed
                )
                .labelsHidden()
            }
            Text("供说话人分离使用的 CPU 核心数，可调范围 2–\(DiarizationThreads.maxAllowed)（本机共 \(ProcessInfo.processInfo.activeProcessorCount) 核，建议留 1 核给系统）。核心越多分离越快，但会占用更多 CPU。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 说话人区分精细度（专业模式）：五档，默认中间档「标准」
    private var precisionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("精细度", systemImage: "slider.horizontal.3")
                Spacer()
                Picker("", selection: $settingsVM.diarizationPrecision) {
                    ForEach(DiarizationPrecision.allCases, id: \.self) { level in
                        Text(level.localizedName).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Text("越高越细：分段窗口重叠更多、每段更长，说话人边界更精确，同时更吃 CPU 与内存。档位只调整分段相关参数（何时分段、每段多长、窗口重叠多少），说话人聚类与声纹识别的判定标准不变。「标准」与历史默认行为一致；修改后需重新转写才生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 下载说话人分离模型（下载到设置中的模型文件夹）
    private func downloadDiarizationModel() {
        isDownloadingDiarizationModel = true
        diarizationDownloadProgress = 0
        Task {
            do {
                try await SpeakerDiarizationService.shared.downloadModels(
                    modelPath: settingsVM.diarizationModelPath
                ) { progress in
                    Task { @MainActor in
                        diarizationDownloadProgress = progress
                    }
                }
            } catch {
                diarizationErrorText = UserFacingError.summary(for: error)
                showDiarizationError = true
            }
            isDownloadingDiarizationModel = false
        }
    }

    // MARK: - 录音设置（macOS）
    #if os(macOS)
    /// 可选麦克风设备（每次渲染重新枚举，插拔设备后切回本页即可刷新）
    private var availableMicrophones: [MicrophoneDevice] {
        MicrophoneDeviceRegistry.availableDevices()
    }
    #endif

    private var recordingSettingsView: some View {
        Form {
            Section("录音来源") {
                Picker("来源", selection: $settingsVM.recordingSource) {
                    ForEach(RecordingSource.allCases, id: \.self) { source in
                        Label(source.displayName, systemImage: source.iconName)
                            .tag(source)
                    }
                }

                #if os(macOS)
                if settingsVM.recordingSource != .systemAudio {
                    Picker("输入设备", selection: $microphoneDeviceUID) {
                        Text("跟随系统默认").tag("")
                        ForEach(availableMicrophones) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if !microphoneDeviceUID.isEmpty,
                           !availableMicrophones.contains(where: { $0.uid == microphoneDeviceUID }) {
                            Text("已断开，将回退系统默认").tag(microphoneDeviceUID)
                        }
                    }

                    // 麦克风选择处同时给出静音入口：这里设的是「开始时」的初始状态，
                    // 录音中再改走徽章菜单 / 菜单栏「麦克风」/ 截图会话工具栏的麦克风菜单
                    Toggle("录音开始时静音麦克风", isOn: $microphoneStartMuted)
                    Text("开启后，每次开始录音或录屏都会先静音麦克风采集；录音中可在录音状态徽章或菜单栏「麦克风」里随时解除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                switch settingsVM.recordingSource {
                case .microphone:
                    Text("仅录制麦克风输入。适合本地会议或语音备忘。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .systemAudio:
                    Text("仅录制系统输出音频。适合在线会议中他人发言内容（需 macOS 14.4+）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .mixed:
                    Text("同时录制麦克风与系统音频（MVP 阶段优先麦克风，系统音频作为补充）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("静音检测") {
                Toggle("自动检测系统静音", isOn: $settingsVM.autoMuteDetection)
                Text("开启后，当系统输入设备被静音时（如会议软件调用系统级静音），自动暂停麦克风采集。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if os(macOS)
                if !microphoneDeviceUID.isEmpty,
                   let device = availableMicrophones.first(where: { $0.uid == microphoneDeviceUID }),
                   !device.supportsMute {
                    Text("所选麦克风不提供系统静音属性，「自动检测系统静音」对它无效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                Toggle("自动跟随会议软件静音（当前版本未启用）", isOn: .constant(false))
                    .disabled(true)
                Text("应用层静音检测依赖辅助功能权限；代码保留但当前版本未启动，因此该开关暂不生效。系统级静音仍可使用上方的「自动检测系统静音」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("回声消除") {
                Toggle("离线参考回声消除", isOn: $echoReductionEnabled)
                Text("以系统音频为参考，消除麦克风轨里由扬声器外放泄漏回来的远端声音，避免同一句话在合并后出现两份。\n\n仅在「来源」同时包含麦克风与系统音频（混合模式）时生效；处理失败会自动沿用原始音轨，不会丢失录音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("使用说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("点击工具栏「开始会议录音」按钮启动录音", systemImage: "record.circle")
                    Label("也可通过菜单栏图标开始/停止录音（无需主窗口）", systemImage: "menubar.rectangle")
                    Label("会议中共享屏幕前，点菜单栏「隐藏主窗口」可隐藏界面和 Dock 图标", systemImage: "eye.slash")
                    Label("停止录音后自动创建录音记录，可直接转写", systemImage: "waveform")
                    Label("快捷键：录音默认全局热键 ⌃⌘R（可在「设置 → 快捷键」修改）；菜单栏菜单展开时 ⌘R 开始/停止录音、⌘H 隐藏/显示主窗口", systemImage: "keyboard")
                    Label("录音文件存储在文稿/Memozia 文件夹，按年月日时分归档", systemImage: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("录音")
    }

    // MARK: - LLM 设置
    private var llmSettingsView: some View {
        List {
            Section("已配置的模型") {
                if llmConfigs.isEmpty {
                    Text("暂无配置，点击下方按钮添加")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(llmConfigs) { config in
                        LLMConfigRowView(
                            config: config,
                            isActive: settingsVM.activeLLMConfigID == config.id,
                            onSelect: { settingsVM.setActiveLLMConfig(config) },
                            onEdit: { editingTarget = .existing(config) },
                            onDelete: { requestDeleteLLMConfig(config) }
                        )
                    }
                    .onDelete { indexSet in
                        // 滑动删除同样走确认流程，避免误删
                        guard let index = indexSet.first else { return }
                        requestDeleteLLMConfig(llmConfigs[index])
                    }
                }
            }

            Section("快捷添加") {
                ForEach(LLMPreset.allCases) { preset in
                    Button {
                        // 与「新建」同一条路径：只开草稿，不预先入库；
                        // 取消即不留痕，保存成功后才落库并设为激活
                        editingTarget = .new(
                            LLMConfigDraft(
                                name: preset.displayName,
                                baseURL: preset.baseURL,
                                modelName: preset.defaultModel,
                                isLocal: preset.isLocal,
                                supportsVision: preset.supportsVisionByDefault
                            ),
                            activatesOnSave: true
                        )
                    } label: {
                        HStack {
                            Image(systemName: preset.icon)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName).font(.subheadline)
                                Text(preset.description).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("配置迁移") {
                Button {
                    beginLLMExport()
                } label: {
                    Label("导出配置…", systemImage: "square.and.arrow.up")
                }
                .disabled(llmConfigs.isEmpty)

                Button {
                    showLLMImporter = true
                } label: {
                    Label("导入配置…", systemImage: "square.and.arrow.down")
                }

                Text("导出文件会自动加密（与本地数据同一把密钥），只有本机 Memozia 能解开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("大模型")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingTarget = .new(LLMConfigDraft(
                        name: "自定义 API",
                        baseURL: "https://your-api.com",
                        modelName: "model-name"
                    ))
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .fileExporter(
            isPresented: $showLLMExporter,
            document: llmExportDocument,
            contentType: .json,
            defaultFilename: "Memozia-大模型配置"
        ) { result in
            if case .failure(let error) = result {
                llmTransferMessage = String(format: String(localized: "导出失败：%@"), UserFacingError.summary(for: error))
                showLLMTransferAlert = true
            }
        }
        .fileImporter(
            isPresented: $showLLMImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleLLMImport(result)
        }
        .alert("配置迁移", isPresented: $showLLMTransferAlert) {
            Button("确定") {}
        } message: {
            Text(llmTransferMessage)
        }
        .sheet(item: $editingTarget) { target in
            LLMConfigEditView(target: target) { saved in
                if target.activatesOnSave {
                    settingsVM.setActiveLLMConfig(saved)
                }
            }
        }
        .confirmationDialog(
            "确认删除该模型配置？",
            isPresented: $showDeleteConfigConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let config = configToDelete {
                    confirmDeleteLLMConfig(config)
                }
                configToDelete = nil
            }
            Button("取消", role: .cancel) {
                configToDelete = nil
            }
        } message: {
            if let config = configToDelete {
                Text("删除「\(config.name)」后不可恢复，其 API Key 将一并清除。")
            }
        }
    }

    // MARK: - LLM 配置删除

    /// 请求删除配置（弹确认对话框）
    private func requestDeleteLLMConfig(_ config: LLMConfig) {
        configToDelete = config
        showDeleteConfigConfirmation = true
    }

    /// 确认后执行删除。顺序：先清 Keychain，再删记录，最后转移激活态。
    ///
    /// 任一阶段失败都中止并报告阶段：不允许出现「界面看似删除、Keychain 仍残留
    /// 且无提示」。数据库失败时回滚挂起的删除，用户可原样重试。
    private func confirmDeleteLLMConfig(_ config: LLMConfig) {
        do {
            try LLMKeychainStore.removeAPIKey(for: config.id)
        } catch {
            settingsLogger.error("删除 LLM 配置失败：清除钥匙串条目出错（\(String(describing: error))）")
            settingsVM.errorMessage = String(
                format: String(localized: "删除配置失败：%@。配置未被删除，请重试。"),
                UserFacingError.summary(for: error)
            )
            settingsVM.showError = true
            return
        }
        modelContext.delete(config)
        do {
            try modelContext.save()
        } catch {
            // 回滚挂起的删除：否则该配置在界面已消失却仍留在库里，且无法重试
            modelContext.rollback()
            settingsLogger.error("删除 LLM 配置失败：数据库保存出错（\(String(describing: error))）")
            settingsVM.errorMessage = String(
                format: String(localized: "删除配置失败：%@。配置未被删除，请重试。"),
                UserFacingError.summary(for: error)
            )
            settingsVM.showError = true
            return
        }
        // 删除当前激活配置时，把激活态转移到剩余第一个配置，避免总结入口失效
        if settingsVM.activeLLMConfigID == config.id {
            settingsVM.activeLLMConfigID = llmConfigs.first { $0.id != config.id }?.id
            settingsVM.saveSettings()
        }
    }

    // MARK: - 大模型配置导入导出

    /// 导出：负载（含 API Key）用**本机密钥**加密后写盘，不向用户索取密码。
    /// 与转写/总结等本地文件同一套加密与密钥（Keychain，设备唯一），因此该文件只能在本机导入
    private func beginLLMExport() {
        do {
            let payload = try LLMConfig.transferPayload(from: llmConfigs)
            let ciphertext = try EncryptionService.encrypt(String(decoding: payload, as: UTF8.self))
            llmExportDocument = LLMConfigExportDocument(data: Data(ciphertext.utf8))
            showLLMExporter = true
        } catch {
            llmTransferMessage = String(format: String(localized: "导出失败：%@"), UserFacingError.summary(for: error))
            showLLMTransferAlert = true
        }
    }

    /// 导入：读文件 → 能解密则解密（本机导出的格式）→ 非密文则按明文解析（兼容旧版未加密导出）
    private func handleLLMImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            llmTransferMessage = String(format: String(localized: "导入失败：%@"), UserFacingError.summary(for: error))
            showLLMTransferAlert = true
        case .success(let urls):
            guard let url = urls.first else { return }
            // 选择面板返回的 URL 需要显式申请访问权限；读出内容后立即释放
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                llmTransferMessage = String(
                    format: String(localized: "导入失败：%@"),
                    String(localized: "无法读取所选文件")
                )
                showLLMTransferAlert = true
                return
            }
            do {
                applyImportedPayload(Data(try EncryptionService.decrypt(text).utf8))
            } catch EncryptionError.invalidCiphertext {
                // 非 Base64：旧版未加密导出，按明文解析
                applyImportedPayload(Data(text.utf8))
            } catch {
                // Base64 但解不开：密钥是本机 Keychain 唯一的，因此多为其他 Mac 导出；也可能是文件损坏
                llmTransferMessage = String(localized: "该文件无法在本机解密：可能由其他 Mac 导出，或文件已损坏。")
                showLLMTransferAlert = true
            }
        }
    }

    /// 解析负载并入库：配置以新身份落库、API Key 写入 Keychain（按新 id）；
    /// 原本没有激活配置时激活第一条。重复项按 Base URL + 模型标识跳过，
    /// 端点不安全的条目直接丢弃（与请求路径同一套校验）
    private func applyImportedPayload(_ payload: Data) {
        do {
            let (configs, apiKeys, outcome) = try LLMConfig.decodeTransfer(payload, existing: llmConfigs)
            var keyWriteFailures = 0
            if !configs.isEmpty {
                for config in configs {
                    modelContext.insert(config)
                    guard let apiKey = apiKeys[config.id] else { continue }
                    // Keychain 写失败不能静默：计入失败数，随导入结果一并告知用户
                    do {
                        try config.setAPIKey(apiKey)
                    } catch {
                        keyWriteFailures += 1
                        settingsLogger.error("导入 LLM 配置：写入钥匙串失败（\(String(describing: error))）")
                    }
                }
                try modelContext.save()
                if settingsVM.activeLLMConfigID == nil, let first = configs.first {
                    settingsVM.setActiveLLMConfig(first)
                }
            }
            var message = String(
                format: String(localized: "导入完成：新增 %lld、跳过重复 %lld、无效 %lld"),
                configs.count,
                outcome.skippedDuplicates,
                outcome.skippedInvalid
            )
            if keyWriteFailures > 0 {
                message += String(
                    format: String(localized: "；另有 %lld 个 API Key 未能写入钥匙串，请在配置中重新填写。"),
                    keyWriteFailures
                )
            }
            llmTransferMessage = message
        } catch is DecodingError {
            llmTransferMessage = String(localized: "文件格式不正确，请选择由本应用「导出配置…」生成的文件。")
        } catch {
            llmTransferMessage = String(format: String(localized: "导入失败：%@"), UserFacingError.summary(for: error))
        }
        showLLMTransferAlert = true
    }

    // MARK: - 关于
    private var aboutView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(verbatim: "Memozia").font(.largeTitle).fontWeight(.bold)
            Text(verbatim: "闻墨集").font(.title3).foregroundStyle(.secondary)
            Text(appVersion).font(.caption).foregroundStyle(.tertiary)
            if AppUpdateService.shared.isStarted {
                AppUpdateSettingsView()
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("专业模式", isOn: Binding(
                    get: { experienceStore.isPro },
                    set: { experienceStore.set($0 ? .pro : .standard) }
                ))
                .font(.headline)

                Text(experienceStore.isPro
                     ? String(localized: "已开放模型、声纹、词典、视频理解、录屏和高级数据管理。")
                     : String(localized: "使用自动配置和精简界面；录音、转写、总结、待办与安全保护保持可用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 8) {
                Label("会议录音：麦克风 + 系统音频", systemImage: "record.circle")
                Label("系统静音检测：跟随系统静音自动暂停", systemImage: "mic.slash")
                Label("快捷笔记：文字 / 图片即录即拆待办", systemImage: "note.text")
                Label("本地 WhisperKit + OpenAI API 双模式转写", systemImage: "waveform")
                Label("AI 待办拆解：一键写入系统提醒事项", systemImage: "checklist")
                Label("LM Studio / Ollama / 云端 API 总结", systemImage: "brain")
                Label("数据加密存储 + 数据文件夹位于文稿目录", systemImage: "lock.shield")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider()
                .frame(width: 240)

            // 隐私、帮助与反馈
            VStack(spacing: 12) {
                NavigationLink(value: DetailRoute.privacyPolicy) {
                    Label("隐私政策", systemImage: "hand.raised.fill")
                }
                Button {
                    showHelp = true
                } label: {
                    Label("使用帮助", systemImage: "questionmark.circle.fill")
                }
                .buttonStyle(.plain)
                if MemoziaContact.email != nil {
                    Button {
                        showFeedback = true
                    } label: {
                        Label("用户反馈", systemImage: "envelope.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.subheadline)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("关于")
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
    }
}
