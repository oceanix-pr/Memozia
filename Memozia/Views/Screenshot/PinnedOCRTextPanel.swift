#if os(macOS)
import AppKit

/// 钉住窗口右侧的 OCR 识别文字面板。
///
/// 内容为一个可编辑、可选中复制的纯文本视图，外加状态行与「复制全部」按钮。
/// 只由工具栏「OCR识别」入口创建（普通「钉住」右侧不会出现文字面板）；
/// 面板跟随钉住窗口移动/缩放贴靠其右侧，右侧空间不足时自动改放左侧，
/// 并始终夹取在屏幕可视区内，避免被推到屏外。
///
/// 宿主 App 处于 accessory 态且截图流程刻意不激活 App（激活会触发主窗口弹出），
/// 因此面板用 nonactivatingPanel + becomesKeyOnlyIfNeeded：平时不抢焦点，
/// 用户点进文本区才开始编辑。
@MainActor
final class PinnedOCRTextPanel: NSObject {

    /// 面板默认尺寸与与钉住窗口的间距
    private static let preferredWidth: CGFloat = 320
    private static let preferredHeight: CGFloat = 420
    private static let gap: CGFloat = 8
    /// 与屏幕可视区边缘保留的最小间距
    private static let edgeMargin: CGFloat = 4

    let panel: NSPanel
    private let textView: NSTextView
    private let statusLabel: NSTextField
    /// 钉住窗口（弱引用：钉住窗关闭时会话会释放它，此处只需停止跟随）
    private weak var host: NSWindow?
    /// 因系统面板临时隐藏前是否处于可见态（决定要不要恢复）
    private var wasVisibleBeforeSystemPanel = false

    init(host: NSWindow) {
        self.host = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "OCR识别")
        // 与钉住窗口同层级，二者一起悬浮在其他应用之上
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        // 不主动抢 key：点进文本区编辑或点按钮时才需要 key
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentMinSize = NSSize(width: 220, height: 160)

        // 状态行（识别中/已识别字数/失败原因）+ 复制按钮
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(
            title: String(localized: "复制全部"), target: nil, action: nil)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = NSFont.systemFont(ofSize: 11)
        copyButton.toolTip = String(localized: "把识别文字复制到剪贴板")
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [statusLabel, copyButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        // 文本区放在滚动视图里，长文可上下滚动
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // 可编辑 + 可复制：识别结果常有个别错字，允许就地改；选区直接 ⌘C 复制
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        // 关闭自动纠错类替换，避免用户改回来的字又被改掉
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = textView

        let content = NSView()
        content.addSubview(header)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // 状态行吃满剩余宽度，按钮保持固有宽度靠右
        statusLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        panel.contentView = content

        self.panel = panel
        self.textView = textView
        self.statusLabel = statusLabel

        super.init()

        copyButton.target = self
        copyButton.action = #selector(copyAllToPasteboard)

        // 跟随钉住窗口移动/缩放
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowChanged),
                name: name,
                object: host
            )
        }
        repositionBesideHost()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 对外接口

    /// 上屏（已显示时无副作用），并按钉住窗口当前位置重新贴靠
    func show() {
        repositionBesideHost()
        panel.orderFrontRegardless()
    }

    /// 关窗并停止跟随（钉住窗口关闭/会话结束时由会话调用）
    func dismiss() {
        NotificationCenter.default.removeObserver(self)
        panel.orderOut(nil)
    }

    /// 系统保存面板弹出期间的临时隐藏：保留对钉住窗口的跟随观察，
    /// 并记住原本是否可见，以便面板结束后原位恢复
    func hideTemporarily() {
        wasVisibleBeforeSystemPanel = panel.isVisible
        guard wasVisibleBeforeSystemPanel else { return }
        panel.orderOut(nil)
    }

    /// 系统面板结束后恢复隐藏前的显示状态（仅当之前可见）
    func restoreAfterSystemPanel() {
        guard wasVisibleBeforeSystemPanel else { return }
        wasVisibleBeforeSystemPanel = false
        repositionBesideHost()
        panel.orderFrontRegardless()
    }

    /// 写入识别文字（覆盖用户已有编辑，因此仅在每次新识别后调用）
    func setText(_ text: String) {
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }

    /// 更新状态行文案
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: - 事件

    /// 复制全部识别文字（用户编辑后的内容即为复制内容）
    @objc private func copyAllToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        statusLabel.stringValue = String(localized: "已复制到剪贴板")
    }

    @objc private func hostWindowChanged() {
        repositionBesideHost()
    }

    // MARK: - 定位

    /// 贴靠钉住窗口右侧；右侧放不下改放左侧，最后夹取到屏幕可视区内
    private func repositionBesideHost() {
        guard let host,
              let screen = host.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size

        var origin = NSPoint(
            x: host.frame.maxX + Self.gap,
            y: host.frame.maxY - size.height
        )
        // 右侧越界则改放左侧
        if origin.x + size.width > visible.maxX - Self.edgeMargin {
            origin.x = host.frame.minX - Self.gap - size.width
        }
        origin.x = min(max(origin.x, visible.minX + Self.edgeMargin),
                       visible.maxX - size.width - Self.edgeMargin)
        // 顶对齐钉住窗口，纵向夹取
        origin.y = min(max(origin.y, visible.minY + Self.edgeMargin),
                       visible.maxY - size.height - Self.edgeMargin)

        panel.setFrameOrigin(origin)
    }
}
#endif
