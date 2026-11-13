import Foundation
#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
import os.log

/// 应用层静音检测器
///
/// 通过 macOS Accessibility API 轮询检测 Teams/Zoom 等会议软件中静音按钮的状态。
/// 当会议软件使用应用层静音（非系统级 mute）时，本检测器可识别并通知上层。
///
/// 工作原理：
/// 1. 通过 NSWorkspace 检测目标会议软件是否正在运行
/// 2. 对 Electron 应用（Teams）显式开启 AXManualAccessibility
/// 3. 通过 Accessibility API 搜索会议窗口中的静音按钮（不限 Role）
/// 4. 根据按钮描述判断当前是否处于静音状态（"Unmute" = 已静音）
/// 5. 通过轮询定时器以 1 秒间隔检测状态变化
///
/// 前提条件：用户需要在「系统设置 → 隐私与安全性 → 辅助功能」中授予本应用权限。
///
/// 线程安全：
/// - 本类不使用 @MainActor 隔离，轮询在后台串行队列执行
/// - AX API 本身是线程安全的
/// - 回调通过 Task { @MainActor } 通知上层
/// - 跨线程共享状态通过 stateLock 保护
final class AppMuteDetector: @unchecked Sendable {

    private let logger = Logger(subsystem: "app.memozia", category: "AppMuteDetector")

    /// 状态锁：保护跨线程访问的可变状态（start/stop 在 MainActor，pollMuteState 在 pollQueue）
    private let stateLock = NSLock()

    /// 静音状态变化回调（true = 已静音，false = 已解除静音）
    private var _onMuteChange: ((Bool) -> Void)?
    var onMuteChange: ((Bool) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onMuteChange }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onMuteChange = newValue }
    }

    /// 当前是否处于应用层静音（供外部读取，仅在实际变化时更新）
    private var _isAppMuted = false
    var isAppMuted: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isAppMuted
    }

    /// 轮询队列
    private let pollQueue = DispatchQueue(label: "app.memoziamute.poll")

    /// 轮询定时器
    private var timer: DispatchSourceTimer?

    /// 是否正在运行
    private var _isRunning = false
    private var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isRunning = newValue }
    }

    /// 目标应用的 Bundle ID 列表
    private let targetBundleIDs: Set<String>

    /// 最后已知的静音状态（用于检测变化）
    private var _lastMutedState = false
    private var lastMutedState: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastMutedState }
        set { stateLock.lock(); defer { stateLock.unlock() }; _lastMutedState = newValue }
    }

    /// 已开启 AX 的 PID 集合（避免重复设置）
    private var _enabledAXPIDs: Set<pid_t> = []
    /// 诊断 dump 标志：每个窗口只 dump 一次避免刷屏
    private var _dumpedWindowTitles: Set<String> = []

    /// 递归搜索最大深度（Teams2 的 AXWebArea 在 depth=10，按钮在 12-20+）
    private let maxSearchDepth = 35

    // MARK: - 初始化

    init(bundleIDs: Set<String> = AppMuteDetector.defaultTargets) {
        self.targetBundleIDs = bundleIDs
    }

    /// 默认监控的会议应用
    static let defaultTargets: Set<String> = [
        "com.microsoft.teams",       // Microsoft Teams (classic)
        "com.microsoft.teams2",      // Microsoft Teams (new)
        "us.zoom.xos",               // Zoom
        "com.tencent.meeting",       // 腾讯会议
    ]

    // MARK: - 生命周期

    /// 开始检测
    /// - Returns: 是否成功启动（辅助功能权限未授予时返回 false）
    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            logger.debug("start() 被调用但已在运行，跳过")
            return true
        }

        logger.info("App 静音检测启动中...")

        // 检查 Accessibility 权限
        #if DEBUG
        // 仅开发构建：开发签名下每次编译 CDHash 变化，TCC 中旧条目失效，先清理再请求。
        // 发布版绝不能自动抹掉用户已有的辅助功能授权。
        let trusted = AXIsProcessTrusted()
        if !trusted {
            resetAccessibilityTCC()
        }
        #endif

        // 使用带 prompt 的选项触发系统弹窗
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt" as String: true]
        let prompted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !prompted {
            logger.warning("辅助功能权限未授予，App 静音检测不可用")
            // C-5: 启动失败时返回 false，便于上层反馈用户
            return false
        }

        stateLock.lock()
        _isRunning = true
        _lastMutedState = false
        _isAppMuted = false
        _enabledAXPIDs.removeAll()
        _dumpedWindowTitles.removeAll()
        stateLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        // 每 1 秒轮询一次（平衡响应速度与 CPU 开销，Electron AX 树搜索较重）
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.pollMuteState()
        }
        timer.resume()
        self.timer = timer

        logger.info("App 静音检测已启动，监控应用: \(self.targetBundleIDs.joined(separator: ", "))")
        return true
    }

    /// 停止检测
    func stop() {
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        timer?.cancel()
        timer = nil
        _isRunning = false
        _isAppMuted = false
        _lastMutedState = false
        _enabledAXPIDs.removeAll()
        stateLock.unlock()
        logger.info("App 静音检测已停止")
    }

    // MARK: - 轮询逻辑

    private func pollMuteState() {
        let muted = detectMuteState()

        stateLock.lock()
        let changed = (muted != _lastMutedState)
        if changed {
            _lastMutedState = muted
            _isAppMuted = muted
        }
        stateLock.unlock()

        // 仅在状态变化时记录 info 日志，轮询明细降到 debug，避免每秒刷屏
        if changed {
            logger.info("[AX轮询] 状态变化: \(muted ? "已静音" : "已解除静音")")
            Task { @MainActor [weak self] in
                self?.onMuteChange?(muted)
            }
        } else {
            logger.debug("[AX轮询] result=\(muted ? "已静音" : "未静音")")
        }
    }

    /// 检测当前是否有会议应用处于静音状态
    private func detectMuteState() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier else { return false }
            return targetBundleIDs.contains(bid)
        }

        if runningApps.isEmpty {
            logger.debug("detectMuteState: 没有运行中的目标应用")
            return false
        }

        for app in runningApps {
            if isAppMutedInRunningApp(app) {
                return true
            }
        }

        return false
    }

    /// 检查指定应用中的静音按钮状态
    private func isAppMutedInRunningApp(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // 对 Electron/Chromium 应用开启 AX 树暴露
        enableAccessibilityIfNeeded(for: pid, appElement: appElement)

        // 获取应用的所有窗口
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        )

        guard windowsResult == .success else {
            logger.debug("PID=\(pid) 获取窗口失败，错误码=\(windowsResult.rawValue)")
            return false
        }

        guard let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            logger.debug("PID=\(pid) 窗口列表为空")
            return false
        }

        for (winIndex, window) in windows.enumerated() {
            if let muteButton = findMuteButton(in: window, depth: 0) {
                let muted = isMutedFromButton(muteButton)
                logger.debug("窗口[\(winIndex)] 找到静音按钮, isMuted=\(muted)")
                return muted
            } else {
                #if DEBUG
                // 诊断：每个窗口只 dump 一次（仅 DEBUG 构建，避免发布版大量日志）
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let winTitle = (titleRef as? String) ?? "(无标题)"
                let dumpKey = "\(winIndex)_\(winTitle)"
                stateLock.lock()
                let alreadyDumped = _dumpedWindowTitles.contains(dumpKey)
                if !alreadyDumped {
                    _dumpedWindowTitles.insert(dumpKey)
                }
                stateLock.unlock()
                if !alreadyDumped {
                    print("[AppMuteDetector] ===== 开始 AX 树 dump 窗口[\(winIndex)]\"\(winTitle)\" =====")
                    dumpAXTree(element: window, depth: 0, maxDepth: 36, prefix: "窗口[\(winIndex)]")
                    print("[AppMuteDetector] ===== AX 树 dump 结束 =====")
                }
                #endif
            }
        }

        return false
    }

    /// 诊断方法：打印 AX 元素树结构（仅 DEBUG 构建，用于排查找不到按钮的问题）
    #if DEBUG
    private func dumpAXTree(element: AXUIElement, depth: Int, maxDepth: Int, prefix: String) {
        guard depth <= maxDepth else { return }

        let indent = String(repeating: "  ", count: depth)
        let role = getAttributeValue(element, kAXRoleAttribute as String) ?? "?"
        let desc = getAccessibilityDescription(for: element) ?? ""
        let domID = getDOMIdentifier(for: element)
        let title = getAttributeValue(element, kAXTitleAttribute as String) ?? ""

        var info = "[AppMuteDetector] [Dump] \(indent)\(prefix) role=\(role)"
        if !title.isEmpty { info += " title=\"\(title)\"" }
        if !desc.isEmpty { info += " desc=\"\(desc)\"" }
        if !domID.isEmpty { info += " domID=\"\(domID)\"" }
        print(info)

        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        )
        guard childrenResult == .success,
              let children = childrenRef as? [AXUIElement] else { return }

        for (i, child) in children.enumerated() {
            dumpAXTree(element: child, depth: depth + 1, maxDepth: maxDepth, prefix: "[\(i)]")
        }
    }
    #endif

    /// 获取 AX 元素的指定属性值（字符串）
    private func getAttributeValue(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        if result == .success, let str = ref as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    /// 对 Electron/Chromium 应用开启 AX 树暴露
    /// - Electron 应用（旧版 Teams）：需要 AXManualAccessibility
    /// - Chromium/WebView2 应用（新版 Teams2）：需要 AXEnhancedUserInterface
    /// 两者都设置以覆盖不同内核
    private func enableAccessibilityIfNeeded(for pid: pid_t, appElement: AXUIElement) {
        stateLock.lock()
        if _enabledAXPIDs.contains(pid) {
            stateLock.unlock()
            return
        }
        _enabledAXPIDs.insert(pid)
        stateLock.unlock()

        var enableFlag: UInt8 = 1
        let enableValue = CFNumberCreate(kCFAllocatorDefault, .sInt8Type, &enableFlag)

        // 1. AXManualAccessibility（Electron）
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            enableValue as CFTypeRef
        )
        logger.info("已为 PID \(pid) 设置 AXManualAccessibility=true")

        // 2. AXEnhancedUserInterface（Chromium/WebView2 — 新版 Teams 使用此属性）
        // 这是 VoiceOver 触发 Chromium 暴露无障碍树的方式
        AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            enableValue as CFTypeRef
        )
        logger.info("已为 PID \(pid) 设置 AXEnhancedUserInterface=true")
    }

    /// 清理当前 app 的辅助功能 TCC 条目（仅限 DEBUG 构建）
    /// 开发签名下每次编译 CDHash 变化会积累残留条目，导致授权错位
    #if DEBUG
    private func resetAccessibilityTCC() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            process.waitUntilExit()
            logger.info("[AX诊断] 已清理 Accessibility TCC 条目: \(bundleID)")
        } catch {
            logger.warning("[AX诊断] 清理 TCC 条目失败: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - AX 树搜索

    /// 在 UI 元素树中递归搜索静音按钮
    /// 优先通过 domID 匹配（Teams 的 "microphone-button"，语言无关）
    /// 回退到描述关键词匹配（Zoom 等 Native 应用），且要求元素角色为按钮，
    /// 避免把包含 mute/静音 字样的普通文本/列表项误判为静音按钮
    private func findMuteButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= maxSearchDepth else { return nil }

        // 获取 domID（Chromium/Web 应用特有）
        let domID = getDOMIdentifier(for: element)

        // 优先匹配 domID（Teams 的 microphone-button，语言无关且唯一）
        if domID == "microphone-button" {
            return element
        }

        // 描述匹配（Zoom 等原生应用 fallback）：
        // 1. 排除参与者列表中的静音状态项（domID 包含 "roster"）
        // 2. 要求元素角色为按钮（AXButton/AXToggleButton），避免误匹配文本元素
        let role = (getAttributeValue(element, kAXRoleAttribute as String) ?? "").lowercased()
        let isButtonLike = role.contains("button")
        if isButtonLike,
           !domID.lowercased().contains("roster"),
           let description = getAccessibilityDescription(for: element),
           isMuteRelatedDescription(description) {
            return element
        }

        // 递归搜索子元素
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        )

        guard childrenResult == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = findMuteButton(in: child, depth: depth + 1) {
                return found
            }
        }

        return nil
    }

    // MARK: - 属性读取

    /// 获取 UI 元素的 Accessibility 描述（依次尝试多种属性，含 Web 特有属性）
    private func getAccessibilityDescription(for element: AXUIElement) -> String? {
        // 按 AX 标准属性 + Chromium/Web 特有属性优先级尝试
        let attributes: [String] = [
            kAXDescriptionAttribute as String,  // 描述（最常见）
            kAXTitleAttribute as String,        // 标题
            kAXHelpAttribute as String,         // 帮助文本
            kAXValueAttribute as String,        // 值
            kAXLabelValueAttribute as String,   // label
            "AXARIALabel" as String,           // ARIA label（Chromium/Web）
            "AXDOMIdentifier" as String,       // DOM ID（Chromium/Web）
            "AXIdentifier" as String,          // 通用 identifier
            "AXRoleDescription" as String,     // role description
        ]

        for attr in attributes {
            var valueRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attr as CFString, &valueRef)
            if result == .success {
                if let str = valueRef as? String, !str.isEmpty {
                    return str
                }
            }
        }

        return nil
    }

    /// 获取 UI 元素的 DOM 标识符（Chromium/Web 应用特有，语言无关）
    private func getDOMIdentifier(for element: AXUIElement) -> String {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, "AXDOMIdentifier" as CFString, &ref
        )
        if result == .success, let str = ref as? String {
            return str
        }
        return ""
    }

    // MARK: - 关键词匹配

    /// 判断描述文本是否为静音按钮
    /// 只匹配动作词（mute/unmute/静音），不匹配名词（mic/microphone/麦克风）
    /// 因为 "Microsoft" 包含 "mic"，"麦克风" 可能出现在窗口标题等非按钮元素中
    private func isMuteRelatedDescription(_ description: String) -> Bool {
        let lowercased = description.lowercased()

        let muteKeywords = [
            "mute", "unmute",
            "静音",
        ]

        return muteKeywords.contains { lowercased.contains($0) }
    }

    /// 根据按钮描述判断当前是否静音
    /// - "取消麦克风静音" / "Unmute" / "Turn on microphone" → 当前已静音
    /// - "静音麦克风" / "Mute" → 当前未静音
    private func isMutedFromButton(_ button: AXUIElement) -> Bool {
        guard let description = getAccessibilityDescription(for: button) else {
            return false
        }

        let lowercased = description.lowercased()

        // 英文直接匹配 unmute 类关键词
        let unmuteIndicators = [
            "unmute",
            "turn on microphone", "turn on mic",
            "打开麦克风", "打开话筒",
            "start audio", "join audio",
        ]
        if unmuteIndicators.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // 中文"取消麦克风静音"："取消"与"静音"必须同时出现才判定为已静音。
        // 只匹配"取消"会误判对话框的"取消"按钮（Cancel）导致麦克风被错误挖断。
        if lowercased.contains("取消") && lowercased.contains("静音") {
            return true
        }

        return false
    }
}
#endif
