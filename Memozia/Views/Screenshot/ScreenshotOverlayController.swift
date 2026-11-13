#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit
import os.log

/// 标注视图的会话宿主协议：全屏截图/重新标注会话（RegionSelectionController）
/// 与钉住窗口会话（PinnedWindowSession）共用，视图仅依赖此接口上报结果
@MainActor
protocol AnnotationSessionHost: AnyObject {
    func finish(_ outcome: RegionSelectionController.Outcome)

    /// 弹系统面板（如 NSSavePanel）前临时揭开宿主窗口。
    /// 全屏悬浮层为 .screenSaver 层级，会压住 .modalPanel 层级的保存面板，必须先揭开；
    /// 默认无操作（钉住窗/重标窗为 .floating，本就在系统面板之下）
    func suspendHostWindowsForSystemPanel()

    /// 系统面板结束后恢复宿主窗口，会话继续（用户取消保存不丢已绘标注）
    func resumeHostWindowsAfterSystemPanel()
}

extension AnnotationSessionHost {
    func suspendHostWindowsForSystemPanel() {}
    func resumeHostWindowsAfterSystemPanel() {}
}

/// 统一捕获会话的启动意图
enum CaptureIntent {
    /// 截图（默认）：选目标后自由从工具栏选出口
    case screenshot
    /// 录屏直达：选定目标（框选/窗口拾取/空格全屏）后自动进入录制倒计时；
    /// 倒计时中 Esc 仍返回会话，出口完全自由（保存/复制/钉住/录制均可）
    case record
}

/// 统一捕获会话控制器（截图 + 录制出口）：
/// 1. 冻结所有屏幕（SCScreenshotManager，排除自身 App 窗口入镜）
/// 2. 每屏创建一个悬浮面板承载冻结图，进行框选/窗口拾取/标注
/// 3. 工具栏统一出口：保存/复制/钉住/OCR/保存文件/录制（录屏目标随结果上抛，
///    由上层复用现有录屏链路）；会话结束后回收面板并回调结果
@MainActor
class RegionSelectionController: NSObject, AnnotationSessionHost {

    static let shared = RegionSelectionController()

    /// 会话结果
    enum Outcome {
        /// 确认保存：原图 PNG + 标注版 PNG（无标注时为 nil）+ 像素尺寸 + 实际捕获模式
        /// captureMode 记录用户现场的实际操作（点窗=window / 框选=region / 全屏=fullscreen），与入口模式无关
        case saved(originalPNG: Data, markedPNG: Data?, pixelWidth: Int, pixelHeight: Int, captureMode: String)
        /// 已复制到剪贴板（不入库）
        case copied
        /// 已保存为文件：截图写入用户在系统保存面板所选的位置，path 为最终文件路径
        case savedToDisk(path: String)
        /// 钉住：当前选区（含已绘标注）栅格化为单张 PNG，由上层开启置顶钉住窗口
        case pinned(png: Data)
        /// OCR 识别并钉住：同样开启置顶钉住窗口，并在窗口右侧附一个可编辑、可复制的
        /// 识别文字面板（单纯「钉住」没有该面板，这是两者唯一区别）
        case pinnedWithOCR(png: Data)
        /// 录制出口：以当前选区/拾取窗口/全屏为录屏目标，由上层走现有录屏链路启动
        case recordRequested(target: ScreenRecordingTarget)
        /// 用户取消（ESC / 右键 / 取消按钮）
        case cancelled
        /// 失败（权限/捕获异常）
        case failed(String)
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "ScreenshotOverlay")

    /// 单屏捕获数据
    struct CaptureData {
        let screen: NSScreen
        let frozenImage: CGImage
        /// 该屏上可拾取的窗口（视图坐标，按 `CGWindowListCopyWindowInfo` 的权威前→后顺序）
        let windowRects: [NSRect]
        /// 与 windowRects 同序的窗口 ID：点选拾取后把选区升级为独立窗口录制目标用
        let windowIDs: [CGWindowID]

        init(screen: NSScreen, frozenImage: CGImage, windowRects: [NSRect], windowIDs: [CGWindowID] = []) {
            self.screen = screen
            self.frozenImage = frozenImage
            self.windowRects = windowRects
            self.windowIDs = windowIDs
        }
    }

    private var panels: [OverlayPanel] = []
    /// 重新标注编辑窗（独立于全屏悬浮层：带标题栏、可手动调整大小）
    private var reannotatePanel: ReannotatePanel?
    private var onOutcome: ((Outcome) -> Void)?
    private(set) var isIdle: Bool = true
    /// 会话开始前的 key 窗口：悬浮层 makeKey 会抢走它，结束时先归还再揭开，避免主窗体闪白
    private weak var previousKeyWindow: NSWindow?

    /// 会话是否已有可见窗口承载（全屏悬浮层或重新标注窗）。
    /// 用于区分两种「非空闲」：用户正看着会话界面（重复触发无需提示，且告警窗层级低于
    /// .screenSaver 悬浮层会被完全遮住）与「非空闲却看不到任何界面」——后者说明会话卡在
    /// 启动阶段，用户只会看到「按热键毫无反应」，必须给出提示
    var hasVisibleSessionWindow: Bool {
        !panels.isEmpty || reannotatePanel != nil
    }

    /// 会话启动代次：finish() 结束时自增，使尚未返回的冻结结果被 begin 续体按代次丢弃
    private var sessionGeneration = 0

    /// 启动（冻结屏幕）阶段看门狗。SCScreenshotManager 在权限/系统状态异常时不保证返回，
    /// 而 `isIdle` 原先只在 finish() 里复位：一旦 `captureAllDisplays()` 挂起，isIdle 会永久为
    /// false，之后所有截图/录屏入口（含两条全局热键）都被静默忽略，直到用户重启应用。
    /// 到点强制结束会话，交还空闲状态并把失败原因上报给用户
    private var startupWatchdog: Task<Void, Never>?

    /// 会话启动阶段上限
    private static let startupTimeout: TimeInterval = 10

    private override init() {
        super.init()
    }

    // MARK: - 会话生命周期

    /// 启动会话（冻结屏幕 → 展示悬浮层）
    /// - Parameters:
    ///   - mode: 捕获模式
    ///   - intent: 会话意图（.record 时选定目标后自动进入录制倒计时）
    ///   - onOutcome: 会话结束回调（主线程）
    func begin(
        mode: ScreenshotManager.CaptureMode,
        intent: CaptureIntent = .screenshot,
        onOutcome: @escaping (Outcome) -> Void
    ) {
        guard isIdle else { return }
        self.onOutcome = onOutcome
        isIdle = false
        // 冻结屏幕期间由看门狗兜底：SCScreenshotManager 不返回时不至于让 isIdle 永久为 false
        let generation = beginStartupWatchdog()

        Task { @MainActor in
            // 记录截图前的 key 窗口（悬浮层稍后 makeKey 会抢走它），finish 时归还
            previousKeyWindow = NSApp.keyWindow
            let data = await Self.captureAllDisplays()
            // 看门狗已判定启动超时并结束会话：丢弃迟到的冻结结果，避免失败提示之后又弹出悬浮层
            guard generation == self.sessionGeneration else {
                Self.logger.error("截图会话冻结结果迟到（启动已超时结束），丢弃")
                return
            }
            self.cancelStartupWatchdog()
            guard !data.isEmpty else {
                self.finish(.failed(String(localized: "无法捕获屏幕内容，请检查屏幕录制权限")))
                return
            }

            let mouseLocation = NSEvent.mouseLocation
            // 全屏模式：所有屏各建面板；其他模式同样所有屏建面板
            let targetScreens = data.map(\.screen)

            for capture in data where targetScreens.contains(where: { $0.frame == capture.screen.frame }) {
                let panel = OverlayPanel(screen: capture.screen)
                let view = OverlayAnnotationView(frame: NSRect(origin: .zero, size: capture.screen.frame.size))
                view.configure(capture: capture, controller: self)
                // 统一捕获会话：仅全屏悬浮层面板开放「录制」出口；
                // 重新标注/钉住编辑窗（非实时屏幕）不提供
                let allowsScreenRecording = FeaturePolicy(
                    experience: AppExperiencePreference.resolved()
                ).allows(.screenRecording)
                if allowsScreenRecording {
                    view.enableScreenRecording()
                }
                if intent == .record && allowsScreenRecording {
                    view.armAutoRecordOnSelection()
                }
                panel.contentView = view
                self.panels.append(panel)
            }

            NSCursor.crosshair.set()
            // 不激活 App：悬浮层是 nonactivatingPanel，orderFrontRegardless + makeKey 即可
            // 接收键鼠事件（ESC/回车/空格/标注快捷键/文字输入）。若调用 NSApp.activate，
            // 会把主窗口带到前台遮挡用户当前画面；accessory 态（主窗口隐藏）下还会触发
            // applicationDidBecomeActive → showMainWindow，表现为「截图时跳出本应用」。
            // 这里直接冻结当前屏幕覆盖显示，用户停留在原应用。

            // 全屏模式：预选整屏（放在 orderFront 之前，首帧渲染即含选区与工具栏）
            if mode == .fullscreen {
                for case let view as OverlayAnnotationView in self.panels.compactMap(\.contentView) {
                    view.preselectFullScreen()
                }
            }

            // 悬浮层淡入：先置全透明上屏并强制绘制冻结图，再用 0.1s 把不透明度从 0 渐变到 1。
            // 诊断已确认几何像素级对齐（frozenImage=屏幕@2x、panel.frame=screen.frame、
            // convertToBacking 精确 2x），冻结图与实时屏幕逐像素重合，所以“弹出瞬间闪一下”
            // 不是错位，而是“整屏突然压暗 15% + 画面冻结”的瞬时突变。淡入让二者平滑过渡
            // （像素一致时视觉上等同于压暗缓缓生效），消除突兀闪现；透明首帧也遮住未绘好的空白帧。
            for panel in self.panels {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                panel.displayIfNeeded()
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                for panel in self.panels {
                    panel.animator().alphaValue = 1
                }
            }, completionHandler: {
                // 淡入完成（悬浮层已完全不透明盖住主窗口）后再抢 key：主窗口 resign 重绘
                // 发生在完全遮挡之后，不外露。makeKey 不激活 App（nonactivatingPanel）。
                // completionHandler 是 @Sendable 非隔离闭包，须经 assumeOnMainThread 进入 MainActor
                // 才能访问 panels/isVisible/makeKey；key 面板在此按鼠标位置重算，避免把非 Sendable
                // 的 OverlayPanel 捕获进 @Sendable 闭包（会话若已取消则 panels 为空，自然跳过）。
                MainActor.assumeOnMainThread {
                    let keyPanel = self.panels.first(where: { $0.screenFrame.contains(mouseLocation) }) ?? self.panels.first
                    if let keyPanel, keyPanel.isVisible {
                        keyPanel.makeKey()
                    }
                }
            })

            Self.logger.info("截图会话已启动（mode=\(mode.rawValue)，screens=\(self.panels.count)）")
        }
    }

    /// 从已有图片重新标注（不截屏，直接进入标注阶段）。
    /// 不再铺满全屏：按图片尺寸适配一个居中编辑窗（优先 1:1 锐利显示，超屏时等比缩小），
    /// 窗口可手动调整大小（锁定图片纵横比），标注几何随缩放等比跟随
    /// - Parameters:
    ///   - imageData: 原始图片 PNG 数据
    ///   - onOutcome: 会话结束回调
    func reannotate(imageData: Data, onOutcome: @escaping (Outcome) -> Void) {
        guard isIdle else { return }
        self.onOutcome = onOutcome
        isIdle = false

        Task { @MainActor in
            // 同 begin：记录标注前的 key 窗口，finish 时归还
            previousKeyWindow = NSApp.keyWindow
            guard let editor = ReannotatePanel.makeEditorWindow(
                title: String(localized: "重新标注"), imageData: imageData) else {
                self.finish(.failed(String(localized: "无法加载图片")))
                return
            }

            editor.view.configure(capture: editor.capture, controller: self)
            editor.panel.delegate = self
            reannotatePanel = editor.panel

            // 直接进入标注阶段：预选整幅图片（选区 = 视图 bounds，等同全屏模式语义）
            editor.view.preselectFullScreen()

            // 会话由应用内入口发起（主窗口可见、App 活跃），编辑窗直接上屏抢 key 接收键鼠；
            // nonactivatingPanel 不会激活 App
            editor.panel.makeKeyAndOrderFront(nil)

            Self.logger.info("重新标注会话已启动（imageSize=\(editor.capture.frozenImage.width)x\(editor.capture.frozenImage.height)，panel=\(Int(editor.view.bounds.width))x\(Int(editor.view.bounds.height))）")
        }
    }

    /// 结束会话（视图层调用）
    func finish(_ outcome: Outcome) {
        guard !isIdle else { return }
        // 作废在途启动：代次自增 + 停掉看门狗，使尚未返回的冻结结果被 begin 续体丢弃
        sessionGeneration += 1
        cancelStartupWatchdog()
        // begin() 里悬浮层通过 makeKey 抢走了原窗口的 key。若直接 orderOut 揭开，
        // AppKit 要到下一帧才把 key 还给原窗口，揭开瞬间主窗体会先以「非活跃」外观出现、
        // 随即重绘变亮 —— 表现为整体闪白/重绘。这里在揭开前同步把 key 归还原窗口，
        // 使「归还 key + 揭开悬浮层」落在同一帧合成，主窗体直接以稳定外观出现。
        // 仅当 App 处于活跃态时归还：非活跃态不抢焦点，避免「截图跳出本应用」回归。
        if NSApp.isActive, let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        if let panel = reannotatePanel {
            panel.delegate = nil
            panel.orderOut(nil)
            reannotatePanel = nil
        }
        NSCursor.arrow.set()
        isIdle = true
        overlaySuspended = false
        let callback = onOutcome
        onOutcome = nil
        callback?(outcome)
    }

    // MARK: - 启动看门狗

    /// 启动看门狗：返回本次启动的代次，供 begin 续体判断冻结结果是否已被作废
    private func beginStartupWatchdog() -> Int {
        startupWatchdog?.cancel()
        startupWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startupTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.startupWatchdog != nil, !self.isIdle else { return }
            Self.logger.error("截图会话启动超时（\(Int(Self.startupTimeout))s）未完成，结束会话并报失败")
            self.finish(.failed(String(localized: "无法捕获屏幕内容，请重试")))
        }
        return sessionGeneration
    }

    /// 停掉启动看门狗（启动已完成或会话已结束）
    private func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    // MARK: - 系统面板临时揭开

    /// 悬浮层是否因系统面板（保存窗）被临时揭开
    private var overlaySuspended = false

    /// 揭开全屏悬浮层以露出系统面板：App 为 accessory 态，不能 NSApp.activate
    /// （applicationDidBecomeActive 会把主窗口弹出来），只能靠揭开悬浮层让面板可见可点
    func suspendHostWindowsForSystemPanel() {
        guard !overlaySuspended, hasVisibleSessionWindow else { return }
        overlaySuspended = true
        for panel in panels {
            panel.orderOut(nil)
        }
        reannotatePanel?.orderOut(nil)
    }

    /// 恢复悬浮层/编辑窗并把 key 还给鼠标所在屏的面板，会话从标注阶段原地继续
    func resumeHostWindowsAfterSystemPanel() {
        guard overlaySuspended else { return }
        overlaySuspended = false
        if let reannotatePanel {
            reannotatePanel.makeKeyAndOrderFront(nil)
            return
        }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first(where: { $0.screenFrame.contains(mouse) }) ?? panels.first
        keyPanel?.makeKey()
    }

    // MARK: - 屏幕捕获

    /// 冻结所有屏幕（完整捕获当前画面，包含 Memozia 自身窗口，可正常截取本应用界面）
    private static func captureAllDisplays() async -> [CaptureData] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else {
            logger.error("无法获取 SCShareableContent")
            return []
        }

        // 可拾取窗口：普通层级、非桌面壁纸
        // layer 0 = 普通应用窗口；壁纸/Dock/菜单栏等系统窗口为其它层级，必须排除，
        // 否则整屏大小的壁纸 rect 会先于真实窗口命中 contains 检测，导致点窗截成全屏
        // 不排除 Memozia 自身：悬浮层面板在捕获完成后才创建（此刻不存在），且为 .screenSaver
        // 层级（windowLayer != 0）本就被上面的 layer == 0 过滤，故主窗口可像普通窗口一样点选
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let pickableWindows: [(rect: NSRect, screenFrame: NSRect, id: CGWindowID)] = content.windows.compactMap { window in
            guard window.windowLayer == 0,
                  window.frame.width > 20, window.frame.height > 20 else { return nil }
            guard let screen = NSScreen.screens.first(where: {
                $0.frame.intersects(window.frame)
            }) else { return nil }
            // SCWindow.frame 为左上原点全局坐标 → 转换为该屏视图坐标（左下原点）
            let globalBottomLeftY = mainMaxY - window.frame.maxY
            let viewRect = NSRect(
                x: window.frame.minX - screen.frame.minX,
                y: globalBottomLeftY - screen.frame.minY,
                width: window.frame.width,
                height: window.frame.height
            )
            return (viewRect, screen.frame, window.windowID)
        }

        // 前→后排序：`SCShareableContent.windows` 的顺序未经 Apple 承诺，只靠它无法保证
        // `first { contains }` 命中最前面的窗口——可能取到被遮挡的后窗，录屏时表现为
        // 「录到当前窗口后面的窗口」。`CGWindowListCopyWindowInfo` 的返回顺序才是权威前→后，
        // 用它给可拾取窗口重排（窗口 ID 与 rect 同源，重排保证点选 ID 与高亮框一致）
        let zIndex = frontToBackWindowZIndex()
        let missingZOrder = pickableWindows.filter { zIndex[$0.id] == nil }.map { $0.id }
        if !missingZOrder.isEmpty {
            Self.logger.debug("\(missingZOrder.count) 个可拾取窗口不在 CGWindowList 中，已排到末尾：\(missingZOrder)")
        }
        let orderedPickableWindows = sortedFrontToBack(pickableWindows, zIndex: zIndex)

        var results: [CaptureData] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            // excludingApplications 传空：不排除任何 App（含 Memozia 自身），完整捕获当前画面
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
            configuration.showsCursor = false
            configuration.capturesAudio = false

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                // 全局已按前→后排序，按屏过滤后各屏仍保持前→后
                let onScreen = orderedPickableWindows.filter { $0.screenFrame == screen.frame }
                results.append(CaptureData(
                    screen: screen,
                    frozenImage: image,
                    windowRects: onScreen.map(\.rect),
                    windowIDs: onScreen.map(\.id)
                ))
            } catch {
                logger.error("捕获屏幕失败（displayID=\(displayID)）：\(error.localizedDescription)")
            }
        }
        return results
    }

    // MARK: - 窗口 z 序（权威前→后）

    /// 权威前→后窗口顺序：`CGWindowListCopyWindowInfo` 的返回顺序即前→后。
    /// `SCShareableContent.windows` 只用于取 `SCWindow` 对象（`desktopIndependentWindow`
    /// 需要它），顺序不可依赖
    nonisolated static func frontToBackWindowZIndex() -> [CGWindowID: Int] {
        let list = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]) ?? []
        var index: [CGWindowID: Int] = [:]
        index.reserveCapacity(list.count)
        for (offset, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            index[number.uint32Value] = offset
        }
        return index
    }

    /// 按权威 z 序重排可拾取窗口；未出现在 `zIndex` 中的窗口（罕见：两次枚举之间窗口增删）
    /// 退到末尾，并保持原有相对顺序（显式以原下标兜底，`sorted` 不保证稳定）
    nonisolated static func sortedFrontToBack(
        _ windows: [(rect: NSRect, screenFrame: NSRect, id: CGWindowID)],
        zIndex: [CGWindowID: Int]
    ) -> [(rect: NSRect, screenFrame: NSRect, id: CGWindowID)] {
        windows.enumerated().sorted { lhs, rhs in
            let l = zIndex[lhs.element.id] ?? Int.max
            let r = zIndex[rhs.element.id] ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map { $0.element }
    }

    /// 直接捕获指定屏幕（无悬浮层，用于全屏直拍热键：立即成图不经标注）
    static func captureDirect(screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else {
            logger.error("无法获取 SCShareableContent")
            return nil
        }

        // 不排除任何 App（含 Memozia 自身），与悬浮层截图行为一致：完整捕获当前画面
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(screen.frame.width * scale)
        configuration.height = Int(screen.frame.height * scale)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

// MARK: - 悬浮面板

/// 覆盖整个屏幕的悬浮面板（无边界、不激活 App 也能显示）
final class OverlayPanel: NSPanel {

    let screenFrame: NSRect

    init(screen: NSScreen) {
        self.screenFrame = screen.frame
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }
}

// MARK: - 重新标注编辑窗

/// 重新标注/钉住编辑面板：带标题栏与标准缩放手柄，可手动调整大小；
/// 锁定内容纵横比为图片纵横比（缩放时图片不变形），nonactivating 保持不激活 App
final class ReannotatePanel: NSPanel {

    init(title: String, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = title
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces]
        contentMinSize = NSSize(width: 320, height: 240)
        // 锁定纵横比：用户缩放窗口时内容保持图片宽高比
        aspectRatio = NSSize(width: max(1, contentSize.width), height: max(1, contentSize.height))
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    /// 构建按图片尺寸适配并居中的编辑窗（含标注视图，未 configure/未接 delegate）。
    /// 尺寸策略：优先图片物理尺寸（像素 ÷ 屏幕缩放，1:1 锐利显示），
    /// 超出主屏可视区 80% 时等比缩小；窗口居中于主屏可视区。
    /// 重新标注（标题「重新标注」）与钉住（标题「钉住」）两个入口共用。
    /// - Returns: 编辑窗三元组；图片解码失败或无主屏时返回 nil
    static func makeEditorWindow(
        title: String,
        imageData: Data
    ) -> (panel: ReannotatePanel, view: OverlayAnnotationView, capture: RegionSelectionController.CaptureData)? {
        guard let imageRep = NSBitmapImageRep(data: imageData),
              let cgImage = imageRep.cgImage,
              let screen = NSScreen.main else { return nil }

        let backingScale = screen.backingScaleFactor
        let naturalWidth = CGFloat(cgImage.width) / backingScale
        let naturalHeight = CGFloat(cgImage.height) / backingScale
        let maxW = screen.visibleFrame.width * 0.8
        let maxH = screen.visibleFrame.height * 0.8
        let fit = min(1, maxW / max(1, naturalWidth), maxH / max(1, naturalHeight))
        let viewSize = NSSize(width: naturalWidth * fit, height: naturalHeight * fit)

        let panel = ReannotatePanel(title: title, contentSize: viewSize)
        // 居中于主屏可视区（frameRect 含标题栏，需用整窗尺寸计算偏移）
        let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: viewSize))
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.midY - frame.height / 2
        ))

        let view = OverlayAnnotationView(frame: NSRect(origin: .zero, size: viewSize))
        let capture = RegionSelectionController.CaptureData(
            screen: screen, frozenImage: cgImage, windowRects: [], windowIDs: [])
        panel.contentView = view
        return (panel, view, capture)
    }
}

// MARK: - 钉住窗口会话

/// 钉住窗口：置顶常驻显示截图（可继续标注、缩放窗口）。
/// 确认 → 按普通截图入库；取消/关闭 → 仅关窗不入库；
/// 工具栏钉住按钮保持选中且不可再操作（无法嵌套钉住）。
/// 独立于 RegionSelectionController 会话状态——钉住期间仍可开启新的截图会话
@MainActor
final class PinnedWindowSession: NSObject, AnnotationSessionHost, NSWindowDelegate {

    private static let logger = Logger(subsystem: "app.memozia", category: "ScreenshotPin")

    private let panel: ReannotatePanel
    private let view: OverlayAnnotationView
    /// 会话结束回调（从管理方列表移除自身）
    private let onEnd: (PinnedWindowSession) -> Void
    private var didFinish = false
    /// 右侧 OCR 识别文字面板（仅「OCR识别」入口创建，普通钉住为 nil）
    private var ocrPanel: PinnedOCRTextPanel?
    /// 钉住窗与文字面板是否因系统面板（保存窗）被临时揭开
    private var hostWindowsSuspended = false

    /// - Parameter showOCR: 是否在开启时立即识别图片文字并在窗口右侧展示文字面板
    ///   （由工具栏「OCR识别」传入；单纯「钉住」不传，右侧不会出现文字）
    init?(imageData: Data, showOCR: Bool = false, onEnd: @escaping (PinnedWindowSession) -> Void) {
        guard let editor = ReannotatePanel.makeEditorWindow(
            title: String(localized: "钉住"), imageData: imageData) else { return nil }
        self.panel = editor.panel
        self.view = editor.view
        self.onEnd = onEnd
        super.init()

        view.configure(capture: editor.capture, controller: self)
        view.configureAsPinned()
        panel.delegate = self

        // 直接进入标注阶段：整幅图片即选区；窗口为 floating 层级，始终置顶
        view.preselectFullScreen()
        panel.makeKeyAndOrderFront(nil)

        if showOCR {
            presentOCRPanel(for: imageData)
        }

        Self.logger.info("钉住窗口已开启（imageSize=\(editor.capture.frozenImage.width)x\(editor.capture.frozenImage.height)，ocr=\(showOCR)）")
    }

    // MARK: - OCR 文字面板

    /// 在钉住窗口右侧挂载/刷新 OCR 文字面板，并异步识别 png。
    /// 重复点击「OCR识别」复用同一面板，仅重新识别并覆盖文字
    func presentOCRPanel(for png: Data) {
        let textPanel = ocrPanel ?? PinnedOCRTextPanel(host: panel)
        ocrPanel = textPanel
        textPanel.show()
        textPanel.setStatus(String(localized: "识别中…"))
        Task { @MainActor [weak textPanel] in
            do {
                let text = try await VisionOCRService.recognizeText(from: png)
                guard let textPanel else { return }
                textPanel.setText(text)
                textPanel.setStatus(text.isEmpty
                    ? String(localized: "未识别到文字")
                    : String(format: String(localized: "已识别 %lld 字，可直接编辑或复制"), text.count))
            } catch {
                textPanel?.setStatus(String(format: String(localized: "识别失败：%@"), error.localizedDescription))
            }
        }
    }

    // MARK: - 系统面板临时揭开

    /// 保存面板弹出期间临时揭开钉住窗与其文字面板：不依赖面板层级的隐含假设，
    /// 保证保存窗可见可输；面板结束后原位恢复（不重新居中，保留用户拖动后的位置）
    func suspendHostWindowsForSystemPanel() {
        guard !hostWindowsSuspended else { return }
        hostWindowsSuspended = true
        panel.orderOut(nil)
        ocrPanel?.hideTemporarily()
    }

    func resumeHostWindowsAfterSystemPanel() {
        guard hostWindowsSuspended else { return }
        hostWindowsSuspended = false
        panel.makeKeyAndOrderFront(nil)
        ocrPanel?.restoreAfterSystemPanel()
    }

    // MARK: - AnnotationSessionHost

    func finish(_ outcome: RegionSelectionController.Outcome) {
        // 钉住窗口内点「OCR识别」：只挂/刷新右侧文字面板，钉住窗口本身保持不关
        if case .pinnedWithOCR(let png) = outcome {
            presentOCRPanel(for: png)
            return
        }
        guard !didFinish else { return }
        didFinish = true
        panel.delegate = nil
        panel.orderOut(nil)
        ocrPanel?.dismiss()
        ocrPanel = nil
        onEnd(self)

        switch outcome {
        case .saved(let originalPNG, let markedPNG, let pixelWidth, let pixelHeight, let captureMode):
            // 钉住内容最终确认：按普通截图入库
            NotificationCenter.default.post(
                name: .screenshotCaptureSaved,
                object: nil,
                userInfo: [
                    "originalPNG": ScreenshotPayloadBox(originalPNG),
                    "markedPNG": markedPNG.map { ScreenshotPayloadBox($0) } as Any,
                    "pixelWidth": pixelWidth,
                    "pixelHeight": pixelHeight,
                    "captureMode": captureMode,
                ]
            )
        case .copied:
            Self.logger.info("钉住截图已复制到剪贴板")
            postCaptureNotice(String(localized: "截图已复制到剪贴板"))
        case .savedToDisk(let path):
            Self.logger.info("钉住截图已保存：\(path)")
            postCaptureNotice(String(format: String(localized: "截图已保存到 %@"), path))
        case .cancelled:
            Self.logger.info("钉住窗口已关闭（不入库）")
        case .failed(let reason):
            Self.logger.error("钉住窗口操作失败：\(reason)")
        case .pinned, .pinnedWithOCR, .recordRequested:
            break // 钉住窗口内钉住按钮已禁用；OCR 已在上方就地处理；录制出口仅全屏会话开放（钉住窗不可达）
        }
    }

    /// 一次性结果提示（已复制 / 已保存）：交 RootView 顶部横幅呈现。
    /// 钉住窗不持有主窗口可见性判断，直接投递；主窗口隐藏时横幅无人可见，但无副作用。
    private func postCaptureNotice(_ message: String) {
        NotificationCenter.default.post(
            name: .screenshotCaptureNotice,
            object: nil,
            userInfo: ["message": message]
        )
    }

    // MARK: - NSWindowDelegate

    /// 关闭按钮等同取消（仅关窗不入库）
    func windowWillClose(_ notification: Notification) {
        finish(.cancelled)
    }
}

// MARK: - 重新标注窗关闭处理

extension RegionSelectionController: NSWindowDelegate {
    /// 关闭按钮等同取消会话（ESC/取消按钮之外的第三个退出入口）
    func windowWillClose(_ notification: Notification) {
        guard !isIdle else { return }
        finish(.cancelled)
    }
}
#endif
