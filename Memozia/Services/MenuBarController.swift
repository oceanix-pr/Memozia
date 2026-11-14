#if os(macOS)
import AppKit
import os.log
#endif
import SwiftUI
import Observation
#if os(macOS)

/// 菜单栏控制器
///
/// 在 macOS 菜单栏创建一个状态项，提供：
/// - 显示/隐藏主窗口（共享屏幕时可快速隐藏，避免被会议参与者看到）
/// - 开始/停止会议录音（后台运行，无需主窗口）
/// - 静音切换
/// - 录音状态与时长显示
/// - 退出应用
///
/// 设计目标：会议中共享屏幕时，用户可隐藏主窗口只留菜单栏图标控制录音，
/// 这样在「共享单个窗口」或「共享整个屏幕（菜单栏默认不共享）」时都不会暴露本软件。
@MainActor
final class MenuBarController: NSObject {

    /// 共享实例
    static let shared = MenuBarController()

    private static let logger = Logger(subsystem: "app.memozia", category: "MenuBar")

    /// 应用标识的单色自定义 Symbol；由系统负责菜单栏明暗与高亮颜色。
    private static let menuBarImage: NSImage? = {
        let source: NSImage?
        if let symbol = NSImage(symbolName: "MemoziaMenuBar", bundle: .main, variableValue: 0) {
            source = symbol
        } else {
            logger.error("菜单栏自定义符号资源缺失，回退为系统波形图标")
            source = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Memozia")
        }
        guard let source, let image = MenuBarIconRenderer.makeTemplate(from: source) else {
            logger.error("菜单栏图标模板生成失败")
            return nil
        }
        return image
    }()

    /// 菜单栏退出前等待统一停止流程（封存 + 合并 + 入库）的上限。
    /// 与退出时等待合并的量级一致，避免这里先放弃、造成「退出等待到期 → 强退 →
    /// 合并半成品」的旧事故；实际会在服务停止且合并结束时立即返回
    private static let quitStopTimeout: TimeInterval = 900

    /// 菜单栏状态项
    private var statusItem: NSStatusItem!

    /// 录音服务引用（@Observable，可观察状态变化）
    private let recorder = MeetingRecorderService.shared

    /// 状态轮询定时器（用于刷新录音时长与图标）
    private var refreshTimer: Timer?

    /// 菜单项引用（动态更新标题）
    private var toggleRecordingItem: NSMenuItem!
    private var statusInfoItem: NSMenuItem!
    private var toggleWindowItem: NSMenuItem!
    private var languageMenuItem: NSMenuItem!

    /// 标记是否已启动
    private var didStart = false

    // 录屏偏好 radio 项（质量/声源），用于选中态刷新
    private var screenSourceItems: [NSMenuItem] = []
    private var screenQualityItems: [NSMenuItem] = []
    /// 麦克风子菜单（「静音 / 解除静音」+「跟随系统默认」+ 各输入设备）：
    /// 设备随插拔变化，需整体重建
    private var microphoneMenuItem: NSMenuItem?
    private var microphoneItems: [NSMenuItem] = []
    /// 子菜单顶部的静音命令项：标题/图标/可用性随录音与静音状态刷新
    private var microphoneMuteItem: NSMenuItem?
    /// 「录音开始时静音麦克风」预设项与其分隔线（录音中隐藏：只对下一场录音有效的开关
    /// 摆在运行中的命令旁边会误导，本场改静音走上方的命令）
    private var microphoneStartMutedItem: NSMenuItem?
    private var microphoneStartMutedSeparator: NSMenuItem?
    /// 上次构建麦克风子菜单的指纹（设备集合 + 当前选择 + 「开始时静音」偏好），
    /// 未变则只刷新状态，变了就整体重建
    private var lastMicrophoneSignature: String?
    /// 录屏直达项（全屏/选区/窗口）：录音/录屏中禁用，互斥状态在菜单里显性化
    private var screenRecordingStartItems: [NSMenuItem] = []
    /// 普通模式隐藏的入口。菜单仍是同一份，切换模式时只刷新可见性。
    private var professionalOnlyItems: [NSMenuItem] = []

    /// 强持有已挂载的「关闭即隐藏」委托：`NSWindow.delegate` 是 **weak**，
    /// 只放在函数局部变量里会让委托对象在挂载后立即释放，`windowShouldClose`
    /// 拦截静默失效（点红点仍然销毁窗口），且被替换下来的原委托也随之失去引用。
    /// key = 委托自身标识；随目标窗口销毁在 `pruneHideOnCloseDelegates()` 中清理，不会无界增长。
    private var hideOnCloseDelegates: [ObjectIdentifier: HideOnCloseWindowDelegate] = [:]
    /// 取消过期的异步显示/隐藏请求，避免退出全屏后的回调再次藏起刚恢复的窗口。
    private var windowVisibilityRequest: UInt = 0

    // MARK: - 启动

    /// 启动菜单栏控制器（仅可调用一次）
    func start() {
        guard !didStart else { return }
        didStart = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = [.removalAllowed]
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.alignment = .center
        statusItem.button?.imageScaling = .scaleNone

        // 构建菜单
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 状态信息项（显示录音时长/静音状态，不可点击）
        statusInfoItem = NSMenuItem(title: String(localized: "Memozia 就绪"), action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

        menu.addItem(.separator())

        // 开始/停止录音
        // 名称取自统一命令描述（与设置 → 热键、帮助页、设置搜索同一份事实源），
        // 录音进行中时由 refreshState 动态改成「停止录音 / 停止录制」
        let recordingCommand = AppCommandCatalog.descriptor(for: .toggleRecording)
        toggleRecordingItem = NSMenuItem(
            title: recordingCommand.localizedTitleString,
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        toggleRecordingItem.image = NSImage(
            systemSymbolName: recordingCommand.icon ?? "record.circle",
            accessibilityDescription: nil
        )
        toggleRecordingItem.target = self
        menu.addItem(toggleRecordingItem)

        menu.addItem(.separator())

        // 统一「捕获屏幕」顶级项（原「截图」+「录屏」两项合并）：
        // 一个目标选择心智（区域/窗口/全屏）下分流静/动两种出口——
        // 截图组进统一会话（会话工具栏含「录制」出口），录屏组保留直达，
        // 尾部保留声源/质量快切（设置页同步提供同一偏好）
        let captureSubmenu = NSMenu()

        let regionCommand = AppCommandCatalog.descriptor(for: .captureRegion)
        let regionItem = NSMenuItem(
            title: regionCommand.localizedTitleString,
            action: #selector(startRegionScreenshot),
            keyEquivalent: "s"
        )
        regionItem.target = self
        regionItem.keyEquivalentModifierMask = [.command, .option]
        regionItem.image = NSImage(
            systemSymbolName: regionCommand.icon ?? "crop",
            accessibilityDescription: nil
        )
        captureSubmenu.addItem(regionItem)

        let windowCommand = AppCommandCatalog.descriptor(for: .captureWindow)
        let windowItem = NSMenuItem(
            title: windowCommand.localizedTitleString,
            action: #selector(startWindowScreenshot),
            keyEquivalent: ""
        )
        windowItem.target = self
        windowItem.image = NSImage(
            systemSymbolName: windowCommand.icon ?? "macwindow.on.rectangle",
            accessibilityDescription: nil
        )
        captureSubmenu.addItem(windowItem)
        professionalOnlyItems.append(windowItem)

        let fullScreenCommand = AppCommandCatalog.descriptor(for: .captureFullScreen)
        let fullscreenItem = NSMenuItem(
            title: fullScreenCommand.localizedTitleString,
            action: #selector(startFullscreenScreenshot),
            keyEquivalent: ""
        )
        fullscreenItem.target = self
        fullscreenItem.image = NSImage(
            systemSymbolName: fullScreenCommand.icon ?? "rectangle.dashed",
            accessibilityDescription: nil
        )
        captureSubmenu.addItem(fullscreenItem)
        professionalOnlyItems.append(fullscreenItem)

        let recordingSeparator = NSMenuItem.separator()
        captureSubmenu.addItem(recordingSeparator)
        professionalOnlyItems.append(recordingSeparator)

        // 录屏直达：全屏一步开录；选区/窗口进统一会话（选定目标后自动进入录制倒计时）
        let screenFullScreenItem = NSMenuItem(
            title: String(localized: "录全屏（鼠标所在屏）"),
            action: #selector(startScreenRecordingFullScreen),
            keyEquivalent: ""
        )
        screenFullScreenItem.target = self
        screenFullScreenItem.image = NSImage(systemSymbolName: "inset.filled.center", accessibilityDescription: nil)
        captureSubmenu.addItem(screenFullScreenItem)

        let screenRegionItem = NSMenuItem(
            title: String(localized: "录选区…"),
            action: #selector(startScreenRecordingRegion),
            keyEquivalent: ""
        )
        screenRegionItem.target = self
        screenRegionItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        captureSubmenu.addItem(screenRegionItem)

        let screenWindowItem = NSMenuItem(
            title: String(localized: "录窗口…"),
            action: #selector(startScreenRecordingWindow),
            keyEquivalent: ""
        )
        screenWindowItem.target = self
        screenWindowItem.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        captureSubmenu.addItem(screenWindowItem)
        screenRecordingStartItems = [screenFullScreenItem, screenRegionItem, screenWindowItem]
        professionalOnlyItems.append(contentsOf: screenRecordingStartItems)

        let sourceSeparator = NSMenuItem.separator()
        captureSubmenu.addItem(sourceSeparator)
        professionalOnlyItems.append(sourceSeparator)

        for source in RecordingSource.allCases {
            let item = NSMenuItem(
                title: String(format: String(localized: "声源：%@"), source.displayName),
                action: #selector(selectScreenSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = source.rawValue
            captureSubmenu.addItem(item)
            screenSourceItems.append(item)
            professionalOnlyItems.append(item)
        }

        let qualitySeparator = NSMenuItem.separator()
        captureSubmenu.addItem(qualitySeparator)
        professionalOnlyItems.append(qualitySeparator)

        for quality in ScreenRecordingQuality.allCases {
            let item = NSMenuItem(
                title: String(format: String(localized: "质量：%@（%@）"), quality.displayName, quality.estimatedSizeLabel),
                action: #selector(selectScreenQuality(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = quality.rawValue
            captureSubmenu.addItem(item)
            screenQualityItems.append(item)
            professionalOnlyItems.append(item)
        }

        let captureItem = NSMenuItem(
            title: String(localized: "捕获屏幕"),
            action: nil,
            keyEquivalent: ""
        )
        captureItem.submenu = captureSubmenu
        captureItem.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        menu.addItem(captureItem)
        refreshScreenRecordingMenuStates()

        // 麦克风选择提到顶层、紧随「捕获屏幕」：会议录音与录屏都用它，
        // 原先埋在「捕获屏幕」子菜单里容易被当成只对录屏生效（与设置页共用同一偏好）
        let microphoneItem = NSMenuItem(
            title: String(localized: "麦克风"),
            action: nil,
            keyEquivalent: ""
        )
        microphoneItem.submenu = NSMenu()
        microphoneItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(microphoneItem)
        microphoneMenuItem = microphoneItem
        professionalOnlyItems.append(microphoneItem)
        refreshMicrophoneMenu(signature: microphoneMenuSignature())

        menu.addItem(.separator())

        // 显示/隐藏主窗口
        toggleWindowItem = NSMenuItem(
            title: String(localized: "隐藏主窗口"),
            action: #selector(toggleMainWindow),
            keyEquivalent: "h"
        )
        toggleWindowItem.target = self
        menu.addItem(toggleWindowItem)

        // 从剪贴板新建笔记（名称取自命令描述：该命令实际创建的是「快捷笔记」，
        // 旧文案写成「新建待办」与实际产物不符，已统一为「从剪贴板新建笔记」）
        let clipboardCommand = AppCommandCatalog.descriptor(for: .newQuickNoteFromClipboard)
        let quickNoteItem = NSMenuItem(
            title: clipboardCommand.localizedTitleString,
            action: #selector(createQuickNoteFromClipboard),
            keyEquivalent: "n"
        )
        quickNoteItem.target = self
        quickNoteItem.image = NSImage(
            systemSymbolName: clipboardCommand.icon ?? "doc.on.clipboard",
            accessibilityDescription: nil
        )
        menu.addItem(quickNoteItem)
        professionalOnlyItems.append(quickNoteItem)

        // 切换语言子菜单：列出全部可用语言，默认跟随系统
        let languageSubmenu = NSMenu()
        // 「跟随系统」项：representedObject 为空字符串，与显式语言项共用同一 action
        let systemLanguageItem = NSMenuItem(
            title: String(localized: "跟随系统"),
            action: #selector(selectLanguage(_:)),
            keyEquivalent: ""
        )
        systemLanguageItem.target = self
        systemLanguageItem.representedObject = ""
        languageSubmenu.addItem(systemLanguageItem)
        languageSubmenu.addItem(.separator())
        // 语言名称用该语言的自称（endonym），经变量传入 NSMenuItem，
        // 不作为本地化 key 提取（各语言菜单里都显示自己的名字）
        for lang in Self.availableLanguages {
            let item = NSMenuItem(
                title: lang.nativeName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            languageSubmenu.addItem(item)
        }
        languageMenuItem = NSMenuItem(
            title: String(localized: "切换语言"),
            action: nil,
            keyEquivalent: ""
        )
        languageMenuItem.submenu = languageSubmenu
        languageMenuItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(languageMenuItem)

        // 打开设置（名称取自命令描述，与应用菜单、帮助页一致）
        let settingsItem = NSMenuItem(
            title: AppCommandCatalog.descriptor(for: .openSettings).localizedTitleString,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 退出
        let quitItem = NSMenuItem(
            title: String(localized: "退出 Memozia"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // 启动状态刷新定时器（每秒刷新一次，驱动图标和菜单标题更新）
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refreshState()

        // 为主窗口挂“关闭即隐藏”委托（隐藏红点销毁窗口的路径，
        // 避免窗口丢失后点 Dock 无法恢复；幂等，重复调用安全）
        attachHideOnCloseDelegates()
    }

    // MARK: - 状态刷新

    /// 刷新菜单栏图标、标题与菜单项状态
    /// 上次刷新对应的界面签名（用于跳过"状态没变"的整轮 AppKit 赋值）
    private var lastRefreshSignature: String?

    /// 设置页切换模式后立即刷新，无需等待下一次定时器 tick。
    func refreshForExperienceChange() {
        lastRefreshSignature = nil
        refreshState()
    }

    private func refreshState() {
        let isRecording = recorder.isRecording
        let isScreenRecording = recorder.isScreenRecording
        let isMuted = recorder.isMicMuted
        let muteSource = recorder.muteSource
        let isMainWindowVisible = isMainWindowShown()
        let selectedLanguage = UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey) ?? ""
        // 录屏偏好可能被设置页修改，纳入签名保证菜单 radio 勾选态跟随
        let screenSourceRaw = ScreenRecordingQuality.savedSource().rawValue
        let screenQualityRaw = ScreenRecordingQuality.saved().rawValue
        // 麦克风设备集合与当前选择同样纳入签名：热插拔、设置页改选都要即时反映到子菜单
        let microphoneSignature = microphoneMenuSignature()
        let experience = AppExperiencePreference.resolved()

        // 本方法的全部输出只取决于上面这些项，且**不含录音时长**（菜单栏不显示秒数）。
        // 旧写法每秒无条件重建 3 个 NSImage、重写全部菜单项标题、遍历语言子菜单，
        // 空闲时一整天都在做无变化的赋值。签名相同即整轮跳过；
        // 任何一项变化（录音/录屏起停、静音切换、主窗口显隐、语言切换、录屏偏好切换）都会在下一次 tick 立即刷新。
        let signature = "\(isRecording)|\(isScreenRecording)|\(isMuted)|\(muteSource)|\(isMainWindowVisible)|\(selectedLanguage)|\(screenSourceRaw)|\(screenQualityRaw)|\(microphoneSignature)|\(experience.rawValue)"
        guard signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature

        // 1) 固定使用 A 版柔角折页 Symbol（可见轮廓约 18pt、单色模板）。
        // 系统负责菜单栏明暗、菜单展开高亮与对比度；录音/静音状态仍由菜单文本表达。
        statusItem.button?.image = Self.menuBarImage
        // 颜色交给系统：不设 contentTintColor，保持模板图的标准主题效果
        statusItem.button?.contentTintColor = nil
        // 不在菜单栏按钮上显示文字
        statusItem.button?.title = ""

        // 2) 菜单项：录屏时停止项表达为「停止录制」，与录音（纯音频）区分
        let stopTitle = isScreenRecording ? String(localized: "停止录制") : String(localized: "停止录音")
        toggleRecordingItem.title = isRecording ? stopTitle : String(localized: "开始会议录音")
        toggleRecordingItem.image = NSImage(
            systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle",
            accessibilityDescription: nil
        )

        let showsProfessionalControls = experience == .pro
        for item in professionalOnlyItems {
            item.isHidden = !showsProfessionalControls
        }

        // 3) 状态信息（不显示时长，只显示简单状态）；录屏时状态前缀为「录屏中」。
        //    静音来源文案与录音徽章共用 MicMuteCommand，避免同一状态两处说法不同
        if isRecording {
            if isMuted {
                let src = MicMuteCommand.sourceLabel(muteSource)
                let mutedFormat = isScreenRecording
                    ? String(localized: "录屏中 · %@")
                    : String(localized: "录音中 · %@")
                statusInfoItem.title = String(format: mutedFormat, src)
            } else {
                statusInfoItem.title = isScreenRecording
                    ? String(localized: "录屏中")
                    : String(localized: "录音中")
            }
        } else {
            statusInfoItem.title = String(localized: "Memozia 就绪")
        }

        // 4) 主窗口切换项（可见性已在签名处取过）
        toggleWindowItem.title = isMainWindowVisible ? String(localized: "隐藏主窗口") : String(localized: "显示主窗口")
        toggleWindowItem.image = NSImage(
            systemSymbolName: isMainWindowVisible ? "eye.slash" : "eye",
            accessibilityDescription: nil
        )

        // 5) 语言子菜单勾选状态（语言值已在签名处读过，不再每次 tick 读 UserDefaults）
        if let submenu = languageMenuItem?.submenu {
            for item in submenu.items {
                let code = item.representedObject as? String ?? ""
                item.state = code == selectedLanguage ? .on : .off
            }
        }

        // 6) 录屏直达项：录音/录屏进行中禁用并提示（互斥不再点了没反应），
        //    偏好 radio 同步刷新（覆盖设置页修改 UserDefaults 的路径）
        for item in screenRecordingStartItems {
            item.isEnabled = !isRecording
            item.toolTip = isRecording ? String(localized: "录音/录屏进行中，请先停止后再开始录屏") : nil
        }
        refreshScreenRecordingMenuStates()

        // 7) 麦克风子菜单：设备集合/当前选择变化时重建，否则只刷新勾选态
        refreshMicrophoneMenu(signature: microphoneSignature)
    }

    // MARK: - 菜单动作

    /// 开始/停止会议录音
    ///
    /// 注意：action 方法标记为 nonisolated，避免在 AppKit 同步回调（无 Task 上下文）上
    /// 走 MainActor.assumeIsolated 的 executor 断言（swift_task_isCurrentExecutorWithFlagsImpl
    /// 在 macOS 26 上可能访问损坏的 executor 指针导致 EXC_BAD_ACCESS，应用从后台被唤醒时尤甚）。
    /// AppKit 的 sendAction:to:from: 保证在主线程同步调用，因此用 MainActor.assumeOnMainThread
    /// （只做主线程检查，不做 executor 断言）进入 MainActor 上下文。
    @objc nonisolated private func toggleRecording() {
        MainActor.assumeOnMainThread {
            if recorder.isRecording {
                // 停止录音：通过通知让 RecordingViewModel 处理录音文件入库
                NotificationCenter.default.post(name: .menuBarStopRecording, object: nil)
            } else {
                // 开始录音：通过通知让 RecordingViewModel 用当前设置启动录音
                NotificationCenter.default.post(name: .menuBarStartRecording, object: nil)
            }
        }
    }

    /// 显示/隐藏主窗口
    @objc nonisolated private func toggleMainWindow() {
        MainActor.assumeOnMainThread {
            if isMainWindowShown() {
                hideMainWindow()
            } else {
                showMainWindow()
            }
            refreshState()
        }
    }

    /// 打开设置（通过通知让主窗口响应）
    @objc nonisolated private func openSettings() {
        MainActor.assumeOnMainThread {
            showMainWindow()
            NotificationCenter.default.post(name: .menuBarOpenSettings, object: nil)
        }
    }

    /// 从剪贴板新建快捷笔记（通过通知让主 App 响应）
    @objc nonisolated private func createQuickNoteFromClipboard() {
        MainActor.assumeOnMainThread {
            showMainWindow()
            NotificationCenter.default.post(name: .menuBarCreateQuickNoteFromClipboard, object: nil)
        }
    }

    // MARK: - 界面语言切换

    /// 界面语言偏好存储键：用户显式选择的语言代码（缺失/空 = 跟随系统）。
    /// 供 MemoziaApp 的 @AppStorage 共用，保证两处菜单勾选状态一致
    static let appLanguageDefaultsKey = "AppInterfaceLanguage"

    /// 可选界面语言（代码与 catalog 的 .lproj 名一致，显示为该语言的自称）
    static let availableLanguages: [(code: String, nativeName: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"),
        ("uk", "Українська"), ("nl", "Nederlands"), ("pl", "Polski"), ("tr", "Türkçe"),
        ("ar", "العربية"), ("hi", "हिन्दी"), ("id", "Bahasa Indonesia"),
        ("sv", "Svenska"), ("th", "ไทย"), ("vi", "Tiếng Việt"),
    ]

    /// 选择界面语言（representedObject 为空 = 跟随系统）
    @objc nonisolated private func selectLanguage(_ sender: NSMenuItem) {
        // 先提取值类型，避免非 Sendable 的 NSMenuItem 跨隔离域传递（Swift 6 严格并发）
        let code = sender.representedObject as? String ?? ""
        MainActor.assumeOnMainThread {
            Self.applyInterfaceLanguage(code)
        }
    }

    /// 应用界面语言选择：写入偏好并同步 AppleLanguages（Bundle 本地化解析依据，重启生效）。
    /// App 菜单的 SwiftUI 命令与状态图标菜单共用此入口
    static func applyInterfaceLanguage(_ code: String) {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: appLanguageDefaultsKey) ?? ""
        guard current != code else { return }
        if code.isEmpty {
            // 跟随系统：移除偏好与覆盖，恢复系统级语言解析
            defaults.removeObject(forKey: appLanguageDefaultsKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(code, forKey: appLanguageDefaultsKey)
            defaults.set([code], forKey: "AppleLanguages")
        }
        promptRestartForLanguageChange()
    }

    /// 语言更改需重启应用生效；仅提示用户手动重启。
    /// 不提供「立即重启」：自动派生新实例 + 退出旧实例的方案在实测中不可靠
    /// （单实例守卫与新进程派生的时序在开发签名/未签名构建下不受控），改为用户手动重启最稳妥
    private static func promptRestartForLanguageChange() {
        let alert = NSAlert()
        alert.messageText = String(localized: "切换语言")
        alert.informativeText = String(localized: "界面语言已更改，重启应用后生效。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }

    /// 退出应用
    ///
    /// 录音中退出走**统一停止入口**（`RecordingViewModel.stopMeetingRecording`）：
    /// 旧实现先直接调用服务的 `stopRecording()`，服务随即变成 isRecording=false，
    /// 之后发出的停止通知在 ViewModel 侧被 `guard isMeetingRecording` 拦下，
    /// 封存/合并/入库整段被跳过——结果是磁盘上有文件、本次却没有数据库条目，
    /// 只能等下次启动的磁盘扫描补录。这里改为：只发停止通知，等待入库完成再退出。
    @objc nonisolated private func quitApp() {
        MainActor.assumeOnMainThread {
            guard recorder.isRecording else {
                NSApp.terminate(nil)
                return
            }
            Task { @MainActor in
                await Self.stopRecordingBeforeQuit(recorder: recorder)
                NSApp.terminate(nil)
            }
        }
    }

    /// 发停止通知并等待统一停止流程完成。
    /// 完成判据优先用 ViewModel 收尾后回发的通知；同时以「服务已停且合并不进行中」
    /// 作为兜底，避免通知无人响应（主窗口未挂载）时永久等待。
    @MainActor
    private static func stopRecordingBeforeQuit(recorder: MeetingRecorderService) async {
        let finished = LockedBox(false)
        let token = NotificationCenter.default.addObserver(
            forName: .menuBarStopRecordingCompleted, object: nil, queue: .main
        ) { _ in
            finished.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        NotificationCenter.default.post(name: .menuBarStopRecording, object: nil)

        let deadline = Date().addingTimeInterval(quitStopTimeout)
        while Date() < deadline {
            if finished.value { return }
            if !recorder.isRecording, !recorder.isMerging { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // 超时：不再等待。退出流程仍会做紧急收尾，已录分片由下次启动恢复拼接
        Self.logger.warning("退出前等待录音停止流程超时，改由退出收尾兜底")
    }

    // MARK: - 截图动作

    /// 区域截图（菜单栏触发）
    @objc nonisolated private func startRegionScreenshot() {
        MainActor.assumeOnMainThread {
            NotificationCenter.default.post(
                name: .menuBarStartScreenshot,
                object: nil,
                userInfo: ["mode": ScreenshotManager.CaptureMode.region.rawValue]
            )
        }
    }

    /// 窗口截图（菜单栏触发）
    @objc nonisolated private func startWindowScreenshot() {
        MainActor.assumeOnMainThread {
            NotificationCenter.default.post(
                name: .menuBarStartScreenshot,
                object: nil,
                userInfo: ["mode": ScreenshotManager.CaptureMode.window.rawValue]
            )
        }
    }

    /// 全屏截图（菜单栏触发）
    @objc nonisolated private func startFullscreenScreenshot() {
        MainActor.assumeOnMainThread {
            NotificationCenter.default.post(
                name: .menuBarStartScreenshot,
                object: nil,
                userInfo: ["mode": ScreenshotManager.CaptureMode.fullscreen.rawValue]
            )
        }
    }

    // MARK: - 录屏（菜单栏）

    @objc nonisolated private func startScreenRecordingFullScreen() {
        postScreenRecordingTarget("fullScreen")
    }

    @objc nonisolated private func startScreenRecordingRegion() {
        postScreenRecordingTarget("region")
    }

    @objc nonisolated private func startScreenRecordingWindow() {
        postScreenRecordingTarget("window")
    }

    private nonisolated func postScreenRecordingTarget(_ raw: String) {
        MainActor.assumeOnMainThread {
            NotificationCenter.default.post(
                name: .menuBarStartScreenRecording,
                object: nil,
                userInfo: ["target": raw]
            )
        }
    }

    /// 录屏声源选择（独立于会议录音设置，存 UserDefaults）。
    /// NSMenuItem 非 Sendable：在 hop 前提取字符串；AppKit action 回调必在主线程，
    /// assumeOnMainThread 语义成立
    @objc nonisolated private func selectScreenSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        MainActor.assumeOnMainThread {
            UserDefaults.standard.set(raw, forKey: ScreenRecordingQuality.sourceDefaultsKey)
            refreshScreenRecordingMenuStates()
        }
    }

    /// 录屏质量档位选择（同上：先提取 Sendable 字符串再切主 actor）
    @objc nonisolated private func selectScreenQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        MainActor.assumeOnMainThread {
            UserDefaults.standard.set(raw, forKey: ScreenRecordingQuality.qualityDefaultsKey)
            refreshScreenRecordingMenuStates()
        }
    }

    private func refreshScreenRecordingMenuStates() {
        let source = ScreenRecordingQuality.savedSource().rawValue
        for item in screenSourceItems {
            item.state = (item.representedObject as? String == source) ? .on : .off
        }
        let quality = ScreenRecordingQuality.saved().rawValue
        for item in screenQualityItems {
            item.state = (item.representedObject as? String == quality) ? .on : .off
        }
    }

    // MARK: - 麦克风子菜单

    /// 麦克风选择（与设置页共用同一偏好：空串 = 跟随系统默认输入设备）。
    /// NSMenuItem 非 Sendable：hop 前先取出 uid 字符串；AppKit action 回调必在主线程
    @objc nonisolated private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        MainActor.assumeOnMainThread {
            MicrophoneDeviceRegistry.saveSelectionUID(uid.isEmpty ? nil : uid)
            refreshMicrophoneMenu(signature: microphoneMenuSignature())
        }
    }

    /// 静音 / 解除静音麦克风（与录音徽章菜单同一条命令：都走 MeetingRecorderService.toggleLocalMute）。
    /// NSMenuItem 非 Sendable：这里不读取 sender，只切主 actor 后执行并刷新菜单
    @objc nonisolated private func toggleMicMute() {
        MainActor.assumeOnMainThread {
            recorder.toggleLocalMute()
            refreshState()
        }
    }

    /// 设备集合 + 当前选择 + 「开始时静音」偏好的指纹：任一变化都需要重建子菜单项。
    /// 偏好纳入指纹：设置页或截图会话工具栏改过它之后，菜单栏的勾选态要在一秒内跟上
    private func microphoneMenuSignature() -> String {
        let uids = MicrophoneDeviceRegistry.availableDevices().map(\.uid).joined(separator: ",")
        let startMuted = MicrophoneStartMutePreference.isEnabled() ? "1" : "0"
        return uids + "#" + (MicrophoneDeviceRegistry.savedSelectionUID() ?? "") + "#" + startMuted
    }

    /// 按指纹重建或仅刷新勾选态（切换麦克风只改偏好，下次录音生效，与声源/质量 radio 同语义）
    private func refreshMicrophoneMenu(signature: String) {
        guard signature != lastMicrophoneSignature else {
            refreshMicrophoneMenuStates()
            return
        }
        lastMicrophoneSignature = signature
        rebuildMicrophoneSubmenu()
    }

    private func rebuildMicrophoneSubmenu() {
        guard let submenu = microphoneMenuItem?.submenu else { return }
        submenu.removeAllItems()
        microphoneItems.removeAll()
        microphoneMuteItem = nil
        microphoneStartMutedItem = nil
        microphoneStartMutedSeparator = nil

        // 静音命令：与设备列表同处一个「麦克风」子菜单，选设备的地方就能静音。
        // 运行时命令只对进行中的录音有效，空闲时禁用并说明原因（见 refreshMicrophoneMenuStates）
        let muteItem = NSMenuItem(
            title: MicMuteCommand.title(isMuted: false),
            action: #selector(toggleMicMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        submenu.addItem(muteItem)
        microphoneMuteItem = muteItem

        // 「录音开始时静音麦克风」预设：空闲时用菜单栏预设下一场录音的初始静音状态，
        // 与设置页「录音 → 输入设备」、截图会话工具栏麦克风菜单读写同一份偏好。
        // 录音中隐藏（只对下一场生效的开关摆在运行中的命令旁会误导，本场改静音走上一条命令）
        let startMutedItem = NSMenuItem(
            title: String(localized: "录音开始时静音麦克风"),
            action: #selector(toggleStartMuted(_:)),
            keyEquivalent: ""
        )
        startMutedItem.target = self
        startMutedItem.state = MicrophoneStartMutePreference.isEnabled() ? .on : .off
        submenu.addItem(startMutedItem)
        microphoneStartMutedItem = startMutedItem

        let startMutedSeparator = NSMenuItem.separator()
        submenu.addItem(startMutedSeparator)
        microphoneStartMutedSeparator = startMutedSeparator

        let followItem = NSMenuItem(
            title: String(localized: "跟随系统默认"),
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        followItem.target = self
        followItem.representedObject = ""
        submenu.addItem(followItem)
        microphoneItems.append(followItem)

        let devices = MicrophoneDeviceRegistry.availableDevices()
        if !devices.isEmpty { submenu.addItem(.separator()) }

        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            submenu.addItem(item)
            microphoneItems.append(item)
        }

        // 已选设备已拔出：显式占位，避免勾选态凭空消失（实际采集会回退系统默认）
        if let uid = MicrophoneDeviceRegistry.savedSelectionUID(),
           !devices.contains(where: { $0.uid == uid }) {
            submenu.addItem(.separator())
            let missingItem = NSMenuItem(
                title: String(localized: "已断开，将回退系统默认"),
                action: nil,
                keyEquivalent: ""
            )
            missingItem.representedObject = uid
            submenu.addItem(missingItem)
            microphoneItems.append(missingItem)
        }

        refreshMicrophoneMenuStates()
    }

    private func refreshMicrophoneMenuStates() {
        let selected = MicrophoneDeviceRegistry.savedSelectionUID() ?? ""
        for item in microphoneItems {
            guard let uid = item.representedObject as? String else { continue }
            item.state = (uid == selected) ? .on : .off
        }

        // 静音命令：标题与图标表达「这一步会做什么」（勾选态留给下面的偏好项与设备项，
        // 命令项不显示对钩，避免与「所选设备」的勾选混淆），可用性与系统/会议软件静音口径一致。
        // 空闲时没有可静音的采集链路，禁用并说明；录音中若静音来自系统或会议软件，
        // 同样不能在 App 内解除（与徽章菜单的 disabled 条件同源）
        let isRecording = recorder.isRecording
        let isMuted = recorder.isMicMuted
        let source = recorder.muteSource
        guard let muteItem = microphoneMuteItem else { return }
        muteItem.title = MicMuteCommand.title(isMuted: isMuted)
        muteItem.image = NSImage(
            systemSymbolName: MicMuteCommand.iconName(isMuted: isMuted),
            accessibilityDescription: nil
        )
        muteItem.isEnabled = isRecording && MicMuteCommand.canToggle(isMuted: isMuted, source: source)
        if !isRecording {
            muteItem.toolTip = String(localized: "录音开始后可静音麦克风")
        } else if !MicMuteCommand.canToggle(isMuted: isMuted, source: source) {
            muteItem.toolTip = MicMuteCommand.helpText(isMuted: isMuted, source: source)
        } else {
            muteItem.toolTip = nil
        }

        // 「开始时静音」预设只在空闲时出现（勾选态由重建时的偏好决定）
        microphoneStartMutedItem?.isHidden = isRecording
        microphoneStartMutedSeparator?.isHidden = isRecording
    }

    /// 切换「录音开始时静音麦克风」偏好（空闲时预设下一场录音；与设置页、截图工具栏同一份）。
    /// NSMenuItem 非 Sendable：只切主 actor，读偏好取反后立即重建子菜单刷新勾选态
    @objc nonisolated private func toggleStartMuted(_ sender: NSMenuItem) {
        MainActor.assumeOnMainThread {
            MicrophoneStartMutePreference.set(!MicrophoneStartMutePreference.isEnabled())
            refreshMicrophoneMenu(signature: microphoneMenuSignature())
        }
    }

    // MARK: - 主窗口控制

    /// 主窗口是否可见
    private func isMainWindowShown() -> Bool {
        return mainWindows.contains { $0.isVisible }
    }

    /// 获取所有主窗口（排除菜单栏状态项面板、提示框等）
    /// SwiftUI 的 WindowGroup 窗口都是 NSWindow 子类，有 contentView 且有 titled 样式
    /// （internal：AppDelegate 的 reopen 处理需据此判断窗口是否丢失）
    var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            // 必须有 contentView（排除空面板）
            window.contentView != nil &&
            // 排除菜单栏状态项的小面板（statusItem.button 所在窗口）
            !window.className.contains("StatusBar") &&
            !window.className.contains("NSStatusBarWindow") &&
            // 排除 tooltip / menu 等瞬态窗口
            window.styleMask.contains(.titled)
        }
    }

    /// 显示主窗口，并恢复 Dock 图标
    func showMainWindow() {
        windowVisibilityRequest &+= 1
        let request = windowVisibilityRequest
        for window in mainWindows {
            (window.delegate as? HideOnCloseWindowDelegate)?.cancelPendingHide()
        }
        // 先恢复 Dock 图标，再显示窗口（避免 accessory 模式下窗口无法成为 key）
        NSApp.setActivationPolicy(.regular)
        // 给 run loop 一点时间让 policy 生效
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowVisibilityRequest == request else { return }
            // 覆盖 SwiftUI 可能新建的窗口（首次启动/被销毁重建后），保证关闭即隐藏始终生效
            self.attachHideOnCloseDelegates()
            let windows = self.mainWindows
            if windows.isEmpty {
                // 窗口可能已被关闭，通过通知让 App 重新打开
                NotificationCenter.default.post(name: .menuBarShowMainWindow, object: nil)
                return
            }
            for window in windows {
                // makeKeyAndOrderFront 不会还原最小化窗口，必须先 deminiaturize；
                // 否则点 Dock 图标后窗口仍留在最小化状态
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                // SwiftUI 已知缺陷：activationPolicy 在 .regular ↔ .accessory 之间切换后，
                // 侧栏 NSToolbar 中的 SwiftUI 托管项不会被重新注入（列表栏按钮消失）。
                // 对 isVisible 做一次关→开切换，强制工具栏重建条目视图
                if let toolbar = window.toolbar, toolbar.isVisible {
                    toolbar.isVisible = false
                    DispatchQueue.main.async {
                        toolbar.isVisible = true
                    }
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 隐藏主窗口，并同时隐藏 Dock 图标（避免在共享屏幕时暴露）
    func hideMainWindow() {
        windowVisibilityRequest &+= 1
        let request = windowVisibilityRequest
        attachHideOnCloseDelegates()
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.windowVisibilityRequest == request else { return }
            // 全屏 Space 必须先退出，才能隐藏 Dock；中途失败时保留可恢复的窗口。
            guard self.mainWindows.allSatisfy({ !$0.isVisible && !$0.styleMask.contains(.fullScreen) }) else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
        let windows = mainWindows
        if windows.isEmpty { finish() }
        for window in windows {
            (window.delegate as? HideOnCloseWindowDelegate)?.hide(window, completion: finish)
        }
    }

    /// 为所有主窗口挂“关闭即隐藏”委托（幂等：已挂过的跳过）。
    /// 背景：窗口对象一旦被销毁（红点关闭 / policy 反复切换的副作用），
    /// showMainWindow 将无窗口可显示；接管关闭为隐藏可从源头消除红点路径的销毁。
    private func attachHideOnCloseDelegates() {
        pruneHideOnCloseDelegates()
        for window in mainWindows {
            if window.delegate is HideOnCloseWindowDelegate { continue }
            let hideDelegate = HideOnCloseWindowDelegate()
            // 若已有委托（如 SwiftUI 内部委托），保留并转发，不破坏原有窗口行为
            hideDelegate.forwardTo = window.delegate
            hideDelegate.attachedWindow = window
            window.delegate = hideDelegate
            // 控制器强持有，保证委托对象生命周期覆盖整个窗口生命周期
            hideOnCloseDelegates[ObjectIdentifier(hideDelegate)] = hideDelegate
        }
    }

    /// 清理目标窗口已销毁的委托：窗口被 SwiftUI 释放后对应条目随之移除，
    /// 使 `hideOnCloseDelegates` 的大小始终不超过当前主窗口数量
    private func pruneHideOnCloseDelegates() {
        guard !hideOnCloseDelegates.isEmpty else { return }
        let aliveWindowIDs = Set(NSApp.windows.map { ObjectIdentifier($0) })
        hideOnCloseDelegates = hideOnCloseDelegates.filter { _, delegate in
            guard let window = delegate.attachedWindow else { return false }
            return aliveWindowIDs.contains(ObjectIdentifier(window))
        }
    }
}

// MARK: - 关闭即隐藏窗口委托

/// 主窗口关闭拦截：点红色关闭按钮时只隐藏不销毁，保持与菜单栏「隐藏主窗口」同构。
/// 窗口对象始终存活，点 Dock 图标/reopen 总能拉回窗口；
/// 其余委托方法原样转发给原有委托（如有），不改变其它窗口行为。
@MainActor
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    private static let logger = Logger(subsystem: "app.memozia", category: "WindowVisibility")

    weak var forwardTo: NSWindowDelegate?

    /// 所服务窗口的弱引用：供控制器清理「窗口已销毁」的委托条目（不改变窗口所有权）
    weak var attachedWindow: NSWindow?

    private enum FullScreenTransition { case entering, exiting }
    private var fullScreenTransition: FullScreenTransition?
    private var hideRequested = false
    private var hideCompletions: [@MainActor () -> Void] = []

    /// 未显式实现的 NSWindowDelegate 回调一律转发给原委托。
    /// `responds(to:)` 必须同时重写：ObjC 运行时默认只看本类方法表，
    /// 否则 AppKit 会认为「委托不实现该回调」而跳过转发，SwiftUI 依赖的
    /// 其余回调（窗口变主窗口、工具栏/全屏相关等）会静默丢失。
    override nonisolated func responds(to aSelector: Selector!) -> Bool {
        // 此代理仅供主线程的 AppKit 窗口委托查询，沿用工程的主线程桥接。
        MainActor.assumeOnMainThread {
            super.responds(to: aSelector) || (forwardTo?.responds(to: aSelector) ?? false)
        }
    }

    override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? {
        MainActor.assumeOnMainThread { forwardTo }
    }

    /// 返回 false 阻止销毁；全屏时先退出 Space，再隐藏保留的窗口。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(sender)
        return false
    }

    func hide(_ window: NSWindow, completion: (@MainActor () -> Void)? = nil) {
        hideRequested = true
        if let completion { hideCompletions.append(completion) }
        completeHideWhenWindowed(window)
    }

    func cancelPendingHide() {
        hideRequested = false
        hideCompletions.removeAll()
        // AppKit 的动画仍在进行，保留 transition，供下一次请求等待其完成。
    }

    private func completeHideWhenWindowed(_ window: NSWindow) {
        guard hideRequested, fullScreenTransition == nil else { return }
        if window.styleMask.contains(.fullScreen) {
            fullScreenTransition = .exiting
            window.toggleFullScreen(nil)
            return
        }
        hideRequested = false
        window.orderOut(nil)
        let completions = hideCompletions
        hideCompletions.removeAll()
        for completion in completions { completion() }
    }

    private func resumePendingHide(_ window: NSWindow) {
        // 给 AppKit/SwiftUI 完成 Space 与窗口样式收尾的机会；恢复操作可在此期间取消隐藏。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.completeHideWhenWindowed(window)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = .entering
        forwardTo?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = nil
        forwardTo?.windowDidEnterFullScreen?(notification)
        if let window = notification.object as? NSWindow { resumePendingHide(window) }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransition = .exiting
        forwardTo?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = nil
        forwardTo?.windowDidExitFullScreen?(notification)
        if let window = notification.object as? NSWindow { resumePendingHide(window) }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = nil
        forwardTo?.windowDidFailToEnterFullScreen?(window)
        resumePendingHide(window)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = nil
        if hideRequested {
            Self.logger.error("退出全屏失败，取消隐藏请求并保留窗口")
            cancelPendingHide()
        }
        forwardTo?.windowDidFailToExitFullScreen?(window)
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingHide()
        forwardTo?.windowWillClose?(notification)
    }

    func windowDidResize(_ notification: Notification) {
        forwardTo?.windowDidResize?(notification)
    }

    func windowDidMove(_ notification: Notification) {
        forwardTo?.windowDidMove?(notification)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        forwardTo?.windowDidMiniaturize?(notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        forwardTo?.windowDidDeminiaturize?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        forwardTo?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        forwardTo?.windowDidResignKey?(notification)
    }
}

#endif

// MARK: - 通知名（跨平台：RootView 在 iOS/macOS 均订阅这些通知）

extension Notification.Name {
    /// 菜单栏请求开始录音
    static let menuBarStartRecording = Notification.Name("menuBarStartRecording")
    /// 菜单栏请求停止录音
    static let menuBarStopRecording = Notification.Name("menuBarStopRecording")
    /// 统一停止流程（封存 + 合并 + 入库）已完成。菜单栏退出等待它后再终止进程，
    /// 避免「服务已停 → 停止通知被 guard 拦下 → 跳过入库」导致本次录音没有数据库条目
    static let menuBarStopRecordingCompleted = Notification.Name("menuBarStopRecordingCompleted")
    /// 菜单栏请求显示主窗口（窗口已关闭时）
    static let menuBarShowMainWindow = Notification.Name("menuBarShowMainWindow")
    /// 分布式通知：第二个实例启动时，请求已有实例显示主窗口（跨进程）。
    /// 用于隐藏主窗口（accessory）后点 Dock 图标误启动新实例的场景。
    static let MemoziaShowMainWindowFromOtherInstance = Notification.Name("app.memozia.showMainWindowFromOtherInstance")
    /// 菜单栏请求打开设置
    static let menuBarOpenSettings = Notification.Name("menuBarOpenSettings")
    /// 菜单栏请求从剪贴板新建快捷笔记
    static let menuBarCreateQuickNoteFromClipboard = Notification.Name("menuBarCreateQuickNoteFromClipboard")
    /// 请求打开帮助页
    static let openHelp = Notification.Name("openHelp")
    /// 应用菜单 ⌘N：打开「新建快捷笔记」面板（此前主链路没有窗口内快捷键）
    static let appMenuNewQuickNote = Notification.Name("appMenuNewQuickNote")
    /// 应用菜单 ⌘O：打开导入音频/视频
    static let appMenuImportMedia = Notification.Name("appMenuImportMedia")
    /// 打开处理队列面板（任务入队后的「查看队列」入口、帮助页引导等共用）
    static let openTaskQueuePanel = Notification.Name("openTaskQueuePanel")
}
