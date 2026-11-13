#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - 标注工具栏

/// 工具按钮：hover 高亮 + 右下角当前颜色指示点
/// 必须用自定义 NSView 而非 NSButton：macOS 26 的 NSButton cell 会按
///「图标高度 + 固定内边距(约24.5pt)」生成内部必需约束，压过 intrinsicContentSize
/// 的 36×36，导致不同图标高度的按钮实际高度 38.5~46.5 不等（悬停灰底大小不一）。
/// 自定义视图完全掌控尺寸；图标用 NSImageView + contentTintColor 着色。
final class ToolButton: NSView {

    var isActive = false {
        didSet {
            refreshBackground()
            iconView.contentTintColor = isActive ? AnnotationToolbar.accent : normalTint
        }
    }
    var isHovering = false { didSet { refreshBackground() } }

    /// 仅拦截交互而保持视觉（钉住态：保持选中高亮但不可点击）
    var isInteractionDisabled = false

    /// 可用状态（撤销/重做用：禁用时整体淡化并忽略点击）
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.35
            refreshBackground()
        }
    }

    /// 右下角当前颜色指示点（nil = 该工具不用颜色，不显示）
    var indicatorColor: NSColor? {
        didSet { colorDot.isHidden = indicatorColor == nil; colorDot.layer?.backgroundColor = indicatorColor?.cgColor }
    }

    var onClick: (() -> Void)?

    /// 统一尺寸（与下排选项条目 36×36 一致）：栈视图忽略 frame，
    /// 必须通过 intrinsicContentSize + 高优先级约束固定大小
    private let buttonSize = NSSize(width: 36, height: 36)
    private let normalTint: NSColor
    private let iconView = NSImageView()
    private let colorDot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))

    init(image: NSImage, tint: NSColor, onClick: (() -> Void)? = nil) {
        self.normalTint = tint
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ToolbarItemStyle.cornerRadius
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityRole(.button)

        iconView.image = image
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = tint
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        colorDot.wantsLayer = true
        colorDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        colorDot.layer?.cornerRadius = 3
        colorDot.layer?.borderWidth = 1
        colorDot.layer?.borderColor = NSColor.white.cgColor
        colorDot.isHidden = true
        addSubview(colorDot)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize { buttonSize }

    /// 鼠标事件统一由本按钮处理，图标/指示点子视图不拦截
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        // 图标按原始尺寸居中（取整避免半像素模糊）；指示点贴右下角
        let size = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        colorDot.frame.origin = NSPoint(x: bounds.width - 10, y: 4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // 点击：按下加深反馈，抬起时仍在按钮内才触发
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isInteractionDisabled else { return }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        refreshBackground()
        guard isEnabled, !isInteractionDisabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    private func refreshBackground() {
        if !isEnabled {
            layer?.backgroundColor = ToolbarItemStyle.clearBackground
        } else if isActive {
            layer?.backgroundColor = AnnotationToolbar.accent.withAlphaComponent(0.15).cgColor
        } else if isHovering {
            layer?.backgroundColor = ToolbarItemStyle.hoverBackground
        } else {
            layer?.backgroundColor = ToolbarItemStyle.clearBackground
        }
    }
}

/// 选区下方的浮动工具栏（浅色风格，双排布局）：
/// 上排：标注工具（全部使用 SF Symbols）| 撤销重做 | 复制/取消/确认
/// 下排：选中 矩形/椭圆/箭头/画笔/文字 时显示选项（三档粗细，文字为三档字号 + 7 色），其他情况隐藏
final class AnnotationToolbar: NSView {

    var onSelectTool: ((AnnotationTool) -> Void)?
    var onSelectColor: ((NSColor) -> Void)?
    var onSelectFontSize: ((CGFloat) -> Void)?
    var onSelectLineWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// 钉住：把当前截图放入置顶窗口常驻显示
    var onPin: (() -> Void)?
    /// OCR识别：钉住当前截图，并在钉住窗口右侧显示可编辑、可复制的识别文字
    var onOCR: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    /// 保存为文件：弹系统保存面板选择位置后写入截图文件
    var onSave: (() -> Void)?
    /// 录制：以当前选区/窗口/全屏为录屏目标（统一捕获会话的动态出口）
    var onRecord: (() -> Void)?
    /// 下排选项行显隐变化时通知外层重算工具栏尺寸
    var onOptionsRowChanged: (() -> Void)?

    /// 标注颜色（7 种常用色，文字与图形共用）
    static let palette: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .black,
        .white,
    ]

    /// 调色板颜色名（与 palette 顺序一致，供 VoiceOver 读出）
    static let paletteColorNames: [String] = [
        String(localized: "红色"),
        String(localized: "橙色"),
        String(localized: "黄色"),
        String(localized: "绿色"),
        String(localized: "蓝色"),
        String(localized: "黑色"),
        String(localized: "白色"),
    ]

    /// 选中后下方显示选项排的工具（图形工具：三档粗细+颜色；文字工具：三档字号+颜色；马赛克：三档颗粒度，无颜色）
    static let toolsWithOptions: Set<AnnotationTool> = [.rect, .ellipse, .arrow, .pen, .text, .mosaic]

    /// 下排需要显示颜色行的工具（马赛克不用颜色）
    static let colorOptionTools: Set<AnnotationTool> = [.rect, .ellipse, .arrow, .pen, .text]

    /// 工具按钮右下角显示当前颜色指示点的工具
    static let colorIndicatorTools: Set<AnnotationTool> = [.rect, .ellipse, .arrow, .pen, .text]

    /// 标注类型 → 对应工具（选中标注时驱动下排选项行）
    static func tool(for kind: AnnotationShape.Kind) -> AnnotationTool {
        switch kind {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .text: return .text
        case .mosaic: return .mosaic
        }
    }

    /// 选中高亮色（浅绿底 + 绿图标，参考 iShot 风格）
    static let accent = NSColor.systemGreen

    private var toolButtons: [AnnotationTool: ToolButton] = [:]
    private var undoButton: ToolButton!
    private var redoButton: ToolButton!
    private var pinButton: ToolButton!
    /// 录制出口按钮（非全屏捕获会话隐藏）
    private var recordButton: ToolButton?
    /// 麦克风快切按钮：与「录制」同步显隐（录音会话且声源含麦克风时展示）
    private var microphoneButton: ToolButton?
    private var activeTool: AnnotationTool = .none
    /// 驱动下排选项行的工具（选中标注时为其类型，否则等于 activeTool）
    private var optionsTool: AnnotationTool = .none
    private var activeColor: NSColor = AnnotationToolbar.palette[0]
    /// 文字字号与线条粗细（下排选项行选中态）
    private var activeFontSize: CGFloat = OverlayAnnotationView.defaultTextFontSize
    private var activeLineWidth: CGFloat = OverlayAnnotationView.defaultLineWidth

    // 双排布局：上排工具按钮；下排选项（粗细/字号 + 7 色），随选中工具显隐
    private let verticalStack = NSStackView()
    private let mainStack = NSStackView()
    private let optionsStack = NSStackView()
    private var optionsRowInstalled = false
    /// 下排内容对应的工具（文字=字号档，图形=粗细档；变化时重建内容）
    private var optionsRowKind: AnnotationTool = .none
    private var lineWidthChips: [(value: CGFloat, chip: MenuDotChip)] = []
    private var fontSizeChips: [(value: CGFloat, chip: MenuLabelChip)] = []
    private var swatches: [MenuColorSwatch] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.97).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowColor = NSColor.black.cgColor

        setAccessibilityLabel(String(localized: "截图标注工具栏"))
        setAccessibilityRole(.toolbar)

        var views: [NSView] = []

        // 选择工具（指针图标；arrowpoint 非有效符号名会渲染成问号）
        let selectButton = makeToolButton(symbol: "cursorarrow", help: String(localized: "选择/移动标注")) { [weak self] in
            self?.onSelectTool?(.select)
        }
        views.append(selectButton)
        toolButtons[.select] = selectButton

        views.append(makeSeparator())

        // 标注工具：矩形/椭圆/箭头/画笔/马赛克 + 文字（SF Symbols，名称本地化，tooltip 带快捷键）
        let tools: [(AnnotationTool, String, String)] = [
            (.rect, "rectangle", String(localized: "矩形")),
            (.ellipse, "oval", String(localized: "椭圆")),
            (.arrow, "arrow.up.right", String(localized: "箭头")),
            (.pen, "pencil", String(localized: "画笔")),
            (.mosaic, "mosaic", String(localized: "马赛克")),
        ]
        let shortcuts: [AnnotationTool: String] = [
            .rect: "R", .ellipse: "O", .arrow: "A", .pen: "P", .mosaic: "M",
        ]
        for (tool, symbol, help) in tools {
            let tooltip = help + " (\(shortcuts[tool] ?? ""))"
            let button = makeToolButton(symbol: symbol, help: tooltip + Self.optionsHint(for: tool)) { [weak self] in
                self?.onSelectTool?(tool)
            }
            views.append(button)
            toolButtons[tool] = button
        }

        let textToolButton = makeTextToolButton { [weak self] in
            self?.onSelectTool?(.text)
        }
        views.append(textToolButton)
        toolButtons[.text] = textToolButton

        views.append(makeSeparator())

        undoButton = makeToolButton(symbol: "arrow.uturn.backward", help: String(localized: "撤销")) { [weak self] in
            self?.onUndo?()
        }
        views.append(undoButton)

        redoButton = makeToolButton(symbol: "arrow.uturn.forward", help: String(localized: "重做")) { [weak self] in
            self?.onRedo?()
        }
        views.append(redoButton)

        views.append(makeSeparator())

        // 钉住：截图放入置顶窗口（与复制/取消/确认同属动作组，保持组内间距与左右边距一致）
        pinButton = makeToolButton(symbol: "pin", help: String(localized: "钉住")) { [weak self] in
            self?.onPin?()
        }
        views.append(pinButton)

        // OCR识别：先钉住，再在钉住窗口右侧展示可编辑、可复制的识别文字
        // （单纯钉住没有这块文字，是本按钮的专属行为）
        let ocrButton = makeToolButton(
            symbol: "text.viewfinder",
            help: String(localized: "OCR识别")) { [weak self] in
            self?.onOCR?()
        }
        views.append(ocrButton)

        let copyButton = makeToolButton(symbol: "doc.on.doc", help: String(localized: "复制到剪贴板")) { [weak self] in
            self?.onCopy?()
        }
        views.append(copyButton)

        // 保存为文件：弹系统保存面板选择位置，写入当前选区（含标注）后结束会话
        let saveButton = makeToolButton(
            symbol: "square.and.arrow.down",
            help: String(localized: "保存为文件…")) { [weak self] in
            self?.onSave?()
        }
        views.append(saveButton)

        // 录制：把当前选区/拾取窗口/全屏录成视频（统一捕获会话的动态出口）。
        // 默认隐藏，仅全屏捕获会话经 setRecordingSupported(true) 展示；
        // 隐藏态不参与 NSStackView 布局，非录制会话的工具栏宽度不变
        let record = makeToolButton(
            symbol: "record.circle",
            help: String(localized: "录制当前选区为视频"),
            tint: .systemRed,
            weight: .semibold
        ) { [weak self] in
            self?.onRecord?()
        }
        record.isHidden = true
        recordButton = record
        views.append(record)

        // 麦克风快切：与菜单栏「麦克风」、设置页共用同一偏好；
        // 默认隐藏，仅在录制会话经 setRecordingSupported(true) 与「录制」一并展示
        let microphone = makeToolButton(
            symbol: "microphone.badge.ellipsis",
            help: Self.microphoneTooltip()
        ) { [weak self] in
            self?.presentMicrophoneMenu()
        }
        microphone.isHidden = true
        microphoneButton = microphone
        views.append(microphone)

        let cancelButton = makeToolButton(symbol: "xmark", help: String(localized: "取消"), tint: .systemRed, weight: .semibold) { [weak self] in
            self?.onCancel?()
        }
        views.append(cancelButton)

        let confirmButton = makeToolButton(symbol: "checkmark", help: String(localized: "确认保存"), tint: .systemGreen, weight: .semibold) { [weak self] in
            self?.onConfirm?()
        }
        views.append(confirmButton)

        for view in views {
            mainStack.addView(view, in: .leading)
        }
        mainStack.orientation = .horizontal
        mainStack.spacing = 6
        mainStack.distribution = .gravityAreas
        
        optionsStack.orientation = .horizontal
        optionsStack.spacing = 8

        verticalStack.addView(mainStack, in: .leading)
        verticalStack.orientation = .vertical
        // leading 对齐：下排第一个元素与上排第一个按钮左对齐
        verticalStack.alignment = .leading
        verticalStack.spacing = 6
        verticalStack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        verticalStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(verticalStack)
        NSLayoutConstraint.activate([
            verticalStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            verticalStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            verticalStack.topAnchor.constraint(equalTo: topAnchor),
            verticalStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 更新按钮态（工具高亮/撤销可用/下排选项行显隐与选中态）
    /// - Parameter optionsTool: 驱动下排选项行的工具（选中标注时为其对应工具，否则为当前工具）
    func updateState(
        activeTool: AnnotationTool,
        optionsTool: AnnotationTool,
        canUndo: Bool,
        canRedo: Bool,
        activeColor: NSColor,
        fontSize: CGFloat,
        lineWidth: CGFloat
    ) {
        self.activeTool = activeTool
        self.optionsTool = optionsTool
        self.activeColor = activeColor
        activeFontSize = fontSize
        activeLineWidth = lineWidth
        for (tool, button) in toolButtons {
            // 图标着色由 ToolButton.isActive 内部处理（激活=绿色，常态=初始 tint）
            button.isActive = tool == activeTool
            button.indicatorColor = Self.colorIndicatorTools.contains(tool) ? activeColor : nil
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        updateOptionsRow()
    }

    /// 钉住态：按钮保持选中高亮（绿色）且不可再点击（已钉住的截图无法再钉住）。
    /// 与 isEnabled 的"淡化禁用"不同：钉住态视觉上仍是选中，仅拦截交互
    func setPinned(_ pinned: Bool) {
        pinButton.isActive = pinned
        pinButton.isInteractionDisabled = pinned
    }

    /// 统一捕获：展示/隐藏「录制」出口按钮（工具栏首次布局前调用，不参与动态显隐动画）
    func setRecordingSupported(_ supported: Bool) {
        recordButton?.isHidden = !supported
        // 声源为「仅系统音频」时不需要麦克风选择；提示语跟随最近一次选择刷新
        microphoneButton?.isHidden = !supported || ScreenRecordingQuality.savedSource() == .systemAudio
        microphoneButton?.toolTip = Self.microphoneTooltip()
    }

    // MARK: - 麦克风快切

    /// 麦克风菜单：列出系统全部输入设备（含 Loopback 等虚拟设备，与系统「声音 → 输入」口径一致）
    /// 并勾选当前项；顶部另给「录音开始时静音麦克风」勾选项（与设置页共用同一偏好）。
    /// 选择写入与菜单栏「麦克风」、设置页共用的同一偏好，下次录音生效
    private func presentMicrophoneMenu() {
        guard let anchor = microphoneButton else { return }
        let selected = MicrophoneDeviceRegistry.savedSelectionUID()
        let menu = NSMenu()

        // 这里的「静音」只能是开始前的初始状态：录制一开始悬浮层即结束（finish(.recordRequested)），
        // 运行中的静音命令在此不可达，录音中改静音请用录音徽章菜单或菜单栏「麦克风」
        let startMutedItem = NSMenuItem(
            title: String(localized: "录音开始时静音麦克风"),
            action: #selector(toggleStartMuted(_:)),
            keyEquivalent: ""
        )
        startMutedItem.target = self
        startMutedItem.state = MicrophoneStartMutePreference.isEnabled() ? .on : .off
        menu.addItem(startMutedItem)
        menu.addItem(.separator())

        let followItem = NSMenuItem(
            title: String(localized: "跟随系统默认"),
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        followItem.target = self
        followItem.representedObject = ""
        followItem.state = selected == nil ? .on : .off
        menu.addItem(followItem)

        let devices = MicrophoneDeviceRegistry.availableDevices()
        if !devices.isEmpty { menu.addItem(.separator()) }
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == selected ? .on : .off
            menu.addItem(item)
        }

        // 已选设备已拔出：显式占位，避免勾选态凭空消失（实际采集会回退系统默认）
        if let selected, !devices.contains(where: { $0.uid == selected }) {
            menu.addItem(.separator())
            let missingItem = NSMenuItem(
                title: String(localized: "已断开，将回退系统默认"),
                action: nil,
                keyEquivalent: ""
            )
            missingItem.representedObject = selected
            missingItem.state = .on
            menu.addItem(missingItem)
        }

        // 工具栏位于选区下方：菜单以按钮顶部为锚点向上弹出，避免遮住选区
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        MicrophoneDeviceRegistry.saveSelectionUID(uid.isEmpty ? nil : uid)
        microphoneButton?.toolTip = Self.microphoneTooltip()
    }

    /// 切换「录音开始时静音麦克风」（与设置页「录音 → 输入设备」下同一份偏好，下次录制生效）
    @objc private func toggleStartMuted(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        MicrophoneStartMutePreference.set(enabled)
        sender.state = enabled ? .on : .off
        microphoneButton?.toolTip = Self.microphoneTooltip()
    }

    /// 按钮提示：显示当前麦克风（未指定或已拔出时为「跟随系统默认」），
    /// 以及本次录制是否会以静音开始
    private static func microphoneTooltip() -> String {
        let current = MicrophoneDeviceRegistry.selectedDeviceName() ?? String(localized: "跟随系统默认")
        var summary = String(format: String(localized: "麦克风：%@"), current)
        if MicrophoneStartMutePreference.isEnabled() {
            summary += " · " + String(localized: "录音时静音")
        }
        return summary
    }

    // MARK: - 私有构建

    /// 工具栏适配尺寸：宽度由上排工具行决定（加左右内边距），不随下排选项行显隐变化。
    /// 不能直接用 fittingSize：垂直栈 .leading 对齐 + 两行宽度不同时，
    /// fittingSize 宽度会丢掉右边距（内容+左边距），导致下排弹出后右侧边距为 0。
    func preferredToolbarSize() -> NSSize {
        needsLayout = true
        layoutSubtreeIfNeeded()
        return NSSize(
            width: mainStack.fittingSize.width + verticalStack.edgeInsets.left + verticalStack.edgeInsets.right,
            height: verticalStack.fittingSize.height
        )
    }

    private func makeToolButton(
        symbol: String,
        help: String,
        tint: NSColor? = nil,
        weight: NSFont.Weight = .regular,
        onClick: (() -> Void)? = nil
    ) -> ToolButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: weight)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        let image = base.withSymbolConfiguration(configuration) ?? base
        let button = ToolButton(
            image: image,
            tint: tint ?? NSColor(calibratedWhite: 0.28, alpha: 1),
            onClick: onClick
        )
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    /// 文字工具按钮（character.textbox：字符框，与预览 App 标记工具栏同款）
    private func makeTextToolButton(onClick: (() -> Void)? = nil) -> ToolButton {
        makeToolButton(symbol: "character.textbox", help: String(localized: "文字 (T)") + Self.optionsHint(for: .text), onClick: onClick)
    }

    private static func optionsHint(for tool: AnnotationTool) -> String {
        guard toolsWithOptions.contains(tool) else { return "" }
        if tool == .text { return String(localized: "（选中后下方可选字号/颜色）") }
        if tool == .mosaic { return String(localized: "（选中后下方可选颗粒度）") }
        return String(localized: "（选中后下方可选粗细/颜色）")
    }

    private func makeSeparator() -> NSView {
        // 高度约为按钮高度（36）的 60%，与上下两排条目协调
        SeparatorView()
    }

    // MARK: - 下排选项行（选中 矩形/椭圆/箭头/画笔/文字 时显示，其他工具隐藏）

    private func updateOptionsRow() {
        let show = Self.toolsWithOptions.contains(optionsTool)
        guard show else {
            if optionsRowInstalled {
                verticalStack.removeView(optionsStack)
                optionsRowInstalled = false
                onOptionsRowChanged?()
            }
            return
        }
        if optionsRowKind != optionsTool || !optionsRowInstalled {
            rebuildOptionsRow()
        } else {
            refreshOptionSelections()
        }
        if !optionsRowInstalled {
            verticalStack.addView(optionsStack, in: .leading)
            optionsRowInstalled = true
            onOptionsRowChanged?()
        }
    }

    private func rebuildOptionsRow() {
        optionsStack.views.forEach { optionsStack.removeView($0) }
        lineWidthChips.removeAll()
        fontSizeChips.removeAll()
        swatches.removeAll()

        var views: [NSView] = []
        if optionsTool == .text {
            // 文字：三档字号（A 递增）
            let labelFonts: [NSFont] = [
                .systemFont(ofSize: 13, weight: .medium),
                .systemFont(ofSize: 16, weight: .medium),
                .systemFont(ofSize: 20, weight: .medium),
            ]
            for (size, font) in zip(OverlayAnnotationView.fontSizeOptions, labelFonts) {
                let chip = MenuLabelChip(
                    title: "A",
                    font: font,
                    width: 36,
                    height: 36,
                    accessibilityLabel: String(localized: "字号 \(Int(size))")
                ) { [weak self] in
                    self?.onSelectFontSize?(size)
                }
                views.append(chip)
                fontSizeChips.append((size, chip))
            }
        } else {
            // 图形/马赛克：三档线条粗细或颗粒度（圆点递增；外框与上排按钮一致 36×36）
            let widthLabel = optionsTool == .mosaic
                ? String(localized: "马赛克颗粒度")
                : String(localized: "线条粗细")
            let tierLabels = [String(localized: "细"), String(localized: "中"), String(localized: "粗")]
            for (index, width) in OverlayAnnotationView.lineWidthOptions.enumerated() {
                let chip = MenuDotChip(
                    thickness: width,
                    width: 36,
                    height: 36,
                    accessibilityLabel: widthLabel + " " + tierLabels[index]
                ) { [weak self] in
                    self?.onSelectLineWidth?(width)
                }
                views.append(chip)
                lineWidthChips.append((width, chip))
            }
        }
        // 马赛克不用颜色，不显示色块行
        if Self.colorOptionTools.contains(optionsTool) {
            views.append(makeInlineSeparator())
            for (index, paletteColor) in Self.palette.enumerated() {
                let swatch = MenuColorSwatch(
                    color: paletteColor,
                    accessibilityLabel: String(localized: "颜色") + " " + Self.paletteColorNames[index]
                ) { [weak self] picked in
                    self?.onSelectColor?(picked)
                }
                views.append(swatch)
                swatches.append(swatch)
            }
        }
        for view in views {
            optionsStack.addView(view, in: .leading)
        }
        optionsRowKind = optionsTool
        refreshOptionSelections()
    }

    private func refreshOptionSelections() {
        if optionsTool == .text {
            for (size, chip) in fontSizeChips {
                chip.isSelected = abs(size - activeFontSize) < 0.1
            }
        } else {
            for (width, chip) in lineWidthChips {
                chip.isSelected = abs(width - activeLineWidth) < 0.1
            }
        }
        for swatch in swatches {
            swatch.isSelected = swatch.color.isAlmostEqual(activeColor)
        }
    }
}

// MARK: - 下排选项行组件

/// 选项行内竖向细分隔线
@MainActor
private func makeInlineSeparator() -> NSView {
    SeparatorView()
}

/// 竖向细分隔线（1×20）：纯 NSView 无固有尺寸会被栈视图压缩，需显式声明
final class SeparatorView: NSView {

    private let separatorSize = NSSize(width: 1, height: 20)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { separatorSize }
}

// MARK: - 统一悬停样式

/// 工具栏可点条目（上排工具按钮 + 下排选项条）共用的悬停外观：
/// 灰底铺满整个条目（36×36）、统一圆角，避免各类条目各自绘制导致大小不一
@MainActor
enum ToolbarItemStyle {
    /// 悬停灰底（6% 黑，叠在浅色工具栏上呈浅灰）
    static var hoverBackground: CGColor { NSColor.black.withAlphaComponent(0.06).cgColor }
    static var clearBackground: CGColor { NSColor.clear.cgColor }
    /// 与选项条选中底/工具按钮圆角一致
    static let cornerRadius: CGFloat = 8
}

/// 下排选项条悬停基类：提供与上排工具按钮完全一致的悬停灰底（铺满整条目）
class HoverableChipView: NSView {

    var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            refreshHoverBackground()
        }
    }

    /// 选中态与上排激活按钮一致：不叠加悬停灰底（选中外观由子类 draw 绘制）
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            refreshHoverBackground()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ToolbarItemStyle.cornerRadius
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// 子类可覆盖自定义底色逻辑
    func refreshHoverBackground() {
        layer?.backgroundColor = (isHovering && !isSelected)
            ? ToolbarItemStyle.hoverBackground
            : ToolbarItemStyle.clearBackground
    }
}

/// 选项行内文字选项条（字号 A 递增）
final class MenuLabelChip: HoverableChipView {

    let title: String
    private let font: NSFont
    private let onClick: () -> Void
    private let chipSize: NSSize

    init(title: String, font: NSFont, width: CGFloat, height: CGFloat, accessibilityLabel: String, onClick: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.onClick = onClick
        self.chipSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: chipSize))
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { chipSize }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            AnnotationToolbar.accent.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let str = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: isSelected ? AnnotationToolbar.accent : NSColor.labelColor,
            ]
        )
        let size = str.size()
        str.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        ))
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// 选项行内线条粗细圆点（直径随粗细递增，选中为绿色）
final class MenuDotChip: HoverableChipView {

    let thickness: CGFloat
    private let onClick: () -> Void
    private let chipSize: NSSize

    init(thickness: CGFloat, width: CGFloat, height: CGFloat, accessibilityLabel: String, onClick: @escaping () -> Void) {
        self.thickness = thickness
        self.onClick = onClick
        self.chipSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: chipSize))
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { chipSize }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(thickness * 3 + 5, bounds.width - 6)
        let dot = NSBezierPath(ovalIn: NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        ))
        (isSelected ? AnnotationToolbar.accent : NSColor(calibratedWhite: 0.55, alpha: 1)).setFill()
        dot.fill()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// 选项行内圆角色块（外框与上排按钮一致 36×36，选中带外圈描边）
final class MenuColorSwatch: HoverableChipView {

    let color: NSColor
    private let onPick: (NSColor) -> Void
    private let swatchFrame: NSSize

    init(color: NSColor, accessibilityLabel: String, onPick: @escaping (NSColor) -> Void) {
        self.color = color
        self.onPick = onPick
        self.swatchFrame = NSSize(width: 36, height: 36)
        super.init(frame: NSRect(origin: .zero, size: swatchFrame))
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { swatchFrame }

    override func draw(_ dirtyRect: NSRect) {
        // 对称内缩，色块在 36×36 条目内居中
        let square = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
        color.setFill()
        square.fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
        square.lineWidth = 1
        square.stroke()
        if isSelected {
            // 选中圈画在条目边界内（外扩会被栈视图裁剪）
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onPick(color) }
}

/// 颜色近似比较（跨色彩空间的等值判断）
extension NSColor {
    func isAlmostEqual(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return self == other
        }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }
}
#endif
