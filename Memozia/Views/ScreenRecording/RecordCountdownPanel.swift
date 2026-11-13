#if os(macOS)
// 统一捕获会话的录制出口倒计时层：截图会话内点「录制」（或「录选区/录窗口」
// 直达项选定目标后），以选区红框 + 3-2-1 数字提示录制范围并给用户反悔窗口。
// - 点击任意处 = 立即开始；Esc = 取消并返回标注会话（选区/标注原样保留）。
// - 屏幕内容是实时画面（不冻结）：只画边框与文字，不遮挡目标区域，避免误以为
//   标注会被烧录进视频。
import AppKit

/// 录制倒计时控制器：由 OverlayAnnotationView 持有，会话面板在倒计时期间
/// 通过 suspendHostWindowsForSystemPanel/resumeHostWindowsAfterSystemPanel 让位/还原
@MainActor
final class RecordCountdownController {

    /// 倒计时走完或用户点击跳过（调用方结束会话并携带录屏目标）
    var onComplete: (() -> Void)?
    /// 用户 Esc 取消（调用方恢复标注会话）
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    /// 选区在该屏视图坐标系（左下原点，points）中的矩形，与标注视图坐标系一致
    private let regionInViewCoords: NSRect
    /// 数字下方的提示行（点击立即开始 · Esc 取消）
    private let hint: String
    /// 第二行偏好摘要（质量/声源，录制是 GB 级磁盘成本，启动前最后确认点）
    private let settingsSummary: String

    private var panel: OverlayPanel?
    private weak var countdownView: RecordCountdownView?
    private var countdownTask: Task<Void, Never>?
    /// 结果只派发一次：任务自然结束 / 点击跳过 / Esc 取消三路竞态收敛
    private var didDispatch = false

    init(
        screen: NSScreen,
        regionInViewCoords: NSRect,
        settingsSummary: String
    ) {
        self.screen = screen
        self.regionInViewCoords = regionInViewCoords
        self.settingsSummary = settingsSummary
        self.hint = String(localized: "点击立即开始 · Esc 取消")
    }

    /// 上屏并开始 3 秒倒计时（初值立即绘制，其后每秒递减）
    func start(seconds: Int = 3) {
        guard panel == nil, !didDispatch else { return }
        let view = RecordCountdownView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            region: regionInViewCoords,
            hint: hint,
            settingsSummary: settingsSummary,
            count: seconds
        )
        view.onSkip = { [weak self] in self?.complete() }
        view.onCancelRequest = { [weak self] in self?.cancel() }
        // 复用截图会话同款面板：borderless + nonactivating + .screenSaver，
        // 不激活 App（activate 会把主窗口弹出来）
        let panel = OverlayPanel(screen: screen)
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.countdownView = view
        NSCursor.arrow.set()

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: seconds - 1, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || self.didDispatch { return }
                self.countdownView?.update(count: remaining)
            }
            // 数字 1 再停留一秒后开始录制
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !self.didDispatch else { return }
            self.complete()
        }
    }

    private func complete() {
        guard !didDispatch else { return }
        didDispatch = true
        teardown()
        onComplete?()
    }

    private func cancel() {
        guard !didDispatch else { return }
        didDispatch = true
        teardown()
        onCancel?()
    }

    private func teardown() {
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
        countdownView = nil
    }
}

/// 倒计时覆盖视图：选区外轻遮罩 + 选区红框 + 居中数字 + 提示行
private final class RecordCountdownView: NSView {

    var onSkip: (() -> Void)?
    var onCancelRequest: (() -> Void)?

    private let region: NSRect
    private let hint: String
    private let settingsSummary: String
    private var count: Int

    init(frame: NSRect, region: NSRect, hint: String, settingsSummary: String, count: Int) {
        self.region = region
        self.hint = hint
        self.settingsSummary = settingsSummary
        self.count = count
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(count: Int) {
        self.count = count
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 目标区域外压暗：明确「红框内才会被录进去」
        NSColor.black.withAlphaComponent(0.2).setFill()
        let path = NSBezierPath(rect: bounds)
        path.appendRect(region)
        path.windingRule = .evenOdd
        path.fill()

        // 选区红框（实线 2pt，与录制中状态色一致）
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: region)
        border.lineWidth = 2
        border.stroke()

        // 数字：区域中心（白字加投影，亮背景上仍可读）
        let numberShadow = NSShadow()
        numberShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        numberShadow.shadowOffset = NSSize(width: 0, height: -1)
        numberShadow.shadowBlurRadius = 6
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 88, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: numberShadow,
        ]
        let numberString = NSAttributedString(string: "\(count)", attributes: numberAttrs)
        let numberSize = numberString.size()
        numberString.draw(at: NSPoint(
            x: region.midX - numberSize.width / 2,
            y: region.midY - numberSize.height / 2 + 18
        ))

        // 提示行 + 偏好摘要：数字下方
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let summaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let hintString = NSAttributedString(string: hint, attributes: hintAttrs)
        let summaryString = NSAttributedString(string: settingsSummary, attributes: summaryAttrs)
        let hintSize = hintString.size()
        let summarySize = summaryString.size()
        hintString.draw(at: NSPoint(
            x: region.midX - hintSize.width / 2,
            y: region.midY - hintSize.height / 2 - 24
        ))
        summaryString.draw(at: NSPoint(
            x: region.midX - summarySize.width / 2,
            y: region.midY - summarySize.height / 2 - 24 - hintSize.height - 4
        ))
    }

    override func mouseUp(with event: NSEvent) {
        onSkip?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancelRequest?()
        case 36, 76, 49: // Enter / 数字键盘 Enter / Space → 立即开始
            onSkip?()
        default:
            super.keyDown(with: event)
        }
    }
}
#endif
