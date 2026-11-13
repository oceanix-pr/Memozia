import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// 主框架视图 - NavigationSplitView 三栏/自适应布局
struct RootView: View {
    /// 持久化能力：由 StartupRootView 依启动结果注入（临时/正常）；默认 readWrite，
    /// 便于预览与未注入路径。临时模式下界面常驻不落盘横幅，并在视图、ViewModel、
    /// 文件与持久化服务三层统一拒绝写操作。
    var persistence: PersistenceGuard = .readWrite

    /// 是否以临时（内存）模式运行
    private var isTransientMode: Bool { persistence.capability.isTransient }

    @Environment(\.modelContext) private var modelContext
    // E1 侧边栏数据源说明：评估过把整表 @Query 改为按月/区间增量加载（先加载最近条目，
    // 展开旧月份再取下一页）。但列表的搜索（跨全库）、详情选中、空状态判据（hasVisibleListItems）
    // 与批量操作都依赖完整集合，分页会在无法运行时验证的情况下引入「旧条目/搜索结果查不到」
    // 的可见回归；当前已由列表侧「按月分组 + 默认仅展开当月」把行视图构建量收敛，故保守保留
    // 整表查询，未做分页（详见 docs/TECH_DEBT.md）。
    @Query(sort: \AudioRecording.createdAt, order: .reverse) private var recordings: [AudioRecording]
    @Query(sort: \QuickNote.createdAt, order: .reverse) private var quickNotes: [QuickNote]
    @Query private var llmConfigs: [LLMConfig]

    @State private var viewModel = RecordingViewModel()
    @State private var quickNoteVM = QuickNoteViewModel()
    @State private var settingsVM = SettingsViewModel()
    @State private var experienceStore = AppExperienceStore.shared
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDragTargeted = false
    /// 删除确认载荷（单选录音 / 单选快捷笔记 / 批量混合）
    ///
    /// 旧实现是三个布尔量 + 三个 confirmationDialog：混合选中时两个 isPresented
    /// 同帧置位会让 SwiftUI 只弹一个，另一类条目被静默跳过。改为单载荷后，
    /// 「同一时刻只有一个删除确认框」由类型保证，展示与否也由载荷派生
    /// （详见 Views/Root/RootDeletionRequest.swift）。
    @State private var pendingDeletion: RootDeletionRequest?
    @State private var pendingMerge: RecordingMergeRequest?
    @State private var pendingMediaCleanup: MediaCleanupRequest?
    @State private var mediaCleanupResult: String?

    /// 批量删除的目标集合（仅 pendingDeletion 的 kind 为 .batch 时有意义）
    @State private var recordingsToDelete: [AudioRecording] = []
    @State private var quickNotesToDelete: [QuickNote] = []

    /// 把「有待删除载荷」翻译成 confirmationDialog 需要的 isPresented；
    /// 关闭时统一清空载荷，杜绝「标记还在、载荷已空」这类中间态
    private var isShowingDeletionConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
    @State private var showCreateQuickNote = false
    @State private var showMediaImporter = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// 已完成引导页时记录的应用版本：升级到新版本后重新展示一次引导（新功能介绍）
    @AppStorage("onboardingCompletedVersion") private var onboardingCompletedVersion = ""

    /// 当前应用版本号（引导页升级重展示的判定依据）
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 取 "major.minor"（版本号段不足两位时按原样返回）
    static func majorMinorVersion(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// 是否需要在本次启动重新展示引导页：仅在主/次版本变化时为 true。
    /// 旧实现比较完整版本号，导致任何 patch 升级都会重弹 12 页引导打扰老用户
    static func onboardingNeedsRefresh(completed: String, current: String) -> Bool {
        let completedKey = majorMinorVersion(completed)
        guard !completedKey.isEmpty else { return true }
        return completedKey != majorMinorVersion(current)
    }
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.accepted) private var hasAcceptedPrivacyPolicy = false
    @AppStorage(MemoziaPrivacyPolicy.StorageKey.acceptedVersion) private var acceptedPrivacyVersion = ""
    /// 同意状态必须同时比对政策版本：只读布尔量会让“协议改了但老用户不再确认”的漏洞复发。
    private var needsPrivacyConsent: Bool {
        MemoziaPrivacyPolicy.needsConsent(
            accepted: hasAcceptedPrivacyPolicy,
            storedVersion: acceptedPrivacyVersion
        )
    }
    /// 录音徽章麦克风菜单选中的输入设备 UID（空 = 跟随系统默认）。
    /// 与设置页「录音 → 输入设备」、菜单栏「麦克风」、截图会话工具栏读写同一偏好，
    /// 改任一处，其余入口立即跟随
    @AppStorage(MicrophoneDeviceRegistry.selectionDefaultsKey) private var microphoneDeviceUID: String = ""
    @State private var showOnboarding = false
    @State private var showPrivacyConsent = false
    @State private var showHelp = false

    // MARK: - 一键处理预览（先看将执行/跳过的步骤，再入队）
    //
    // 旧实现点一下就把整串步骤投出去：其中转写会清空既有片段重建，
    // 用户手动改过的转写会被无声覆盖，已完成且不想重跑的步骤也会重复执行。
    /// 预览载荷（目标条目 + 状态快照），二者同生共死。
    /// 用 `.sheet(item:)` 承载：只有载荷存在才会展示 sheet，避免「展示标记已置位、
    /// 内容 state 尚未提交」时内容闭包读到空值，误显示「条目已不存在」。
    @State private var oneClickPreview: OneClickPreviewPayload?

    /// 当前选中的列表项集合（录音或快捷笔记）；Set 绑定启用列表多选（⌘/⇧ 点击）
    @State private var selectedListItems: Set<ListItem> = []

    /// P1-5: 当前正在编辑标题的条目 ID（替代 NotificationCenter 广播）
    @State private var editingItemID: String?

    // 导出相关状态（从 RecordingDetailView 迁移）
    /// 导出文件名基名（不含后缀/序号）：录音/录屏用文件名，快捷笔记（图片/文字）用标题
    @State private var exportBaseName = ""
    @State private var exportTranscriptDoc: MarkdownDocument?
    @State private var exportSummaryDoc: MarkdownDocument?
    @State private var showTranscriptExporter = false
    @State private var showSummaryExporter = false
    /// PDF 导出：转写与总结各用一份文档与开关，避免互相覆盖
    @State private var exportTranscriptPDFDoc: MarkdownPDFDocument?
    @State private var exportSummaryPDFDoc: MarkdownPDFDocument?
    @State private var showTranscriptPDFExporter = false
    @State private var showSummaryPDFExporter = false
    // MARK: - 临时模式（不落盘）写操作门控
    //
    // 未取得数据库独占锁 / 持久化容器创建失败时，用户可在启动界面二次确认后
    // 「以临时模式继续」：界面常驻不落盘横幅，且创建/导入/删除等写操作默认禁用，
    // 避免用户误以为改动已正常保存。

    /// 写操作门控：临时模式下拦截并给出统一提示；返回 true 表示已被拦截（调用方应 return）
    private func blockWriteIfPersistenceUnavailable(_ operation: PersistenceOperation) -> Bool {
        guard let blocked = persistence.rejection(for: operation) else { return false }
        viewModel.errorMessage = blocked.message
        viewModel.showError = true
        return true
    }

    /// 把持久化能力注入 ViewModel 与服务，作为视图级门控之外的边界兜底。
    /// 能力运行期不变，首次出现时执行一次即可。
    private func installPersistence() {
        viewModel.persistence = persistence
        quickNoteVM.persistence = persistence
        EntryMirrorStore.shared.capability = persistence.capability
        BackgroundTaskQueue.installCapability(persistence.capability)
    }

    /// 打开新建快捷笔记面板（受临时模式门控）
    private func requestCreateQuickNote() {
        guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
        showCreateQuickNote = true
    }

    /// 打开媒体导入面板（受临时模式门控）
    private func requestImportMedia() {
        guard !blockWriteIfPersistenceUnavailable(.importMedia) else { return }
        showMediaImporter = true
    }

    // 截图权限/错误非阻塞弹窗状态
    @State private var showScreenshotPermissionAlert = false
    @State private var showScreenshotErrorAlert = false
    @State private var screenshotErrorMessage = ""

    /// 一次性系统提示统一载荷（解密失败 / 加密未生效 / 保存失败）
    ///
    /// 三条提示此前各持一个布尔量 + 一份结构完全相同的 `.alert`，属于同一类
    /// 「必须看到、不会自动消失」的阻塞层。合并为单一通道后，展示与否由
    /// `systemNotice != nil` 派生，标题与正文集中在 `SystemNotice` 里统一校对
    /// （详见 Views/Root/SystemNotice.swift）。
    @State private var systemNotice: SystemNotice?

    // 磁盘同步结果反馈：顶部非模态横幅（手动刷新始终展示，启动同步仅展示有内容的场景）
    @State private var syncBannerText: String?
    @State private var syncBannerDismissTask: Task<Void, Never>?
    /// 横幅图标：同步用循环箭头，一次性结果（截图已复制/已保存）用对勾，
    /// 否则"已复制到剪贴板"旁边挂着刷新图标会让人误解
    @State private var syncBannerSymbol = "arrow.clockwise.circle.fill"
    @State private var syncBannerIsWarning = false
    /// 横幅上的可选动作（如「查看队列」）：入队成功后就近提供进度/取消入口
    @State private var syncBannerActionTitle: String?
    @State private var syncBannerAction: (() -> Void)?

    // body 链条过长会导致类型检查超时，拆为三层计算属性分层组合
    var body: some View {
        dialogLayers
        .disabled(MediaCleanupService.shared.isRunning)
        // 底部只保留常驻的临时模式提示；过程类反馈（导入/合并/清理）统一走顶部横幅
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                transientModeBanner
            }
        }
        // 录音实时告警与磁盘同步结果同级：同处顶部横幅层，位置与刷新反馈一致
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                syncResultBanner
                recordingWarningOverlay
            }
        }
        .animation(.easeInOut, value: syncBannerText)
        .animation(.easeInOut, value: viewModel.liveRecordingWarning)
        .animation(.easeInOut, value: viewModel.importProgressText)
        .animation(.easeInOut, value: MediaCleanupService.shared.isRunning)
        .animation(.easeInOut, value: RecordingMergeActivity.shared.isRunning)
        .animation(.easeInOut, value: viewModel.isMergingAudio)
        .animation(.easeInOut, value: viewModel.isMeetingRecording)
        .animation(.easeInOut, value: viewModel.isRecordingMuted)
        .onChange(of: viewModel.recordingFeedback?.id) { _, _ in handleRecordingFeedback() }
        .fileImporter(
            isPresented: $showMediaImporter,
            allowedContentTypes: AudioImportValidator.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importMediaFiles(urls)
            case .failure(let error):
                // 选择器失败（权限被拒 / 卷已卸载等）不能静默：否则用户点了没有任何反应
                viewModel.errorMessage = String(
                    format: String(localized: "导入失败：%@"),
                    error.localizedDescription
                )
                viewModel.showError = true
            }
        }
        .modifier(ExportModifiers(
            showTranscriptExporter: $showTranscriptExporter,
            exportTranscriptDoc: exportTranscriptDoc,
            showTranscriptPDFExporter: $showTranscriptPDFExporter,
            exportTranscriptPDFDoc: exportTranscriptPDFDoc,
            showSummaryExporter: $showSummaryExporter,
            exportSummaryDoc: exportSummaryDoc,
            showSummaryPDFExporter: $showSummaryPDFExporter,
            exportSummaryPDFDoc: exportSummaryPDFDoc,
            exportBaseName: exportBaseName
        ))
        .modifier(LifecycleTasksModifier(
            modelContext: modelContext,
            viewModel: viewModel,
            privacyAccepted: !needsPrivacyConsent,
            sttConfig: settingsVM.makeSTTConfig(experience: experienceStore.current),
            isTransientMode: isTransientMode,
            onSyncResult: { handleSyncResult($0, isManualRefresh: false) }
        ))
        .task { installPersistence() }
        // 一次性系统提示统一走 SystemNotice 通道（阻塞层，见 Views/Root/SystemNotice.swift），
        // 三条提示的标题与正文集中在枚举里，这里只负责把通知翻译成载荷
        // 解密失败：仅在检测到密钥异常时弹出，不改变现有布局
        .onReceive(
            NotificationCenter.default
                .publisher(for: EncryptionService.decryptionFailureNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            systemNotice = .decryptionFailed
        }
        // 加密失败：避免“UI 显示已加密、磁盘实为明文”静默发生
        .onReceive(
            NotificationCenter.default
                .publisher(for: EncryptionService.encryptionFailureNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            systemNotice = .encryptionIneffective
        }
        // 保存失败：写库异常原先被 `try?` 吞掉，界面看起来已经成功，重启才回退
        .onReceive(
            NotificationCenter.default
                .publisher(for: PersistenceReporting.saveFailureNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            systemNotice = .saveFailed
        }
        .systemNoticeLayer($systemNotice)
    }

    /// 视图层 1：主布局 + 文件导入 + 通知监听 + 首屏引导
    private var observerLayers: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .menuBarStartRecording)) { _ in
            handleMenuBarStartRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarStopRecording)) { _ in
            handleMenuBarStopRecording()
        }
        // 录音全局热键（设置 → 热键，默认 ⌃⌘R）：开/停切换，与工具栏「录音」按钮同一动作
        .onReceive(NotificationCenter.default.publisher(for: .recordingHotkeyPressed)) { _ in
            toggleMeetingRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarStartScreenRecording)) { notification in
            guard experienceStore.policy.allows(.screenRecording) else { return }
            handleMenuBarStartScreenRecording(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenRecordingTargetRequested)) { notification in
            // 统一捕获会话的录制出口：目标已由会话换算，直接走现有录屏链路
            guard experienceStore.policy.allows(.screenRecording) else { return }
            guard let target = notification.userInfo?["target"] as? ScreenRecordingTarget else { return }
            startScreenRecording(target: target)
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotHotkeyPressed)) { _ in
            ScreenshotManager.shared.startCapture(mode: effectiveScreenshotMode())
        }
        .onReceive(NotificationCenter.default.publisher(for: .fullscreenScreenshotHotkeyPressed)) { _ in
            guard experienceStore.policy.allows(.advancedCapture) else { return }
            ScreenshotManager.shared.captureFullScreenDirect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarStartScreenshot)) { notification in
            let modeRaw = notification.userInfo?["mode"] as? String ?? ScreenshotManager.CaptureMode.region.rawValue
            let effectiveRaw = EffectiveSettingsResolver.screenshotMode(
                savedRawValue: modeRaw,
                experience: experienceStore.current
            )
            let mode = ScreenshotManager.CaptureMode(rawValue: effectiveRaw) ?? .region
            ScreenshotManager.shared.startCapture(mode: mode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarStartDelayedScreenshot)) { notification in
            guard experienceStore.policy.allows(.advancedCapture) else { return }
            let modeRaw = notification.userInfo?["mode"] as? String ?? ScreenshotManager.CaptureMode.region.rawValue
            let mode = ScreenshotManager.CaptureMode(rawValue: modeRaw) ?? .region
            let delay = notification.userInfo?["delay"] as? Int ?? 3
            ScreenshotManager.shared.startCapture(mode: mode, delay: delay)
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotCaptureSaved)) { notification in
            handleScreenshotSaved(userInfo: notification.userInfo)
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotPermissionNeeded)) { _ in
            showScreenshotPermissionAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotErrorOccurred)) { notification in
            screenshotErrorMessage = notification.userInfo?["message"] as? String ?? String(localized: "未知错误")
            showScreenshotErrorAlert = true
        }
        // 截图一次性结果提示 + 应用菜单 ⌘N/⌘O 走同一个桥接 modifier。
        // 刻意合并成单个链接：`observerLayers` 的视图链已逼近 Swift 类型检查上限，
        // 每多挂一个 `.modifier(...)` 都可能让整个 body 编译超时
        .modifier(RootViewBridgeModifier(
            onScreenshotNotice: { message in
                syncBannerSymbol = "checkmark.circle.fill"
                showTransientBanner(message)
            },
            onNewQuickNote: { requestCreateQuickNote() },
            onImportMedia: { requestImportMedia() }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .menuBarOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarCreateQuickNoteFromClipboard)) { _ in
            guard experienceStore.policy.allows(.advancedCapture) else { return }
            guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
            if let note = quickNoteVM.createQuickNoteFromClipboard(context: modelContext) {
                selectedListItems = [.quickNote(note)]
            } else if quickNoteVM.showError {
                // 错误已通过 alert 展示
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHelp)) { _ in
            showHelp = true
        }
        #endif
        .onAppear {
            if needsPrivacyConsent {
                showPrivacyConsent = true
            } else if !hasCompletedOnboarding {
                showOnboarding = true
            } else if Self.onboardingNeedsRefresh(
                completed: onboardingCompletedVersion,
                current: Self.currentAppVersion
            ) {
                // 主/次版本升级（如 6.0.0 新增截图）：重新展示一次引导页介绍新功能；
                // patch 升级不再重弹
                showOnboarding = true
            }
        }
        .onChange(of: experienceStore.current) { _, _ in
            // 模式切换不修改任何已保存的 Pro 配置，只刷新当前可用入口。
            let visibleSelection = selectedListItems.filter(isSelectionVisible)
            if experienceStore.policy.allows(.batchOperations) {
                selectedListItems = Set(visibleSelection)
            } else {
                selectedListItems = Set(visibleSelection.prefix(1))
            }
            #if os(macOS)
            MenuBarController.shared.refreshForExperienceChange()
            GlobalHotkeyManager.shared.refreshForExperienceChange()
            #endif
        }
    }

    /// 视图层 2：Sheet 与 Alert 弹窗
    private var sheetAndAlertLayers: some View {
        observerLayers
        .sheet(isPresented: $showPrivacyConsent) {
            PrivacyConsentView()
                .interactiveDismissDisabled()
                .onDisappear {
                    // 直接读 UserDefaults：@AppStorage 的通知可能晚于 sheet 关闭回调，
                    // 用静态判断保证“刚同意的新用户”能立即进入引导页。
                    if !MemoziaPrivacyPolicy.needsConsent() && !hasCompletedOnboarding {
                        showOnboarding = true
                    }
                }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSettings) {
            settingsSheetContent
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .alert("错误", isPresented: $viewModel.showError) {
            if let folder = viewModel.recordingFailureFolder {
                Button("在 Finder 中显示") {
                    viewModel.recordingFailureFolder = nil
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            Button("确定") { viewModel.recordingFailureFolder = nil }
        } message: {
            // 兜底串必须先本地化：`String` 直接传给 Text 会走 verbatim 重载，不查 String Catalog
            let errorMsg = viewModel.errorMessage ?? String(localized: "未知错误")
            Text(errorMsg)
        }
        .alert("需要屏幕录制权限", isPresented: $showScreenshotPermissionAlert) {
            Button("打开系统设置") {
                #if os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Memozia，然后重新触发截图。")
        }
        .alert("截图失败", isPresented: $showScreenshotErrorAlert) {
            Button("确定") {}
        } message: {
            Text(screenshotErrorMessage)
        }
    }

    /// 视图层 3：删除确认对话框 + 新建笔记 Sheet + 错误提示
    private var dialogLayers: some View {
        sheetAndAlertLayers
        .alert(Text(pendingMediaCleanup?.kind.title ?? ""), isPresented: Binding(
            get: { pendingMediaCleanup != nil },
            set: { if !$0 { pendingMediaCleanup = nil } }
        ), presenting: pendingMediaCleanup) { request in
            Button("确定", role: .destructive) {
                pendingMediaCleanup = nil
                Task {
                    do {
                        let result = try await MediaCleanupService.shared.cleanup(request, context: modelContext, persistence: persistence)
                        mediaCleanupResult = result.message
                    } catch {
                        mediaCleanupResult = UserFacingError.summary(for: error)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingMediaCleanup = nil }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: Binding(
            get: { mediaCleanupResult != nil },
            set: { if !$0 { mediaCleanupResult = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text("媒体清理").font(.headline)
                ScrollView {
                    Text(mediaCleanupResult ?? "")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("确定") { mediaCleanupResult = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 480, idealWidth: 600, minHeight: 240, idealHeight: 420)
        }
        .confirmationDialog("合并录音？", isPresented: Binding(
            get: { pendingMerge != nil },
            set: { if !$0 { pendingMerge = nil } }
        ), titleVisibility: .visible, presenting: pendingMerge) { request in
            Button("合并录音", role: .destructive) {
                pendingMerge = nil
                Task {
                    if let merged = await viewModel.mergeRecordings(request.recordings, context: modelContext) {
                        selectedListItems = [.recording(merged)]
                    }
                }
            }
            Button("取消", role: .cancel) { pendingMerge = nil }
        } message: { request in
            Text(request.message)
        }
        // 删除确认唯一出口：单选录音 / 单选笔记 / 批量混合各给对应按钮，
        // 标题与正文来自载荷（提出请求时已固定），动作按 kind 分流。
        // 旧实现三个 isPresented 并存，混合选中时会静默跳过一类条目。
        .confirmationDialog(
            Text(pendingDeletion?.title ?? ""),
            isPresented: isShowingDeletionConfirmation,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            switch request.kind {
            case .recording(let recording):
                Button("删除", role: .destructive) {
                    guard !blockWriteIfPersistenceUnavailable(.deleteEntry) else {
                        pendingDeletion = nil
                        return
                    }
                    viewModel.deleteRecording(recording, context: modelContext)
                    // 从多选集合中移除被删除的录音
                    selectedListItems = selectedListItems.filter { item in
                        if case .recording(let selected) = item { return selected.id != recording.id }
                        return true
                    }
                    pendingDeletion = nil
                }
            case .quickNote(let note):
                Button("删除", role: .destructive) {
                    guard !blockWriteIfPersistenceUnavailable(.deleteEntry) else {
                        pendingDeletion = nil
                        return
                    }
                    quickNoteVM.deleteQuickNote(note, context: modelContext)
                    // 从多选集合中移除被删除的笔记
                    selectedListItems = selectedListItems.filter { item in
                        if case .quickNote(let selected) = item { return selected.id != note.id }
                        return true
                    }
                    pendingDeletion = nil
                }
            case .batch:
                // 混合选中时按类型各给一个破坏性按钮，两个都执行也不会互相顶掉
                if !recordingsToDelete.isEmpty {
                    Button("删除 \(recordingsToDelete.count) 个录音", role: .destructive) {
                        deleteSelectedRecordings()
                    }
                }
                if !quickNotesToDelete.isEmpty {
                    Button("删除 \(quickNotesToDelete.count) 个快捷笔记", role: .destructive) {
                        deleteSelectedQuickNotes()
                    }
                }
            }
            Button("取消", role: .cancel) {
                clearBatchDeleteSelection()
            }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $showCreateQuickNote) {
            CreateQuickNoteSheet { text in
                if let note = quickNoteVM.createQuickNote(from: text, context: modelContext) {
                    selectedListItems = [.quickNote(note)]
                }
                showCreateQuickNote = false
            } onCreateFromImage: {
                if let note = quickNoteVM.createQuickNoteFromClipboard(context: modelContext) {
                    selectedListItems = [.quickNote(note)]
                }
                showCreateQuickNote = false
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
            #endif
        }
        .alert("错误", isPresented: $quickNoteVM.showError) {
            Button("确定") {}
        } message: {
            Text(quickNoteVM.errorMessage ?? String(localized: "未知错误"))
        }
        // 一键处理预览：确认后入队（含「重新转写」是否覆盖已有转写、云端数据范围）
        .sheet(item: $oneClickPreview) { payload in
            OneClickPreviewView(
                entryTitle: payload.item.title,
                inputs: payload.inputs
            ) { plan in
                enqueueOneClick(payload.item, plan: plan)
            }
        }
    }

    /// 侧边栏视图
    @ViewBuilder
    private var sidebarView: some View {
        RecordingListView(
            recordings: recordings,
            quickNotes: quickNotes,
            selectedListItems: $selectedListItems,
            onCreateQuickNote: { requestCreateQuickNote() },
            onImportMedia: { requestImportMedia() },
            onScreenshot: {
                ScreenshotManager.shared.startCapture(mode: effectiveScreenshotMode())
            },
            onDeleteRecording: { recording in
                pendingDeletion = .recording(recording)
            },
            onDeleteQuickNote: { note in
                pendingDeletion = .quickNote(note)
            },
            onRecordingTitleChange: { recording, newTitle in
                viewModel.updateRecordingTitle(recording, newTitle: newTitle, context: modelContext)
            },
            onQuickNoteTitleChange: { note, newTitle in
                quickNoteVM.updateTitle(note, newTitle: newTitle, context: modelContext)
            },
            experience: experienceStore.current,
            showHiddenRecordings: effectiveShowHiddenRecordings,
            allowsMultipleSelection: experienceStore.policy.allows(.batchOperations),
            editingItemID: $editingItemID,
            onRefresh: {
                let result = await FileSyncService.syncFromDisk(
                    context: modelContext,
                    excludeFolderNames: MeetingRecorderService.shared.activeRecordingFolderNames
                )
                handleSyncResult(result, isManualRefresh: true)
            },
            isMeetingRecording: viewModel.isMeetingRecording,
            contextMenuContent: { items in
                AnyView(contextMenuContent(for: items).disabled(MediaCleanupService.shared.isRunning))
            },
            onToggleMeetingRecording: {
                #if os(macOS)
                toggleMeetingRecording()
                #endif
            }
        )
        // 列表栏默认拉到最宽（ideal = max），用户仍可拖窄
        .navigationSplitViewColumnWidth(min: 240, ideal: 400, max: 400)
        #if os(macOS)
        .overlay {
            if isDragTargeted {
                dragOverlayView
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
        #endif
    }

    /// 按当前“显示隐藏”开关计算列表中是否还有可见条目
    private var hasVisibleListItems: Bool {
        let showHidden = effectiveShowHiddenRecordings
        return recordings.contains { showHidden || !$0.isHidden }
            || quickNotes.contains { showHidden || !$0.isHidden }
    }

    /// 指定选中项在现有过滤条件下是否可见（被隐藏的选中项不应再展示详情）
    private func isSelectionVisible(_ item: ListItem) -> Bool {
        let showHidden = effectiveShowHiddenRecordings
        switch item {
        case .recording(let recording): return showHidden || !recording.isHidden
        case .quickNote(let note):       return showHidden || !note.isHidden
        }
    }

    /// 普通模式不暴露隐藏条目；切回 Pro 后恢复用户原先保存的显示偏好。
    private var effectiveShowHiddenRecordings: Bool {
        experienceStore.policy.allows(.hiddenItems) && settingsVM.showHiddenRecordings
    }

    /// 普通模式统一进入最容易理解的区域截图；不会覆盖 Pro 保存的默认截图方式。
    private func effectiveScreenshotMode() -> ScreenshotManager.CaptureMode {
        let savedRaw = UserDefaults.standard.string(forKey: "screenshotDefaultMode")
            ?? ScreenshotManager.CaptureMode.region.rawValue
        let effectiveRaw = EffectiveSettingsResolver.screenshotMode(
            savedRawValue: savedRaw,
            experience: experienceStore.current
        )
        return ScreenshotManager.CaptureMode(rawValue: effectiveRaw) ?? .region
    }

    /// 详情视图（按列表项类型分流）
    private var detailView: some View {
        detailContent
            // 会议录音状态徽章常驻详情列顶部工具栏，替代原先的底部悬浮条
            .toolbar {
                if viewModel.isMeetingRecording {
                    ToolbarItem(placement: .principal) {
                        recordingStatusBadge
                    }
                }
                // 右上角处理队列入口（下载模型 / 转写 / 总结 / 润色标题 / 画面分析 / 拆解待办）。
                // 外观交给系统工具栏原生渲染（不自绘背景、不隐藏共享背景）
                ToolbarItem(placement: .primaryAction) {
                    QueueToolbarButton()
                }
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        if !hasVisibleListItems {
            // 列表无任何可见条目（真空或条目被全部隐藏）：旧实现返回 `Color.clear`，
            // 右侧是一片纯空白——用户既不知道能做什么，也看不到任何入口。
            // 补齐标题、说明与两个动作（文案沿用工具栏既有按钮，避免新增未翻译键）。
            ContentUnavailableView {
                Label("暂无条目", systemImage: "tray")
            } description: {
                Text("导入音频或视频，或新建快捷笔记开始使用（条目被隐藏时可切换「显示隐藏条目」找回）")
            } actions: {
                Button("导入", systemImage: "square.and.arrow.down") { requestImportMedia() }
                Button("笔记", systemImage: "text.pad.header.badge.plus") { requestCreateQuickNote() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedListItems.count > 1 {
            // 多选：不展示单条详情，提示当前选中数量
            ContentUnavailableView(
                "已选中 \(selectedListItems.count) 个条目",
                systemImage: "checkmark.circle.badge.checkmark",
                description: Text("按住 ⌘ 或 ⇧ 点击可多选；右键可批量隐藏或删除")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = selectedListItems.first, isSelectionVisible(item) {
            switch item {
            case .recording(let recording):
                RecordingDetailView(
                    recording: recording,
                    viewModel: viewModel,
                    settingsVM: settingsVM,
                    llmConfigs: llmConfigs,
                    experience: experienceStore.current,
                    onTranscribe: { startTranscriptionFor(recording) },
                    onCancelTranscription: { viewModel.cancelTranscription() },
                    onOneClick: { presentOneClickPreview(item) },
                    onCleanupAudio: { presentMediaCleanup(.audio, items: [item]) }
                )
                // 详情页展示的条目即「当前展示条目」：同步到 ViewModel，
                // 只有它才把流式内容与进行中态写入共享 UI 状态（避免后台另一条目串数据）
                .onAppear { syncDetailSelection() }
                .onChange(of: recording.id) { _, _ in syncDetailSelection() }
            case .quickNote(let note):
                QuickNoteDetailView(
                    quickNote: note,
                    viewModel: quickNoteVM,
                    llmConfigs: llmConfigs,
                    // 全局模型选择：详情页选中的模型写回「活动大模型配置」并持久化，
                    // 因此「生成总结 / 拆解待办 / 一键处理 / 队列执行」跟着同一份配置，
                    // 重开笔记或重启应用后选择保持一致。
                    // 旧实现 setter 为空（`{ _ in }`）：选择器看着能改，实际点什么都不会生效。
                    selectedLLMConfig: Binding(
                        get: { settingsVM.getActiveLLMConfig(from: llmConfigs) },
                        set: { config in
                            guard let config else { return }
                            settingsVM.setActiveLLMConfig(config)
                        }
                    ),
                    defaultReminderListID: settingsVM.defaultReminderListID,
                    isProMode: experienceStore.isPro,
                    onOneClick: { presentOneClickPreview(item) },
                    onCleanupImage: { presentMediaCleanup(.image, items: [item]) }
                )
                .onAppear { syncDetailSelection() }
                .onChange(of: note.id) { _, _ in syncDetailSelection() }
            }
        } else {
            // 空状态：Slogan 压在「选择一个录音或笔记」之上。图标与标题仍交给 ContentUnavailableView
            // 的标准排版（label 闭包里嵌套的 Label 会沿用同一套样式），文案走 Localizable.xcstrings
            ContentUnavailableView {
                VStack(spacing: 10) {
                    Text("Memozia · 闻墨集")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Label("选择一个条目", systemImage: "tray")
                }
            } description: {
                Text("从左侧列表选择，或导入音视频、新建笔记")
            } actions: {
                // 旧实现在这里放 `EmptyView()`：文案让用户"点击工具栏新建"却不给可点入口
                Button("导入", systemImage: "square.and.arrow.down") { requestImportMedia() }
                Button("笔记", systemImage: "text.pad.header.badge.plus") { requestCreateQuickNote() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - 会议录音控制（macOS）

    #if os(macOS)
    /// 切换会议录音状态
    private func toggleMeetingRecording() {
        guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
        if viewModel.isMeetingRecording {
            Task {
                // 录屏与录音共用停止链路；声源用本次实际选择，不取设置默认值
                let source = viewModel.activeRecordingSource ?? settingsVM.recordingSource
                await viewModel.stopMeetingRecording(context: modelContext, source: source)
            }
        } else {
            let config = settingsVM.makeRecordingConfig(experience: experienceStore.current)
            viewModel.startMeetingRecording(config: config, context: modelContext)
        }
    }

    /// 菜单栏请求开始录音
    private func handleMenuBarStartRecording() {
        guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
        guard !viewModel.isMeetingRecording else { return }
        let config = settingsVM.makeRecordingConfig(experience: experienceStore.current)
        viewModel.startMeetingRecording(config: config, context: modelContext)
    }

    /// 菜单栏请求停止录音（也是菜单栏退出前的收尾入口）。
    /// 完成后回发 `.menuBarStopRecordingCompleted`：退出流程据此确认
    /// 「封存 + 合并 + 入库」已完成再终止进程，避免退出跳过入库
    private func handleMenuBarStopRecording() {
        guard viewModel.isMeetingRecording else {
            NotificationCenter.default.post(name: .menuBarStopRecordingCompleted, object: nil)
            return
        }
        Task {
            let source = viewModel.activeRecordingSource ?? settingsVM.recordingSource
            await viewModel.stopMeetingRecording(context: modelContext, source: source)
            NotificationCenter.default.post(name: .menuBarStopRecordingCompleted, object: nil)
        }
    }

    /// 菜单栏/工具栏请求开始录屏（userInfo target：fullScreen / region / window）
    private func handleMenuBarStartScreenRecording(_ notification: Notification) {
        guard experienceStore.policy.allows(.screenRecording) else { return }
        guard let raw = notification.userInfo?["target"] as? String else { return }
        beginScreenRecording(targetRaw: raw)
    }

    /// 录屏入口（统一捕获版）：
    /// - fullScreen：保持一步直达（无会话），鼠标所在屏直接开录
    /// - region / window：进入带录制出口的捕获会话（intent = record），
    ///   选定目标后自动 3 秒倒计时开录；出口完全自由（可改存截图/复制/钉住）；
    ///   窗口目标由悬停拾取升级为独立窗口录制，不再走列表 Sheet
    private func beginScreenRecording(targetRaw raw: String) {
        guard let kind = ScreenTargetKind(rawValue: raw) else { return }
        switch kind {
        case .fullScreen:
            startScreenRecording(target: .mouseDisplay)
        case .region:
            ScreenshotManager.shared.startCapture(mode: .region, intent: .record)
        case .window:
            ScreenshotManager.shared.startCapture(mode: .window, intent: .record)
        }
    }

    /// 真正启动录屏：声源/质量读自录屏偏好（菜单栏「捕获屏幕」与设置页共用），
    /// 互斥不再静默：录音/录屏进行中给出明确提示
    private func startScreenRecording(target: ScreenRecordingTarget) {
        guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
        guard !viewModel.isMeetingRecording else {
            viewModel.errorMessage = String(localized: "正在录音/录屏，请先停止后再开始新的录屏。")
            viewModel.showError = true
            return
        }
        guard RegionSelectionController.shared.isIdle else {
            // 防御：会话进行中从菜单直达开录会把冻结层录进视频
            viewModel.errorMessage = String(localized: "捕获会话进行中，请先完成或取消当前会话再开始录屏。")
            viewModel.showError = true
            return
        }
        viewModel.startScreenRecording(
            target: target,
            source: ScreenRecordingQuality.savedSource(),
            quality: ScreenRecordingQuality.saved(),
            context: modelContext
        )
    }
    #endif
    
    /// 设置弹窗内容
    @ViewBuilder
    private var settingsSheetContent: some View {
        SettingsView(isTransientMode: isTransientMode, settingsVM: settingsVM, experienceStore: experienceStore)
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 500)
            #else
            /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
            .presentationDetents([.medium, .large])
            */
            #endif
    }
    
    /// 上下文菜单内容
    @ViewBuilder
    private func contextMenuContent(for items: Set<ListItem>) -> some View {
        // 分流录音与快捷笔记
        let recordingItems = items.compactMap { item -> AudioRecording? in
            if case .recording(let r) = item { return r }
            return nil
        }
        let quickNoteItems = items.compactMap { item -> QuickNote? in
            if case .quickNote(let n) = item { return n }
            return nil
        }

        // 批量转写/总结入口已移除：单条转写在转写页，总结在总结页

        if items.count == 1, let item = items.first {
            // 一键处理：先出预览（列出将执行/跳过的步骤与云端数据范围），确认后再入队
            Button {
                presentOneClickPreview(item)
            } label: {
                Label("一键处理", systemImage: "wand.and.stars")
            }
            Divider()
            // 单选：按类型显示不同菜单
            switch item {
            case .recording(let recording):
                Button {
                    editingItemID = item.id
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                #if os(macOS)
                Button {
                    let url = recording.folderName.isEmpty
                        ? recording.fileURL
                        : recording.folderURL
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在Finder中显示", systemImage: "folder")
                }
                #endif

                Menu {
                    if recording.transcriptionStatus == .completed {
                        // 只取 Sendable 快照（排序 + 原始密文），解密与拼装在后台完成：
                        // 旧实现把整篇 Markdown 的构建放在按钮 action 里（主线程）
                        let snapshot = recording.transcriptSnapshot
                        Button("复制转写文本") {
                            // 带说话人与时间段的 Markdown（与总结 prompt 同源），非纯文本拼接
                            withBuiltText({ AudioRecording.transcriptMarkdown(from: snapshot) }) { text in
                                copyToClipboard(text)
                            }
                        }
                        Button("导出转写为 .md") {
                            let name = recording.fileName
                            withBuiltText({ AudioRecording.transcriptMarkdown(from: snapshot) }) { text in
                                exportBaseName = name
                                exportTranscriptDoc = MarkdownDocument(text: text)
                                showTranscriptExporter = true
                            }
                        }
                        Button("导出转写为 .pdf") {
                            let name = recording.fileName
                            withBuiltText({ AudioRecording.transcriptMarkdown(from: snapshot) }) { text in
                                exportBaseName = name
                                exportPDF(markdown: text, title: name, to: .transcript)
                            }
                        }
                    }
                    // 是否已有总结改用非解密判据：旧实现在菜单构建时解密一次，
                    // 等于右键打开菜单就触发一次主线程 AES-GCM
                    let encryptedSummary = recording.summary ?? ""
                    if !encryptedSummary.isEmpty {
                        Button("复制总结内容") {
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                copyToClipboard(text)
                            }
                        }
                        Button("导出总结为 .md") {
                            let name = recording.fileName
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                exportBaseName = name
                                exportSummaryDoc = MarkdownDocument(text: text)
                                showSummaryExporter = true
                            }
                        }
                        Button("导出总结为 .pdf") {
                            let name = recording.fileName
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                exportBaseName = name
                                exportPDF(markdown: text, title: name, to: .summary)
                            }
                        }
                    }
                    if FileManager.default.fileExists(atPath: recording.fileURL.path) {
                        Button("导出原始录音") {
                            // 直接在主窗口上弹系统分享面板；
                            // sheet 包 NSSharingServicePicker 会因零尺寸 NSView 呈现空白弹窗
                            presentSharingPicker(for: recording.fileURL)
                        }
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }

                if experienceStore.isPro {
                    Button {
                        polishTitle(for: item)
                    } label: {
                        Label("润色标题", systemImage: "wand.and.stars")
                    }

                    Button {
                        viewModel.toggleRecordingHidden(recording, context: modelContext)
                    } label: {
                        Label(recording.isHidden ? "取消隐藏" : "隐藏",
                              systemImage: recording.isHidden ? "eye" : "eye.slash")
                    }
                }

                Button(role: .destructive) {
                    pendingDeletion = .recording(recording)
                } label: {
                    Label("删除", systemImage: "trash")
                }

                mediaCleanupMenu(for: items)

            case .quickNote(let note):
                Button {
                    editingItemID = item.id
                } label: {
                    Label("重命名", systemImage: "pencil")
                }

                #if os(macOS)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([note.folderURL])
                } label: {
                    Label("在Finder中显示", systemImage: "folder")
                }
                #endif

                // 导出：与录音/录屏同一套出口（同一份导出面板状态），文件基名用笔记标题。
                // 图片/文字笔记的唯一导出物是总结，故只列总结项；没有总结时不展示空菜单。
                // 判据与解密都改为"不解密判空 + 后台解密"，避免右键即触发主线程 AES-GCM
                let encryptedSummary = note.summaryText ?? ""
                if !encryptedSummary.isEmpty {
                    Menu {
                        Button("复制总结内容") {
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                copyToClipboard(text)
                            }
                        }
                        Button("导出总结为 .md") {
                            let title = note.title
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                exportBaseName = title
                                exportSummaryDoc = MarkdownDocument(text: text)
                                showSummaryExporter = true
                            }
                        }
                        Button("导出总结为 .pdf") {
                            let title = note.title
                            withBuiltText({ EncryptionService.decryptSafely(encryptedSummary) }) { text in
                                exportBaseName = title
                                exportPDF(markdown: text, title: title, to: .summary)
                            }
                        }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }

                if experienceStore.isPro {
                    Button {
                        polishTitle(for: item)
                    } label: {
                        Label("润色标题", systemImage: "wand.and.stars")
                    }

                    Button {
                        note.isHidden.toggle()
                        note.saveMetaToFolder()
                        do {
                            try modelContext.save()
                        } catch {
                            quickNoteVM.errorMessage = String(localized: "隐藏状态保存失败，请重试。")
                            quickNoteVM.showError = true
                        }
                    } label: {
                        Label(note.isHidden ? "取消隐藏" : "隐藏",
                              systemImage: note.isHidden ? "eye" : "eye.slash")
                    }
                }

                Button(role: .destructive) {
                    pendingDeletion = .quickNote(note)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                mediaCleanupMenu(for: items)
            }
        } else if !items.isEmpty && experienceStore.policy.allows(.batchOperations) {
            if quickNoteItems.isEmpty,
               let ordered = RecordingViewModel.orderedMergeCandidates(recordingItems) {
                Button {
                    pendingMerge = RecordingMergeRequest(recordings: ordered)
                } label: {
                    Label("合并录音", systemImage: "waveform.path.badge.plus")
                }
                Divider()
            }
            // 多选：隐藏/删除
            Button {
                for item in items {
                    switch item {
                    case .recording(let recording):
                        viewModel.toggleRecordingHidden(recording, context: modelContext)
                    case .quickNote(let note):
                        note.isHidden.toggle()
                        note.saveMetaToFolder()
                    }
                }
                do {
                    try modelContext.save()
                } catch {
                    viewModel.errorMessage = String(localized: "隐藏状态保存失败，请重试。")
                    viewModel.showError = true
                }
            } label: {
                let allHidden = items.allSatisfy { $0.isHidden }
                Label(allHidden ? "取消隐藏选中条目" : "隐藏选中条目",
                      systemImage: allHidden ? "eye" : "eye.slash")
            }

            // 多选删除：录音与快捷笔记走同一个确认载荷（见批量删除 MARK）
            Button(role: .destructive) {
                recordingsToDelete = recordingItems
                quickNotesToDelete = quickNoteItems
                guard !recordingsToDelete.isEmpty || !quickNotesToDelete.isEmpty else { return }
                pendingDeletion = .batch(recordings: recordingsToDelete, quickNotes: quickNotesToDelete)
            } label: {
                Label("删除选中的 \(items.count) 个条目", systemImage: "trash")
            }
            mediaCleanupMenu(for: items)
        }
    }

    @ViewBuilder
    private func mediaCleanupMenu(for items: Set<ListItem>) -> some View {
        let cleanupItems = MediaCleanupRequest.contextSelection(items: items, selection: selectedListItems)
        if experienceStore.isPro && !cleanupItems.isEmpty {
            Button(role: .destructive) {
                presentMediaCleanup(.originals, items: cleanupItems)
            } label: {
                Label("清理源件", systemImage: "trash.slash")
            }
            .disabled(isTransientMode || MediaCleanupService.shared.isRunning)
        }
    }

    private func presentMediaCleanup(_ kind: MediaCleanupRequest.Kind, items: Set<ListItem>) {
        guard !blockWriteIfPersistenceUnavailable(.deleteEntry) else { return }
        pendingMediaCleanup = MediaCleanupRequest(kind: kind, items: items)
        if pendingMediaCleanup == nil { mediaCleanupResult = String(localized: "所选条目没有可清理的源件。") }
    }

    // MARK: - 批量删除（录音 + 快捷笔记共用同一确认载荷）

    // 批量删除的标题与正文已随载荷在「提出请求」时算好
    // （见 RootDeletionRequest.batch(recordings:quickNotes:)）：
    // 动作执行会清空目标集合，若文案届时再重算会落到默认分支。

    private func deleteSelectedRecordings() {
        guard !blockWriteIfPersistenceUnavailable(.deleteEntry) else {
            clearBatchDeleteSelection()
            return
        }
        for recording in recordingsToDelete {
            viewModel.deleteRecording(recording, context: modelContext)
        }
        viewModel.selectedRecording = nil
        // 从多选集合中移除被删除的录音（保留其余选中项）
        selectedListItems = selectedListItems.filter { item in
            if case .recording(let selected) = item {
                return !recordingsToDelete.contains { $0.id == selected.id }
            }
            return true
        }
        recordingsToDelete = []
    }

    private func deleteSelectedQuickNotes() {
        guard !blockWriteIfPersistenceUnavailable(.deleteEntry) else {
            clearBatchDeleteSelection()
            return
        }
        for note in quickNotesToDelete {
            quickNoteVM.deleteQuickNote(note, context: modelContext)
        }
        // 从多选集合中移除被删除的快捷笔记（保留其余选中项）
        selectedListItems = selectedListItems.filter { item in
            if case .quickNote(let selected) = item {
                return !quickNotesToDelete.contains { $0.id == selected.id }
            }
            return true
        }
        quickNotesToDelete = []
    }

    /// 清空批量删除目标并收起确认框（取消、临时模式拦截旁路、动作完成都收口到这里）
    private func clearBatchDeleteSelection() {
        recordingsToDelete = []
        quickNotesToDelete = []
        pendingDeletion = nil
    }

    // MARK: - 后台构建可导出文本

    /// 在后台构建文本、回主线程执行动作。
    /// 右键菜单里的"复制转写文本 / 导出 .md / 导出 .pdf"旧实现直接在按钮 action 里
    /// 拼整篇 Markdown（排序 + 逐段 AES-GCM 解密）或解密整篇总结——长会议是数十毫秒到
    /// 数百毫秒的主线程阻塞。传入的 `build` 只捕获 Sendable 快照，不触碰 `@Model`。
    private func withBuiltText(
        _ build: @escaping @Sendable () -> String,
        perform: @escaping @MainActor (String) -> Void
    ) {
        let buildTask = Task.detached(priority: .userInitiated) { build() }
        Task { @MainActor in
            let text = await buildTask.value
            perform(text)
        }
    }

    // MARK: - 润色标题（右键入口，录音/笔记/截图共用）

    /// 用当前选中的大模型配置润色条目标题；未配置模型时提示到设置中选择
    private func polishTitle(for item: ListItem) {
        // 统一投递到处理队列（内部会解析活动大模型配置并给出未配置提示）
        enqueueTitle(item)
    }

    // MARK: - 截图入库（macOS）

    #if os(macOS)
    /// 捕获会话保存截图 → 作为图片笔记入库并选中（不触发 OCR，不单独分类）
    private func handleScreenshotSaved(userInfo: [AnyHashable: Any]?) {
        guard !blockWriteIfPersistenceUnavailable(.createEntry) else { return }
        guard let userInfo,
              let originalPNG = (userInfo["originalPNG"] as? ScreenshotPayloadBox)?.data else { return }
        // 优先使用标注版（用户标注的最终产物），无标注时用原图
        let imageToSave = (userInfo["markedPNG"] as? ScreenshotPayloadBox)?.data ?? originalPNG
        if let note = quickNoteVM.createQuickNote(fromImage: imageToSave, context: modelContext) {
            selectedListItems = [.quickNote(note)]
        }
    }
    #endif

    // MARK: - 拖拽导入 (macOS)

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !blockWriteIfPersistenceUnavailable(.importMedia) else { return false }
        Task {
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // 不支持的类型不能静默丢弃：拖拽层已消失，用户会以为应用卡住。
                    // 与批量导入路径保持一致的提示文案
                    guard AudioImportValidator.allSupportedExtensions.contains(url.pathExtension.lowercased()),
                          AudioImportValidator.isValidMediaFile(url) else {
                        Task { @MainActor in
                            viewModel.errorMessage = String(
                                format: String(localized: "文件「%@」不是支持的音频/视频格式"),
                                url.lastPathComponent
                            )
                            viewModel.showError = true
                        }
                        return
                    }
                    Task { @MainActor in
                        await viewModel.importAudio(from: url, context: modelContext)
                    }
                }
            }
        }
        return true
    }
    #endif

    // MARK: - 文件导入处理

    /// 逐个导入音频/视频文件（工具栏媒体选择器入口）：
    /// 校验类型 → security-scoped 访问 → 更新进度提示
    private func importMediaFiles(_ urls: [URL]) {
        guard !blockWriteIfPersistenceUnavailable(.importMedia) else { return }
        Task {
            let total = urls.count
            for (index, url) in urls.enumerated() {
                // 校验文件是否为真实音频/视频类型
                guard AudioImportValidator.isValidMediaFile(url) else {
                    viewModel.errorMessage = String(format: String(localized: "文件「%@」不是支持的音频/视频格式"), url.lastPathComponent)
                    viewModel.showError = true
                    continue
                }
                // 处理 security-scoped URL
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                viewModel.importProgressText = String(
                    format: String(localized: "导入中 (%lld/%lld)..."),
                    index + 1, total
                )
                await viewModel.importAudio(from: url, context: modelContext)
            }
            viewModel.importProgressText = nil
        }
    }

    // MARK: - 转写控制（从 RecordingDetailView 迁移）

    /// 为指定录音发起转写：投递到全局处理队列，由 TaskCenter 负责调度
    /// （本地模型准备也收敛进转写步骤，见 `transcriptionStep`）
    private func startTranscriptionFor(_ recording: AudioRecording) {
        enqueueTranscription(recording)
    }

    // MARK: - 剪贴板

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

    // MARK: - PDF 导出（右键入口）

    /// PDF 导出目标：转写与总结分别对应各自的文档与面板开关
    private enum PDFExportTarget {
        case transcript
        case summary
    }

    /// 右键「导出为 .pdf」：先把 Markdown 排版成 PDF，再弹保存面板。
    ///
    /// 排版放在点菜单这一刻、且离开主线程，有两个原因：
    /// - 长转写（数万字）排版要百毫秒量级，不能在 UI 线程上顶住保存面板；
    /// - 排版失败能在用户选路径前就弹错，而不是选完自方才发现写了个空文件。
    private func exportPDF(markdown: String, title: String, to target: PDFExportTarget) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            viewModel.errorMessage = String(localized: "没有可导出的内容。")
            viewModel.showError = true
            return
        }
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    var configuration = MarkdownPDFRenderer.Configuration()
                    configuration.title = title
                    return try MarkdownPDFRenderer.render(markdown: markdown, configuration: configuration)
                }.value
                switch target {
                case .transcript:
                    exportTranscriptPDFDoc = MarkdownPDFDocument(data: data)
                    showTranscriptPDFExporter = true
                case .summary:
                    exportSummaryPDFDoc = MarkdownPDFDocument(data: data)
                    showSummaryPDFExporter = true
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
    }

    #if os(macOS)
    /// 在主窗口内容视图中心锚定弹出系统分享面板（导出原始录音）。
    /// NSSharingServicePicker 需要 NSView 锚点：sheet 内的包装视图尺寸为零，
    /// 会导致空白弹窗，因此不走 sheet，直接锚定当前窗口。
    private func presentSharingPicker(for url: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        let anchor = CGRect(x: bounds.midX - 1, y: bounds.midY - 1, width: 2, height: 2)
        NSSharingServicePicker(items: [url])
            .show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }
    #endif
    
    /// 临时模式常驻横幅：只要本次运行不落盘就一直显示，避免用户误以为改动已保存。
    /// 与进度/告警胶囊同一处底部 overlay，不新增顶层视图链（该链已接近类型检查上限）
    @ViewBuilder
    private var transientModeBanner: some View {
        if isTransientMode {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("临时模式：未连接数据库，新建/导入/删除已禁用，本次所有改动都不会保存，退出即丢失。")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .clipShape(Capsule())
            .padding(.bottom, 8)
        }
    }

    /// 磁盘同步结果反馈：非模态横幅告知“恢复了几条、新载入了什么”；
    /// 恢复失败走模态 alert（需要用户明确知晓且不频繁）。
    /// 手动刷新始终展示（回答“刷新到底做了什么”）；启动同步仅在有待展示内容时展示
    private func handleSyncResult(_ result: FileSyncService.SyncResult, isManualRefresh: Bool) {
        var lines: [String] = []

        if !result.recovered.isEmpty {
            let details = result.recovered.map { info -> String in
                let minutes = Int((info.duration / 60).rounded())
                let durationText = minutes >= 1 ? String(format: String(localized: "，约 %d 分钟"), minutes) : ""
                return info.displayName + durationText
            }
            lines.append(String(
                format: String(localized: "已自动恢复 %d 条崩溃遗留的录音：%@。转写与总结需重新发起"),
                result.recovered.count,
                details.joined(separator: "、")
            ))
        }
        if result.stillRecordingCount > 0 {
            lines.append(String(localized: "\(result.stillRecordingCount) 条录音疑似仍在录制，本轮未处理"))
        }
        if result.newCount > result.recovered.count {
            lines.append(String(format: String(localized: "新载入 %d 个条目"), result.newCount - result.recovered.count))
        }
        if lines.isEmpty {
            guard isManualRefresh else { return }
            lines.append(String(localized: "同步完成，无新内容"))
        }

        withAnimation(.easeInOut) { syncBannerSymbol = "arrow.clockwise.circle.fill" }
        showTransientBanner(lines.joined(separator: "\n"))

        // 恢复失败：分片已保留，需要用户明确知晓（走模态 alert）
        if !result.recoveryFailedNames.isEmpty {
            viewModel.errorMessage = String(
                format: String(localized: "%d 条录音自动恢复失败：%@。\n分片文件已保留在录音文件夹，可用专业音频工具尝试修复。"),
                result.recoveryFailedNames.count,
                result.recoveryFailedNames.joined(separator: "、")
            )
            viewModel.showError = true
        }
        if result.saveFailed {
            viewModel.errorMessage = String(localized: "数据同步完成但保存到数据库失败，重启应用后可能需要重新加载。")
            viewModel.showError = true
        }
    }

    private func handleRecordingFeedback() {
        guard let feedback = viewModel.recordingFeedback else { return }
        syncBannerSymbol = feedback.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        let action: (() -> Void)? = feedback.folderName.map { folder in
            {
                guard let recording = recordings.first(where: { $0.folderName == folder }) else { return }
                viewModel.captureReportRequestedFolder = folder
                selectedListItems = [.recording(recording)]
                viewModel.selectedRecording = recording
            }
        }
        showTransientBanner(
            feedback.message, actionTitle: action == nil ? nil : String(localized: "查看详情"),
            action: action, isWarning: feedback.isWarning
        )
    }

    /// 顶部非模态横幅：展示文本并在 8 秒后自动收起。
    /// 由磁盘同步结果、截图一次性结果（已复制/已保存）与任务入队提示共用。
    /// - Parameters:
    ///   - actionTitle: 可选动作按钮文案；为 nil 时只展示文本
    ///   - action: 动作回调（如「查看队列」打开处理队列面板）
    private func showTransientBanner(
        _ text: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        isWarning: Bool = false
    ) {
        withAnimation(.easeInOut) {
            syncBannerIsWarning = isWarning
            syncBannerText = text
            syncBannerActionTitle = actionTitle
            syncBannerAction = action
        }
        syncBannerDismissTask?.cancel()
        syncBannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut) {
                syncBannerText = nil
                syncBannerActionTitle = nil
                syncBannerAction = nil
            }
        }
    }

    /// 收起横幅（统一清理文本与动作，避免动作按钮残留到下一次横幅）
    private func dismissTransientBanner() {
        withAnimation(.easeInOut) {
            syncBannerText = nil
            syncBannerActionTitle = nil
            syncBannerAction = nil
        }
    }

    /// 顶部横幅：结果提示在 8 秒后收起，过程提示在操作结束时收起。
    /// 结果类（同步/保存/截图）与过程类（导入、合并、清理）反馈共用这一条，
    /// 过程类在左侧显示转圈图标，不再单独占用底部胶囊。
    @ViewBuilder
    private var syncResultBanner: some View {
        // 过程类反馈优先：导入/合并/清理进行中时，横幅显示当前步骤而不是上一条结果
        if let text = progressBannerText {
            bannerContent(text: text, isProgress: true)
        } else if let text = syncBannerText {
            bannerContent(text: text, isProgress: false)
        }
    }

    /// 横幅内容：结果类与过程类共用同一套样式（胶囊背景 + 图标 + 文案 + 关闭键）
    @ViewBuilder
    private func bannerContent(text: String, isProgress: Bool) -> some View {
        // 单行提示（如「录音已保存。」+「查看详情」）按中线对齐：图标、文字、按钮、关闭键
        // 的视觉中心落在同一条水平线上；多行提示（采集详情逐条列出）仍按顶对齐，
        // 否则图标与关闭键会飘到整段文字的中部
        HStack(alignment: text.contains("\n") ? .top : .center, spacing: 10) {
            if isProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("处理中"))
            } else {
                Image(systemName: syncBannerSymbol)
                    .foregroundStyle(syncBannerIsWarning ? Color.yellow : Color.secondary)
            }
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            // 就近入口（如任务入队后的「查看队列」）：不必让用户自己去工具栏找队列按钮
            if isProgress, viewModel.isMergingAudio, viewModel.canCancelEchoReduction {
                Button("取消回声消除") { viewModel.cancelEchoReduction() }
                    .buttonStyle(.link)
            } else if !isProgress,
                      let actionTitle = syncBannerActionTitle, let action = syncBannerAction {
                Button(actionTitle) {
                    action()
                    dismissTransientBanner()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // 小号按钮自带内边距，与文字基线对齐时会显得偏下，这里按中线对齐
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            }
            if !isProgress {
                Button {
                    dismissTransientBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 过程类反馈（导入/合并/清理）的文案：与结果类共用顶部横幅，左侧显示转圈图标。
    /// 优先级按「用户刚触发的动作」排：导入 → 清理 → 合并。
    private var progressBannerText: String? {
        if let progressText = viewModel.importProgressText { return progressText }
        if MediaCleanupService.shared.isRunning {
            let count = String(format: String(localized: "%1$lld/%2$lld"),
                               Int64(MediaCleanupService.shared.completedTargetCount),
                               Int64(MediaCleanupService.shared.targetCount))
            return String(localized: "正在清理媒体…") + " " + count
        }
        if RecordingMergeActivity.shared.isRunning {
            return String(localized: "正在合并录音…")
        }
        if viewModel.isMergingAudio {
            var text = mergePhaseText
            if viewModel.mergePhase == .echoReduction, viewModel.mergeProgressTotal > 0 {
                text += " " + String(format: String(localized: "%1$lld/%2$lld"),
                                     Int64(viewModel.mergeProgressCompleted),
                                     Int64(viewModel.mergeProgressTotal))
            }
            return text
        }
        return nil
    }

    /// 收尾阶段对应的用户文案
    private var mergePhaseText: String {
        switch viewModel.mergePhase {
        case .idle, .inspectingSegments: return String(localized: "正在检查录音分片…")
        case .echoReduction:             return String(localized: "正在消除回声…")
        case .mixing:                    return String(localized: "正在混音导出…")
        case .saving:                    return String(localized: "正在保存录音…")
        }
    }

    /// 录音中实时告警（磁盘不足/系统音频中断/唤醒恢复等）：顶部横幅常驻展示，
    /// 与磁盘同步结果同级（同一顶部横幅层），可手动关闭；
    /// 当前故障常驻，恢复后收起；历史记录在录音条目中保留。
    @ViewBuilder
    private var recordingWarningOverlay: some View {
        if viewModel.isMeetingRecording, let warning = viewModel.liveRecordingWarning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(warning)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Button("检查设备") { showSettings = true }
                    .buttonStyle(.link)
                Button {
                    viewModel.liveRecordingWarning = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .clipShape(Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var recordingStatusBadge: some View {
        HStack(spacing: 18) {
            // 布局占位用的空文本：标记为装饰，避免 VoiceOver 读到空元素
            Text(" ")
                .font(.caption.monospacedDigit())
                .accessibilityHidden(true)
            // 闪烁红点表示录音中
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(0.8)

            // 计时文本关到独立子视图：@Observable 按 body 实际读取的属性做依赖追踪，
            // 旧写法在 RootView.body 内读 recordingElapsed → 录音期间整棵根视图
            // （列表 + 详情 + 7 个 .animation(value:)）每秒重算一次
            RecordingElapsedLabel(viewModel: viewModel)
            Divider().frame(height: 12)
            // 麦克风入口：一个菜单同时管「静音 / 解除静音」与「选择输入设备」。
            // 设备列表走 MicrophoneDeviceRegistry 的同一份偏好，与设置页「录音 → 输入设备」、
            // 菜单栏「麦克风」、截图会话工具栏三方同步；图标本身仍随静音状态切换，
            // 不展开菜单也能一眼看出是否静音
            Menu {
                Button {
                    viewModel.toggleRecordingMute()
                } label: {
                    // 文案/图标取自 MicMuteCommand：与菜单栏「麦克风」子菜单是同一条命令，
                    // 口径集中在一处。传入的是 `String(localized:)` 的结果而非 LocalizedStringKey，
                    // 因此这里用 String 重载是安全的；不要改成裸字面量（那会被当 verbatim 文本，永不翻译）
                    Label(
                        MicMuteCommand.title(isMuted: viewModel.isRecordingMuted),
                        systemImage: MicMuteCommand.iconName(isMuted: viewModel.isRecordingMuted)
                    )
                }
                .disabled(
                    !MicMuteCommand.canToggle(
                        isMuted: viewModel.isRecordingMuted,
                        source: viewModel.recordingMuteSource
                    )
                )

                Divider()

                // .inline 让设备在菜单里直接铺开成带勾选的单选项，而不是再套一层子菜单
                Picker("输入设备", selection: $microphoneDeviceUID) {
                    Text("跟随系统默认").tag("")
                    ForEach(availableMicrophones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // 已选设备已拔出：显式占位，避免勾选态凭空消失（实际采集会回退系统默认）
                    if !microphoneDeviceUID.isEmpty,
                       !availableMicrophones.contains(where: { $0.uid == microphoneDeviceUID }) {
                        Text("已断开，将回退系统默认").tag(microphoneDeviceUID)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: viewModel.isRecordingMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(viewModel.isRecordingMuted ? .orange : .secondary)
            }
            .menuStyle(.borderlessButton)
            // 徽章要保持紧凑：不显示下拉箭头，只留图标本身
            .menuIndicator(.hidden)
            .fixedSize()
            .help(MicMuteCommand.helpText(isMuted: viewModel.isRecordingMuted, source: viewModel.recordingMuteSource))
            // .help 只提供鼠标 tooltip；菜单 label 是纯图标，VoiceOver 会读成 SF Symbol 名
            .accessibilityLabel(Text(MicMuteCommand.title(isMuted: viewModel.isRecordingMuted)))
            Divider().frame(height: 12)
            if viewModel.isRecordingMuted {
                // 静音来源文案（系统 / 会议软件 / 本地）与菜单栏状态项共用 MicMuteCommand，
                // 两处不会出现「已静音」与「已手动静音」这类不同说法
                Text(MicMuteCommand.sourceLabel(viewModel.recordingMuteSource))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Divider().frame(height: 12)
            }



            // 会议录音仅 macOS 支持，停止按钮同样限 macOS（iOS 上此徽章不可达）
            #if os(macOS)
            Button(role: .destructive) {
                toggleMeetingRecording()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("停止录音")
            // .help 只提供鼠标 tooltip；VoiceOver 读到的是 SF Symbol 名，需显式 label
            .accessibilityLabel("停止录音")
            #endif
            
            // 布局占位用的空文本：标记为装饰，避免 VoiceOver 读到空元素
            Text(" ")
                .font(.caption.monospacedDigit())
                .accessibilityHidden(true)
        }
        // 徽章现置于工具栏：macOS 工具栏会为条目自带一层容器底色，
        // 不再叠加原底部悬浮条的胶囊背景/内边距/过渡，避免“两层套娃”观感
    }

    // 静音命令的文案 / 图标 / 可用性 / 来源标签统一由 MicMuteCommand 提供：
    // 徽章菜单与菜单栏「麦克风」子菜单是同一条命令，口径不再各留一份

    /// 徽章麦克风菜单的可选输入设备（含 Loopback 等虚拟/回环设备，与系统「声音 → 输入」口径一致）
    private var availableMicrophones: [MicrophoneDevice] {
        MicrophoneDeviceRegistry.availableDevices()
    }

    /// 格式化录音时长
    private func formatRecordingDuration(_ seconds: TimeInterval) -> String {
        RecordingElapsedLabel.formatted(seconds)
    }

    
    #if os(macOS)
    /// 拖拽覆盖层视图
    private var dragOverlayView: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(.tint, lineWidth: 2)
            .background(.tint.opacity(0.08))
            .padding(8)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("释放以导入音频/视频")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
            }
    }
    #endif
}

// MARK: - 处理队列接入

/// 把「转写 / 总结 / 润色标题 / 画面分析 / 拆解待办 / 一键处理」统一投递到 `TaskCenter`。
///
/// 设计要点：
/// - 只做调度，不重写业务逻辑：每个步骤的执行体调用既有 ViewModel 方法并 `await` 其 Task
/// - 「一键处理」= 一个父 Job 内含多个顺序子步骤（Job 名取当前条目标题），不摊平成独立 Job
/// - 状态字段（summaryStatus / visualStatus / todoStatus）由本层在执行前后写入，供队列面板重启后恢复
private extension RootView {

    /// 取当前活动大模型配置；未配置时提示到设置
    func resolvedLLMConfig() -> LLMConfig? {
        guard let config = settingsVM.getActiveLLMConfig(from: llmConfigs) else {
            viewModel.errorMessage = String(localized: "请先在设置中选择大模型配置。")
            viewModel.showError = true
            return nil
        }
        return config
    }

    /// 把「详情页当前展示的条目」同步到 ViewModel 的 selectedRecording / selectedQuickNote。
    ///
    /// ViewModel 以此判定「哪一条是当前展示条目」：只有它才把流式内容与进行中态写入共享
    /// UI 状态，后台正在跑的另一条目不得把内容串到当前页面。列表是唯一的选择入口
    /// （多选或未选中时都视作没有当前条目），所以在这里统一回填。
    func syncDetailSelection() {
        guard selectedListItems.count == 1,
              let item = selectedListItems.first,
              isSelectionVisible(item) else {
            viewModel.selectedRecording = nil
            quickNoteVM.selectedQuickNote = nil
            return
        }
        switch item {
        case .recording(let recording):
            if viewModel.selectedRecording?.id != recording.id { viewModel.selectedRecording = recording }
            quickNoteVM.selectedQuickNote = nil
        case .quickNote(let note):
            if quickNoteVM.selectedQuickNote?.id != note.id { quickNoteVM.selectedQuickNote = note }
            viewModel.selectedRecording = nil
        }
    }

    // MARK: 单任务入口

    /// 转写（含本地模型准备）
    func enqueueTranscription(_ recording: AudioRecording) {
        TaskCenter.shared.enqueue(makeTranscriptionJob(recording))
    }

    /// 总结（导出/详情页「总结」按钮）
    func enqueueSummary(_ recording: AudioRecording, asMeeting: Bool?) {
        guard let config = resolvedLLMConfig() else { return }
        TaskCenter.shared.enqueue(
            makeJob(title: recording.fileName, folder: recording.folderName, durable: true,
                    steps: [summaryStep(recording, config: config, asMeeting: asMeeting)])
        )
    }

    /// 快捷笔记总结
    func enqueueNoteSummary(_ note: QuickNote) {
        guard let config = resolvedLLMConfig() else { return }
        TaskCenter.shared.enqueue(
            makeJob(title: note.title, folder: note.folderName, durable: false,
                    steps: [summaryStep(note, config: config)])
        )
    }

    /// 润色标题
    func enqueueTitle(_ item: ListItem) {
        guard let config = resolvedLLMConfig() else { return }
        switch item {
        case .recording(let recording):
            TaskCenter.shared.enqueue(
                makeJob(title: recording.fileName, folder: recording.folderName, durable: false,
                        steps: [titleStep(recording, config: config)])
            )
        case .quickNote(let note):
            TaskCenter.shared.enqueue(
                makeJob(title: note.title, folder: note.folderName, durable: false,
                        steps: [titleStep(note, config: config)])
            )
        }
    }

    /// 拆解待办
    func enqueueTodo(_ item: ListItem) {
        guard let config = resolvedLLMConfig() else { return }
        switch item {
        case .recording(let recording):
            TaskCenter.shared.enqueue(
                makeJob(title: recording.fileName, folder: recording.folderName, durable: false,
                        steps: [todoStep(recording, config: config)])
            )
        case .quickNote(let note):
            TaskCenter.shared.enqueue(
                makeJob(title: note.title, folder: note.folderName, durable: false,
                        steps: [todoStep(note, config: config)])
            )
        }
    }

    /// 画面要点分析（录屏 / 导入视频）
    func enqueueVisual(_ recording: AudioRecording) {
        guard let config = resolvedLLMConfig() else { return }
        TaskCenter.shared.enqueue(
            makeJob(title: recording.fileName, folder: recording.folderName, durable: false,
                    steps: [visualStep(recording, config: config)])
        )
    }

    // MARK: 一键处理

    /// 打开「一键处理」预览：先把将执行/将跳过的步骤与云端数据范围摆出来，确认后再入队。
    /// 未配置大模型时直接提示（沿用 `resolvedLLMConfig` 的既有提示）。
    func presentOneClickPreview(_ item: ListItem) {
        guard let config = resolvedLLMConfig() else { return }
        oneClickPreview = OneClickPreviewPayload(
            item: item,
            inputs: oneClickPlanInputs(for: item, config: config)
        )
    }

    /// 汇总条目当前状态，用于推导一键处理计划（纯数据，规则见 `OneClickPlan.make`）。
    ///
    /// 「已完成」一律按**产物**判定，而不是队列写入的状态字段：
    /// `summaryStatus` / `todoStatus` 只由队列步骤回写，用户在详情页直接生成总结/拆解待办
    /// 并不会改这些字段——只看状态字段会把「其实早就做完了」误判成「待执行」，
    /// 于是预览里把用户不想重跑的步骤列成将执行（云端调用还按次计费）。
    func oneClickPlanInputs(for item: ListItem, config: LLMConfig) -> OneClickPlan.Inputs {
        switch item {
        case .recording(let recording):
            let folderURL = recording.folderURL
            return OneClickPlan.Inputs(
                isRecording: true,
                hasVideo: recording.hasVideoSource,
                transcriptCompleted: recording.transcriptionStatus == .completed,
                transcriptManuallyEdited: recording.transcriptModifiedAt != nil,
                visualCompleted: recording.hasVisualArtifacts,
                summaryCompleted: !(recording.summary ?? "").isEmpty,
                todoCompleted: TodoDocument.exists(in: folderURL),
                audioFileExists: FileManager.default.fileExists(atPath: recording.fileURL.path),
                isImageNote: false,
                usesCloudLLM: !config.isLocal,
                forceRetranscribe: false
            )
        case .quickNote(let note):
            return OneClickPlan.Inputs(
                isRecording: false,
                hasVideo: false,
                transcriptCompleted: false,
                transcriptManuallyEdited: false,
                visualCompleted: false,
                summaryCompleted: !(note.summaryText ?? "").isEmpty,
                todoCompleted: TodoDocument.exists(in: note.folderURL),
                audioFileExists: false,
                isImageNote: note.isImageNote,
                usesCloudLLM: !config.isLocal,
                forceRetranscribe: false
            )
        }
    }

    /// 按用户确认后的计划入队。
    ///
    /// 依赖与隐私边界保持既有行为：
    /// - 「转写」步骤内部先确保本地模型就绪（`transcriptionStep`），再转写
    /// - 「总结」步骤内部完成后自动润色标题（在 ViewModel 内，未在此处拆开）
    /// - 云端文本请求仍走 PII 脱敏与还原；图片/视频帧不做文本脱敏，故预览里明确数据范围
    /// - 待办只落盘 TodoDocument，不写入系统提醒事项
    func enqueueOneClick(_ item: ListItem, plan: OneClickPlan) {
        guard let config = resolvedLLMConfig() else { return }
        let kinds = Set(plan.runItems.map(\.kind))
        var steps: [TaskCenter.Step] = []
        let title: String
        let folder: String
        let durable: Bool

        switch item {
        case .recording(let recording):
            title = recording.fileName
            folder = recording.folderName
            durable = true
            if kinds.contains(.transcription) {
                // 有人工编辑的转写：入队前先落一份快照。快照失败即中止，不拿用户的手动修改去赌
                guard snapshotTranscriptBeforeRetranscribe(recording) else { return }
                steps.append(transcriptionStep(recording))
            }
            if kinds.contains(.visualAnalysis) {
                steps.append(visualStep(recording, config: config))
            }
            if kinds.contains(.summary) {
                // 录音 / 录屏默认会议总结
                steps.append(summaryStep(recording, config: config, asMeeting: true))
            }
            if kinds.contains(.todoExtraction) {
                steps.append(todoStep(recording, config: config))
            }
        case .quickNote(let note):
            title = note.title
            folder = note.folderName
            durable = false
            if kinds.contains(.summary) {
                steps.append(summaryStep(note, config: config))
            }
            if kinds.contains(.todoExtraction) {
                steps.append(todoStep(note, config: config))
            }
        }

        guard !steps.isEmpty else { return }
        TaskCenter.shared.enqueue(makeJob(title: title, folder: folder, durable: durable, steps: steps))
        showQueueEntryBanner()
    }

    /// 重新转写前把现有转写备份为 transcript.backup.md（原子写）。
    /// - Returns: 备份是否可用；false 表示备份失败，调用方必须中止本次处理
    func snapshotTranscriptBeforeRetranscribe(_ recording: AudioRecording) -> Bool {
        let source = recording.transcriptFileURL
        let backup = recording.folderURL.appendingPathComponent("transcript.backup.md")
        do {
            if FileManager.default.fileExists(atPath: source.path) {
                // 直接复制磁盘上的转写文件：保真（含用户手工改写的 Markdown）
                try Data(contentsOf: source).write(to: backup, options: .atomic)
            } else {
                let markdown = recording.transcriptMarkdown
                guard !markdown.isEmpty else { return true }
                try Data(markdown.utf8).write(to: backup, options: .atomic)
            }
            return true
        } catch {
            PersistenceReporting.reportSaveFailure(error)
            viewModel.errorMessage = String(localized: "备份现有转写失败，已取消处理以免覆盖手动修改。请检查磁盘空间后重试。")
            viewModel.showError = true
            return false
        }
    }

    /// 入队成功后展示任务入口：横幅 + 「查看队列」（队列面板支持查看进度与取消）
    func showQueueEntryBanner() {
        syncBannerSymbol = "square.stack.fill"
        showTransientBanner(
            String(localized: "已加入处理队列，可查看进度或取消。"),
            actionTitle: String(localized: "查看队列")
        ) {
            NotificationCenter.default.post(name: .openTaskQueuePanel, object: nil)
        }
    }

    // MARK: Job / Step 构造

    func makeJob(title: String, folder: String, durable: Bool, steps: [TaskCenter.Step]) -> TaskCenter.Job {
        TaskCenter.Job(folderName: folder, title: title, steps: steps, isDurable: durable)
    }

    func makeTranscriptionJob(_ recording: AudioRecording) -> TaskCenter.Job {
        makeJob(title: recording.fileName, folder: recording.folderName, durable: true,
                steps: [transcriptionStep(recording)])
    }

    /// 转写步骤：本地模式先确保模型就绪（缺失即下载），再转写
    func transcriptionStep(_ recording: AudioRecording) -> TaskCenter.Step {
        let sttConfig = settingsVM.makeSTTConfig(experience: experienceStore.current)
        let context = modelContext
        let whisper = WhisperLocalService.shared
        let audioURL = recording.fileURL
        return TaskCenter.Step(
            kind: .transcription,
            run: { failure in
                if sttConfig.mode == .local, !whisper.isModelLoadedFor(path: sttConfig.modelPath) {
                    do {
                        try await whisper.loadModel(fromPath: sttConfig.modelPath)
                    } catch {
                        // 本地模型加载失败是最常见的可修复原因：给出稳定码让面板引导到设置
                        failure.code = .missingLocalModel
                        return .failed
                    }
                }
                recording.transcriptionStatus = .processing
                let task = viewModel.startTranscription(recording: recording, sttConfig: sttConfig, context: context)
                await task.value
                if recording.transcriptionStatus == .failed {
                    failure.code = Self.transcriptionFailureCode(audioURL: audioURL, mode: sttConfig.mode)
                    return .failed
                }
                if Task.isCancelled { return .cancelled }
                return .succeeded
            },
            cancel: { viewModel.cancelTranscription() }
        )
    }

    /// 转写失败的稳定码：音频缺失 → 输入缺失；系统语音识别 → 权限；否则走通用兜底
    static func transcriptionFailureCode(audioURL: URL, mode: STTMode) -> TaskErrorCode {
        if !FileManager.default.fileExists(atPath: audioURL.path) { return .inputFileMissing }
        if mode == .system { return .permissionDenied }
        return TaskFailureClassifier.classify(
            primaryInputExists: true,
            availableDiskBytes: TaskFailureClassifier.availableDiskBytes(at: AudioRecording.storageDirectory)
        )
    }

    /// 非转写步骤的兜底稳定码：输入仍在 →（磁盘不足 / 未知）
    static func fallbackFailureCode(inputFileURL: URL?) -> TaskErrorCode {
        TaskFailureClassifier.classify(
            primaryInputExists: inputFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true,
            availableDiskBytes: TaskFailureClassifier.availableDiskBytes(at: AudioRecording.storageDirectory)
        )
    }

    /// 依据步骤强类型结论回写条目处理状态：
    /// 成功→completed、失败→failed、取消→pending（交回未处理，供重新发起）。
    /// 不再用「总结非空 / 待办非空 / 时间戳非空」之类的旁证反推成功。
    private func applyOutcome(
        _ outcome: TaskCenter.StepOutcome,
        to setStatus: (ProcessingStatus) -> Void
    ) {
        switch outcome {
        case .succeeded: setStatus(.completed)
        case .cancelled: setStatus(.pending)
        case .failed:    setStatus(.failed)
        }
    }

    /// 总结步骤（录音/录屏）
    func summaryStep(_ recording: AudioRecording, config: LLMConfig, asMeeting: Bool?) -> TaskCenter.Step {
        let context = modelContext
        return TaskCenter.Step(
            kind: .summary,
            run: { failure in
                recording.summaryStatus = .processing
                let task = viewModel.generateSummary(
                    recording: recording,
                    llmConfig: config,
                    context: context,
                    asMeeting: asMeeting,
                    experience: AppExperiencePreference.resolved()
                )
                // 结论由执行体给出：成功仅当本次确实产出并持久化
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: nil) }
                applyOutcome(outcome) { recording.summaryStatus = $0 }
                return outcome
            },
            cancel: { viewModel.cancelSummary(recordingID: recording.id) }
        )
    }

    /// 总结步骤（快捷笔记）
    func summaryStep(_ note: QuickNote, config: LLMConfig) -> TaskCenter.Step {
        let context = modelContext
        let imageURL = note.hasImage ? note.sourceImageURL : nil
        return TaskCenter.Step(
            kind: .summary,
            run: { failure in
                note.summaryStatus = .processing
                let task = quickNoteVM.generateSummary(
                    for: note,
                    llmConfig: config,
                    context: context,
                    experience: AppExperiencePreference.resolved()
                )
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: imageURL) }
                applyOutcome(outcome) { note.summaryStatus = $0 }
                return outcome
            },
            cancel: { quickNoteVM.cancelSummary(noteID: note.id) }
        )
    }

    /// 画面要点步骤（录屏 / 导入视频）。不弹帧数确认，直接走多模态大模型分析
    func visualStep(_ recording: AudioRecording, config: LLMConfig) -> TaskCenter.Step {
        let context = modelContext
        let videoURL = recording.videoFileURL
        return TaskCenter.Step(
            kind: .visualAnalysis,
            run: { failure in
                recording.visualStatus = .processing
                let task = viewModel.generateVisualNotes(recording: recording, llmConfig: config, context: context)
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: videoURL) }
                applyOutcome(outcome) { recording.visualStatus = $0 }
                return outcome
            },
            cancel: { viewModel.cancelVisualNotes() }
        )
    }

    /// 拆解待办步骤（只落盘 TodoDocument，不写入提醒事项）
    func todoStep(_ recording: AudioRecording, config: LLMConfig) -> TaskCenter.Step {
        return TaskCenter.Step(
            kind: .todoExtraction,
            run: { failure in
                recording.todoStatus = .processing
                let task = viewModel.extractTodos(from: recording, llmConfig: config)
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: nil) }
                applyOutcome(outcome) { recording.todoStatus = $0 }
                return outcome
            },
            cancel: { viewModel.cancelTodoExtraction(recordingID: recording.id) }
        )
    }

    /// 拆解待办步骤（快捷笔记）
    func todoStep(_ note: QuickNote, config: LLMConfig) -> TaskCenter.Step {
        let context = modelContext
        return TaskCenter.Step(
            kind: .todoExtraction,
            run: { failure in
                note.todoStatus = .processing
                let task = quickNoteVM.extractTodos(from: note, llmConfig: config, context: context)
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: nil) }
                applyOutcome(outcome) { note.todoStatus = $0 }
                return outcome
            },
            cancel: { quickNoteVM.cancelTodoExtraction(noteID: note.id) }
        )
    }

    /// 润色标题步骤（录音）
    func titleStep(_ recording: AudioRecording, config: LLMConfig) -> TaskCenter.Step {
        let context = modelContext
        return TaskCenter.Step(
            kind: .title,
            run: { failure in
                let task = viewModel.polishRecordingTitle(recording, llmConfig: config, context: context)
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: nil) }
                return outcome
            },
            cancel: { viewModel.cancelTitle(recordingID: recording.id) }
        )
    }

    /// 润色标题步骤（快捷笔记）
    func titleStep(_ note: QuickNote, config: LLMConfig) -> TaskCenter.Step {
        let context = modelContext
        return TaskCenter.Step(
            kind: .title,
            run: { failure in
                let task = quickNoteVM.polishNoteTitle(note, llmConfig: config, context: context)
                let outcome = await task.value
                if outcome == .failed { failure.code = Self.fallbackFailureCode(inputFileURL: nil) }
                return outcome
            },
            cancel: { quickNoteVM.cancelTitle(noteID: note.id) }
        )
    }
}

/// RootView 的通知桥接 modifier：截图一次性结果（已复制 / 已保存）+ 应用菜单 ⌘N/⌘O。
///
/// 合并成单个 modifier 是刻意的：`observerLayers` 那条视图链已经很长，
/// 每多挂一个 `.onReceive` / `.modifier(...)` 都会让 Swift 类型检查超时
/// （"unable to type-check this expression in reasonable time"），
/// 所以这里把新增的通知统一收进一个链接。
private struct RootViewBridgeModifier: ViewModifier {
    /// 截图一次性结果文案（已复制 / 已保存到文件）
    let onScreenshotNotice: (String) -> Void
    let onNewQuickNote: () -> Void
    let onImportMedia: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .screenshotCaptureNotice)
            ) { notification in
                guard let message = notification.userInfo?["message"] as? String else { return }
                onScreenshotNotice(message)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appMenuNewQuickNote)) { _ in
                onNewQuickNote()
            }
            .onReceive(NotificationCenter.default.publisher(for: .appMenuImportMedia)) { _ in
                onImportMedia()
            }
    }
}
