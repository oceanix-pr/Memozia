#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - 悬浮层视图（框选 + 标注画布）

/// 覆盖单个屏幕的标注视图：
/// - selecting 阶段：region 模式拖拽框选 / window 模式悬停高亮窗口
/// - annotating 阶段：显示工具栏，可移动/缩放选区、绘制标注、编辑文字
final class OverlayAnnotationView: NSView, NSTextFieldDelegate {

    /// 文字标注长度上限（规避 macOS 26 大文本同步布局挂死）
    static let maxTextLength = 500
    /// 文字标注默认字号
    static let defaultTextFontSize: CGFloat = 24
    /// 字号可选项（三档）
    static let fontSizeOptions: [CGFloat] = [14, 24, 36]
    /// 线条粗细可选项（三档）/ 默认值
    static let lineWidthOptions: [CGFloat] = [2, 4, 6]
    static let defaultLineWidth: CGFloat = 4
    /// 最小选区尺寸（小于此视为误触，重新框选）
    static let minSelectionSize: CGFloat = 8

    private static let logger = Logger(subsystem: "app.memozia", category: "ScreenshotOverlay")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityLabel(String(localized: "截图标注区域"))
        setAccessibilityRole(.unknown)
    }

    // MARK: 输入

    private var capture: RegionSelectionController.CaptureData?
    /// 会话宿主：接收保存/复制/取消/失败/钉住结果（全屏截图会话或钉住窗口会话）
    weak var controller: (any AnnotationSessionHost)?
    /// 钉住窗口模式：工具栏「钉住」按钮保持选中且不可再操作（已钉住的截图无法再钉住）
    private var isPinnedSession = false

    // MARK: 统一捕获会话（录制出口）

    /// 仅全屏捕获悬浮层会话开启（RegionSelectionController.begin 调用）：
    /// 工具栏展示「录制」按钮，以当前选区/拾取窗口/全屏为录屏目标。
    /// 重新标注/钉住编辑窗展示的是历史图片而非实时屏幕，不具备录制语义
    private var screenRecordingEnabled = false
    /// 录屏直达意图：选定目标后自动进入录制倒计时（菜单/工具栏「录选区/录窗口」）
    private var autoRecordOnSelection = false
    /// 录制倒计时层（strong：倒计时期间会话面板处于 suspend 态，靠它维持生命周期）
    private var recordCountdown: RecordCountdownController?
    /// 点击拾取窗口的 ID：点选即置位，此后一旦用户手动改动选区/改用全屏即失效
    /// （判据是这一事件，而非 `selection == 拾取时矩形` 的浮点相等）
    private var pickedWindowID: CGWindowID?

    // MARK: 状态机

    private enum Phase {
        case selecting
        case annotating
    }
    private var phase: Phase = .selecting

    // 选区与交互
    private(set) var selectionRect: NSRect?
    private var dragStartPoint: NSPoint?
    private var isDraggingNewSelection = false
    private var isResizingSelection = false
    private var resizeHandle: SelectionHandle?
    private var resizeStartRect: NSRect?
    private var isMovingSelection = false
    private var moveStartPoint: NSPoint?
    private var moveStartRect: NSRect?

    /// 窗口拾取（统一模式：悬停高亮 + 点击捕窗，拖拽则转为区域框选）
    private var hoveredWindowRect: NSRect?
    /// mouseDown 时记录的悬停窗口；拖动超出阈值前松开即捕获该窗口
    private var pendingWindowRect: NSRect?
    /// 悬停窗口在 capture.windowRects/windowIDs 中的下标（拾取时取对应窗口 ID）
    private var pendingWindowIndex: Int?
    /// 超过该拖动距离视为区域框选（否则视为点击 → 捕获悬停窗口）
    private static let windowSnapDragThreshold: CGFloat = 4

    // 实际捕获方式（决定入库的 captureMode 标签）
    private var capturedViaWindow = false
    private var capturedFullScreen = false

    /// 实际捕获模式：按用户现场操作（点窗/框选/全屏）而非入口模式记录
    private var actualCaptureMode: ScreenshotManager.CaptureMode {
        if capturedFullScreen { return .fullscreen }
        if capturedViaWindow { return .window }
        return .region
    }

    // 标注
    private(set) var annotations: [AnnotationShape] = []
    private var redoStack: [AnnotationShape] = []
    private var currentTool: AnnotationTool = .none
    private var currentColor: NSColor = .systemRed
    /// 文字标注当前字号 / 格式（新文字按此创建）
    private var currentFontSize: CGFloat = OverlayAnnotationView.defaultTextFontSize
    private var currentIsBold = false
    private var currentIsItalic = false
    /// 图形标注当前线条粗细（矩形/椭圆/箭头/画笔按此创建）
    private var currentLineWidth: CGFloat = OverlayAnnotationView.defaultLineWidth
    private var drawingShape: AnnotationShape?

    // 单个标注选择
    private var selectedAnnotationID: UUID?
    private var isMovingAnnotation = false
    private var moveAnnotationStartPoint: NSPoint?
    private var moveAnnotationOriginalPoints: [NSPoint]?
    /// 已完成标注的马赛克缓存（避免每帧重算）
    private var mosaicCache: [UUID: NSImage] = [:]

    // 文字输入
    private var activeTextField: NSTextField?

    // 工具栏
    private lazy var toolbar: AnnotationToolbar = makeToolbar()
    private var toolbarSize: NSSize = .zero

    // MARK: - 初始化

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func configure(
        capture: RegionSelectionController.CaptureData,
        controller: any AnnotationSessionHost
    ) {
        self.capture = capture
        self.controller = controller
        capturedViaWindow = false
        capturedFullScreen = false
        autoresizingMask = [.width, .height]
        updateCursor()
        needsDisplay = true
    }

    /// 钉住窗口模式：工具栏钉住按钮进入选中态并禁用交互（须在 preselectFullScreen 之前调用）
    func configureAsPinned() {
        isPinnedSession = true
    }

    /// 开放统一捕获的「录制」出口（仅全屏捕获悬浮层会话；须在首次 showToolbar 前调用）
    func enableScreenRecording() {
        screenRecordingEnabled = true
    }

    /// 录屏直达：下一次选定目标（框选/拾窗/空格全屏）后自动进入录制倒计时
    func armAutoRecordOnSelection() {
        autoRecordOnSelection = true
    }

    /// 全屏模式：预选整屏直接进入标注
    func preselectFullScreen() {
        // 全屏是程序改选区：清掉点窗拾取，避免「先点窗再空格全屏」时窗口目标压过全屏
        invalidateWindowPick()
        selectionRect = bounds
        capturedFullScreen = true
        phase = .annotating
        showToolbar()
        updateCursor()
        needsDisplay = true
        consumeAutoRecord()
    }

    /// 重新标注窗可手动调整大小：图片随视图拉伸填充，标注几何（点坐标/线宽/字号）
    /// 必须等比跟随，否则已有标注会与画面错位；选区铺满新尺寸，工具栏重排。
    /// 仅全屏/重新标注（capturedFullScreen）阶段生效——普通截图会话面板尺寸固定不会触发
    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = bounds.size
        let shouldScale = capturedFullScreen && phase == .annotating
            && oldSize.width > 0 && oldSize.height > 0
            && (abs(newSize.width - oldSize.width) > 0.5 || abs(newSize.height - oldSize.height) > 0.5)
        super.setFrameSize(newSize)
        guard shouldScale else { return }

        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height
        let uniform = (sx + sy) / 2

        // 缩放中正在编辑的文字先提交（字段位置基于旧坐标）
        commitActiveTextField()

        func scaleShape(_ shape: inout AnnotationShape) {
            shape.points = shape.points.map { NSPoint(x: $0.x * sx, y: $0.y * sy) }
            shape.lineWidth *= uniform
            shape.fontSize *= uniform
        }
        for index in annotations.indices {
            scaleShape(&annotations[index])
        }
        if drawingShape != nil {
            scaleShape(&drawingShape!)
        }
        // 马赛克缓存基于旧尺寸采样，缩放后作废重算
        mosaicCache.removeAll()

        selectionRect = NSRect(origin: .zero, size: newSize)
        layoutToolbar()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let capture else { return }

        // 1. 冻结图：非翻转视图的 cgContext 用户空间与视图坐标一致，
        //    CGImage 直接绘制即为正立（无需手动翻转；手动 translate+scale(-1) 反而会上下颠倒）
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(capture.frozenImage, in: bounds)
            ctx.restoreGState()
        }

        // 2. 遮罩：未选区时整屏轻遮罩；有选区/悬停窗口时遮罩选区外
        if coversScreen {
            // 全屏/近全屏（如最大化窗口）：选区外无遮罩空间，由内嵌边框 + 状态标签提供反馈
        } else if let selection = selectionRect {
            dimOutside(selection, alpha: 0.35)
        } else if let hovered = hoveredWindowRect {
            dimOutside(hovered, alpha: 0.25)
        } else {
            NSColor.black.withAlphaComponent(0.15).setFill()
            bounds.fill()
        }

        // 3. 标注（裁剪在选区内）
        if phase == .annotating, let selection = selectionRect {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            drawAnnotationShapes(annotations, isFinal: true)
            if let drawing = drawingShape {
                drawAnnotationShape(drawing, isFinal: false)
            }
            // 选中标注的高亮边框
            if let id = selectedAnnotationID,
               let shape = annotations.first(where: { $0.id == id }) {
                let bbox = boundingBox(of: shape).insetBy(dx: -4, dy: -4)
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
                let path = NSBezierPath(rect: bbox)
                path.lineWidth = 2
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.stroke()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // 4. 选区边框与手柄
        if let selection = selectionRect, phase == .annotating {
            if coversScreen {
                drawFullScreenBorder(selection)
                drawStatusBadge()
            } else {
                drawSelectionBorder(selection)
            }
        }

        // 5. 窗口悬停高亮（统一模式：未拖出区域框选时显示待选窗口）
        if phase == .selecting, selectionRect == nil, let hovered = hoveredWindowRect {
            let path = NSBezierPath(rect: hovered)
            path.lineWidth = 2
            NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()
            path.stroke()
        }

        // 6. 尺寸提示（拖拽框选/悬停窗口时）
        if phase == .selecting {
            if isDraggingNewSelection, let selection = selectionRect {
                drawSizeLabel(selection)
            } else if let hovered = hoveredWindowRect {
                drawSizeLabel(hovered)
            }
        }

        // 7. 操作提示（选择阶段底部居中）
        if phase == .selecting {
            drawSelectionHint()
        }
    }

    /// 选择阶段的操作提示条（统一模式：拖拽/点窗/空格全屏）
    private func drawSelectionHint() {
        drawFloatingHint(
            String(localized: "拖拽框选区域，点击截取窗口，按空格全屏"),
            at: NSPoint(x: bounds.midX, y: bounds.minY + 24)
        )
    }

    /// 全屏/近全屏捕获的顶部状态标签（给出明确的截图状态反馈）
    private func drawStatusBadge() {
        drawFloatingHint(
            String(localized: "回车保存 · Esc 取消"),
            at: NSPoint(x: bounds.midX, y: bounds.maxY - 44)
        )
    }

    /// 指定中心点绘制圆角黑底提示条
    private func drawFloatingHint(_ text: String, at center: NSPoint) {
        let str = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )
        let size = str.size()
        guard size.width > 0 else { return }
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let bg = NSRect(
            x: origin.x - 12,
            y: origin.y - 6,
            width: size.width + 24,
            height: size.height + 12
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        str.draw(at: origin)
    }

    /// 全屏/近全屏：选区外无边框空间，用内嵌粗边框保证可见
    private func drawFullScreenBorder(_ selection: NSRect) {
        let inset = min(3, selection.width / 4, selection.height / 4)
        let border = NSBezierPath(rect: selection.insetBy(dx: inset, dy: inset))
        border.lineWidth = 4
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.89, alpha: 1).setStroke()
        border.stroke()
    }

    /// 选区是否覆盖几乎整屏（全屏截图 / 最大化窗口）：
    /// 此时隔选区外遮罩与外扩边框均无可见区域，需要专门的状态反馈
    private var coversScreen: Bool {
        guard let selection = selectionRect, bounds.width > 0, bounds.height > 0 else { return false }
        return selection.width * selection.height >= bounds.width * bounds.height * 0.9
    }

    /// 遮罩选区外区域（even-odd 填充）
    private func dimOutside(_ rect: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(rect: bounds)
        path.appendRect(rect)
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawSelectionBorder(_ selection: NSRect) {
        let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.89, alpha: 1).setStroke()
        border.stroke()

        // 8 个调节手柄
        NSColor.white.setFill()
        NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.89, alpha: 1).setStroke()
        for handle in SelectionHandle.allCases {
            let rect = handle.rect(for: selection)
            let dot = NSBezierPath(ovalIn: rect)
            dot.fill()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawSizeLabel(_ rect: NSRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let str = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )
        let size = str.size()
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 8)
        if origin.y + size.height > bounds.maxY { origin.y = rect.minY - 8 - size.height }
        if origin.x < bounds.minX { origin.x = bounds.minX }
        let bg = NSRect(
            x: origin.x - 6,
            y: origin.y - 2,
            width: size.width + 12,
            height: size.height + 4
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: origin)
    }

    // MARK: - 标注绘制

    /// - Parameter offset: 绘制坐标平移（视图坐标 → 输出画布坐标），屏幕实时绘制时为 .zero
    private func drawAnnotationShapes(_ shapes: [AnnotationShape], isFinal: Bool, offset: NSPoint = .zero) {
        for shape in shapes {
            drawAnnotationShape(shape, isFinal: isFinal, offset: offset)
        }
    }

    private func drawAnnotationShape(_ shape: AnnotationShape, isFinal: Bool, offset: NSPoint = .zero) {
        switch shape.kind {
        case .rect:
            let path = NSBezierPath(rect: rectFromPoints(shape.points).offsetBy(dx: offset.x, dy: offset.y))
            path.lineWidth = shape.lineWidth
            shape.color.setStroke()
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: rectFromPoints(shape.points).offsetBy(dx: offset.x, dy: offset.y))
            path.lineWidth = shape.lineWidth
            shape.color.setStroke()
            path.stroke()

        case .arrow:
            guard shape.points.count >= 2 else { return }
            drawArrow(
                from: Self.shifted(shape.points[0], by: offset),
                to: Self.shifted(shape.points[1], by: offset),
                color: shape.color,
                lineWidth: shape.lineWidth
            )

        case .pen:
            guard shape.points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: Self.shifted(shape.points[0], by: offset))
            for point in shape.points.dropFirst() {
                path.line(to: Self.shifted(point, by: offset))
            }
            path.lineWidth = shape.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            shape.color.setStroke()
            path.stroke()

        case .text:
            guard let text = shape.text, !text.isEmpty, let origin = shape.points.first else { return }
            NSAttributedString(
                string: text,
                attributes: [
                    .font: shape.textFont,
                    .foregroundColor: shape.color,
                ]
            ).draw(at: Self.shifted(origin, by: offset))

        case .mosaic:
            drawMosaic(shape, isFinal: isFinal, offset: offset)
        }
    }

    private static func shifted(_ p: NSPoint, by offset: NSPoint) -> NSPoint {
        NSPoint(x: p.x + offset.x, y: p.y + offset.y)
    }

    private func drawArrow(from p0: NSPoint, to p1: NSPoint, color: NSColor, lineWidth: CGFloat) {
        let shaft = NSBezierPath()
        shaft.move(to: p0)
        shaft.line(to: p1)
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let headLength = max(14, lineWidth * 5)
        let spread: CGFloat = .pi / 7
        let a1 = NSPoint(
            x: p1.x - headLength * cos(angle - spread),
            y: p1.y - headLength * sin(angle - spread)
        )
        let a2 = NSPoint(
            x: p1.x - headLength * cos(angle + spread),
            y: p1.y - headLength * sin(angle + spread)
        )
        let head = NSBezierPath()
        head.move(to: a1)
        head.line(to: p1)
        head.line(to: a2)
        head.lineWidth = lineWidth
        head.lineCapStyle = .round
        head.lineJoinStyle = .miter
        color.setStroke()
        head.stroke()
    }

    /// 马赛克：裁剪冻结图对应区域 → 高质量缩小 → 最近邻放大
    /// - Parameter offset: 绘制坐标平移；裁剪始终按原始视图坐标计算（冻结图像素空间不变）
    private func drawMosaic(_ shape: AnnotationShape, isFinal: Bool, offset: NSPoint = .zero) {
        guard let capture else { return }
        let rect = rectFromPoints(shape.points).integral.intersection(bounds)
        guard rect.width > 2, rect.height > 2 else { return }

        let image: NSImage
        if let cached = mosaicCache[shape.id] {
            image = cached
        } else {
            let scale = CGFloat(capture.frozenImage.width) / bounds.width
            let pixelRect = CGRect(
                x: rect.minX * scale,
                y: (bounds.height - rect.maxY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
            guard pixelRect.width > 2, pixelRect.height > 2,
                  let crop = capture.frozenImage.cropping(to: pixelRect) else { return }
            image = Self.pixelate(crop: crop, toSize: rect.size, granularity: shape.lineWidth)
            if isFinal {
                // 缓存为全尺寸位图，无上限时多个大面积马赛克会叠加数十 MB 内存；
                // 超限整体清空（按需重算，马赛克生成本身开销很低）
                if mosaicCache.count >= 12 {
                    mosaicCache.removeAll()
                }
                mosaicCache[shape.id] = image
            }
        }
        // 放大绘制强制邻近插值：等价于旧版“先栅格化成全尺寸位图再贴”，
        // 但拖拽中（isFinal=false、不进缓存）每个鼠标事件不再分配两块选区尺寸位图
        let context = NSGraphicsContext.current
        let previousInterpolation = context?.imageInterpolation
        context?.imageInterpolation = .none
        image.draw(in: rect.offsetBy(dx: offset.x, dy: offset.y))
        // setter 只接受非可选值：previousInterpolation 来自可选链，仅当 context 存在时才有值
        // （无 context 时上面那次 draw 本身也是 no-op，无需恢复）
        if let context, let previousInterpolation {
            context.imageInterpolation = previousInterpolation
        }
    }

    /// - Parameter granularity: 颗粒度档位（复用 lineWidth 三档 2/4/6 → 细/中/粗）
    ///
    /// 只生成降采样小图（放大交给绘制时的邻近插值）：旧实现额外栅格化一张与选区
    /// 同尺寸的位图，而拖拽中的马赛克不进缓存 → 每帧都要重做两次全屏尺寸分配。
    private static func pixelate(crop: CGImage, toSize size: NSSize, granularity: CGFloat) -> NSImage {
        let factor: CGFloat = granularity <= 2 ? 4.0 : (granularity <= 4 ? 10.0 : 18.0)
        let smallW = max(2, Int(size.width / factor))
        let smallH = max(2, Int(size.height / factor))

        guard let smallRep = makeRep(width: smallW, height: smallH),
              let smallContext = NSGraphicsContext(bitmapImageRep: smallRep) else {
            return NSImage(cgImage: crop, size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = smallContext
        smallContext.imageInterpolation = .high
        NSImage(cgImage: crop, size: NSSize(width: smallW, height: smallH))
            .draw(in: NSRect(x: 0, y: 0, width: smallW, height: smallH))
        NSGraphicsContext.restoreGraphicsState()

        guard let smallCG = smallRep.cgImage else {
            return NSImage(cgImage: crop, size: size)
        }
        return NSImage(cgImage: smallCG, size: size)
    }

    private static func makeRep(width: Int, height: Int) -> NSBitmapImageRep? {
        guard width > 0, height > 0 else { return nil }
        return NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private func rectFromPoints(_ points: [NSPoint]) -> NSRect {
        guard let p0 = points.first, let p1 = points.last else { return .zero }
        return NSRect(
            x: min(p0.x, p1.x),
            y: min(p0.y, p1.y),
            width: abs(p0.x - p1.x),
            height: abs(p0.y - p1.y)
        )
    }

    // MARK: - 鼠标交互

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        guard phase == .annotating else {
            beginSelection(at: point)
            return
        }
        guard let selection = selectionRect else { return }

        // 命中调节手柄 → 缩放选区
        if let handle = hitHandle(at: point, in: selection) {
            isResizingSelection = true
            resizeHandle = handle
            resizeStartRect = selection
            return
        }

        // 选择工具：点击标注 → 选中并准备拖动；双击文字标注 → 重新编辑
        if currentTool == .select {
            // 双击文字标注 → 进入编辑模式
            if event.clickCount >= 2, let shape = hitTestAnnotation(at: point),
               shape.kind == .text {
                beginEditingExistingText(shape, fallback: point)
                return
            }
            if let shape = hitTestAnnotation(at: point) {
                selectedAnnotationID = shape.id
                isMovingAnnotation = true
                moveAnnotationStartPoint = point
                moveAnnotationOriginalPoints = shape.points
                updateToolbarState()
                needsDisplay = true
            } else {
                selectedAnnotationID = nil
                updateToolbarState()
                needsDisplay = true
            }
            return
        }

        // 默认工具 + 选区内点击 → 移动选区
        if currentTool == .none, selection.contains(point) {
            isMovingSelection = true
            moveStartPoint = point
            moveStartRect = selection
            return
        }
        // 标注工具 → 开始绘制
        switch currentTool {
        case .select:
            break
        case .none:
            // 默认工具 + 选区外点击 → 重新框选（清空标注）
            resetToSelecting()
            beginSelection(at: point)
        case .rect, .ellipse, .arrow, .mosaic:
            drawingShape = AnnotationShape(
                kind: toolKind(for: currentTool),
                color: currentColor,
                lineWidth: currentLineWidth,
                points: [point, point]
            )
        case .pen:
            drawingShape = AnnotationShape(kind: .pen, color: currentColor, lineWidth: currentLineWidth, points: [point])
        case .text:
            // 点击已有文字标注 → 直接拖动（双击 → 重新编辑），避免每次点击都新建输入框
            if let shape = hitTestAnnotation(at: point), shape.kind == .text {
                if event.clickCount >= 2 {
                    beginEditingExistingText(shape, fallback: point)
                    return
                }
                selectedAnnotationID = shape.id
                isMovingAnnotation = true
                moveAnnotationStartPoint = point
                moveAnnotationOriginalPoints = shape.points
                updateToolbarState()
                needsDisplay = true
                return
            }
            beginTextEditing(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDraggingNewSelection, let start = dragStartPoint {
            let beyondThreshold =
                abs(point.x - start.x) > Self.windowSnapDragThreshold
                || abs(point.y - start.y) > Self.windowSnapDragThreshold
            if beyondThreshold {
                // 拖出阈值 → 转为区域框选，放弃点击捕窗
                pendingWindowRect = nil
            }
            if pendingWindowRect == nil {
                selectionRect = normalizedRect(from: start, to: point)
            }
            needsDisplay = true
            return
        }
        if isResizingSelection, let handle = resizeHandle, let startRect = resizeStartRect {
            invalidateWindowPick()
            selectionRect = clamped(handle.resizingRect(of: startRect, to: point))
            layoutToolbar()
            needsDisplay = true
            return
        }
        if isMovingSelection, let start = moveStartPoint, let startRect = moveStartRect {
            invalidateWindowPick()
            let dx = point.x - start.x
            let dy = point.y - start.y
            selectionRect = clamped(startRect.offsetBy(dx: dx, dy: dy))
            layoutToolbar()
            needsDisplay = true
            return
        }
        // 选择工具拖动 → 移动选中的标注
        if isMovingAnnotation, let start = moveAnnotationStartPoint,
           let originalPoints = moveAnnotationOriginalPoints,
           let id = selectedAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            let dx = point.x - start.x
            let dy = point.y - start.y
            let before = boundingBox(of: annotations[index])
            annotations[index].points = originalPoints.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
            if annotations[index].kind == .mosaic {
                mosaicCache.removeValue(forKey: id)
            }
            // 只重绘受影响区域（标注阶段遮罩静态，无需整视图失效）
            invalidateRegion(before.union(boundingBox(of: annotations[index])))
            return
        }
        if var shape = drawingShape {
            let before = boundingBox(of: shape)
            switch shape.kind {
            case .pen:
                shape.points.append(point)
            default:
                if !shape.points.isEmpty {
                    shape.points[shape.points.count - 1] = point
                }
            }
            drawingShape = shape
            // 画笔/拖拽工具是连续高频路径：整视图失效会在 5K 屏上每帧重新合成整屏
            invalidateRegion(before.union(boundingBox(of: shape)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingNewSelection {
            isDraggingNewSelection = false
            // 未拖出阈值即松开 → 点击捕获悬停窗口
            if let windowRect = pendingWindowRect {
                pendingWindowRect = nil
                capturedViaWindow = true
                if let index = pendingWindowIndex, let ids = capture?.windowIDs, ids.indices.contains(index) {
                    pickedWindowID = ids[index]
                } else {
                    pickedWindowID = nil
                }
                pendingWindowIndex = nil
                let clampedRect = clamped(windowRect)
                selectionRect = clampedRect
                enterAnnotating()
                needsDisplay = true
                return
            }
            pendingWindowIndex = nil
            if let selection = selectionRect,
               selection.width >= Self.minSelectionSize, selection.height >= Self.minSelectionSize {
                enterAnnotating()
            } else {
                selectionRect = nil
            }
            needsDisplay = true
            return
        }
        if isResizingSelection {
            isResizingSelection = false
            resizeHandle = nil
            resizeStartRect = nil
            return
        }
        if isMovingSelection {
            isMovingSelection = false
            moveStartPoint = nil
            moveStartRect = nil
            return
        }
        if isMovingAnnotation {
            isMovingAnnotation = false
            moveAnnotationStartPoint = nil
            moveAnnotationOriginalPoints = nil
            return
        }
        if var shape = drawingShape {
            let valid: Bool
            switch shape.kind {
            case .pen:
                valid = shape.points.count >= 2
            case .text:
                valid = false
            default:
                let rect = rectFromPoints(shape.points)
                valid = rect.width >= 3 || rect.height >= 3
            }
            drawingShape = nil
            if valid {
                shape.points = finalizePoints(shape)
                annotations.append(shape)
                redoStack.removeAll()
                updateToolbarState()
            }
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if phase == .selecting, !isDraggingNewSelection {
            let hovered = capture?.windowRects.first { $0.contains(point) }
            if hovered != hoveredWindowRect {
                hoveredWindowRect = hovered
                needsDisplay = true
            }
        }
        updateCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let field = activeTextField {
            activeTextField = nil
            field.superview?.removeFromSuperview()
            window?.makeFirstResponder(self)
        } else {
            controller?.finish(.cancelled)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Delete/Backspace：删除选中的标注
        if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)),
           selectedAnnotationID != nil {
            deleteSelectedAnnotation()
            return
        }

        // Cmd+Shift+Z → 重做
        if event.keyCode == UInt16(kVK_ANSI_Z),
           event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift) {
            redo()
            return
        }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            // 文字编辑中：ESC 先丢弃文字框，再次 ESC 才取消会话
            if activeTextField != nil {
                discardActiveTextField()
            } else {
                controller?.finish(.cancelled)
            }
        case UInt16(kVK_Space) where phase == .selecting:
            // 空格：截图现场切换为全屏捕获
            preselectFullScreen()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            confirmSelection(copyOnly: false)
        case UInt16(kVK_ANSI_Z) where event.modifierFlags.contains(.command):
            undo()
        // 工具快捷键（无修饰键，标注阶段生效）
        case UInt16(kVK_ANSI_V) where phase == .annotating:
            selectTool(.none)
        case UInt16(kVK_ANSI_R) where phase == .annotating:
            selectTool(.rect)
        case UInt16(kVK_ANSI_O) where phase == .annotating:
            selectTool(.ellipse)
        case UInt16(kVK_ANSI_A) where phase == .annotating:
            selectTool(.arrow)
        case UInt16(kVK_ANSI_P) where phase == .annotating:
            selectTool(.pen)
        case UInt16(kVK_ANSI_M) where phase == .annotating:
            selectTool(.mosaic)
        case UInt16(kVK_ANSI_T) where phase == .annotating:
            selectTool(.text)
        case UInt16(kVK_ANSI_S) where phase == .annotating:
            selectTool(.select)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 键盘与工具操作

    private func beginSelection(at point: NSPoint) {
        // 统一模式：按下记录悬停窗口（松开未拖动 → 捕窗；拖出阈值 → 区域框选）
        // 主动计算而非读 hover 缓存：面板刚显示时 mouseMoved 可能尚未触发
        dragStartPoint = point
        isDraggingNewSelection = true
        pendingWindowIndex = capture?.windowRects.firstIndex { $0.contains(point) }
        pendingWindowRect = pendingWindowIndex.flatMap { index in capture?.windowRects[index] }
        selectionRect = nil
        needsDisplay = true
    }

    private func enterAnnotating() {
        phase = .annotating
        hoveredWindowRect = nil
        pendingWindowRect = nil
        showToolbar()
        updateCursor()
        consumeAutoRecord()
    }

    /// 录屏直达意图消费：选定目标后自动进入录制倒计时（意图一次性，取消后回到普通会话）
    private func consumeAutoRecord() {
        guard autoRecordOnSelection else { return }
        autoRecordOnSelection = false
        startRecordingFromSelection()
    }

    /// 用户手动改动选区（缩放/移动）或改用全屏后，点窗拾取的独立窗口目标不再成立，显式失效。
    /// 判据是「点选后是否改过选区」这一事件，避免用 `selection == 拾取时矩形` 的浮点相等去猜——
    /// ±1pt 的钳制差异会被误判成「改过」，静默降级为区域录制（会录到窗口后面的画面）
    private func invalidateWindowPick() {
        capturedViaWindow = false
        pickedWindowID = nil
    }

    private func resetToSelecting() {
        phase = .selecting
        selectionRect = nil
        capturedViaWindow = false
        capturedFullScreen = false
        pendingWindowRect = nil
        pickedWindowID = nil
        annotations.removeAll()
        redoStack.removeAll()
        mosaicCache.removeAll()
        hideToolbar()
        updateCursor()
        needsDisplay = true
    }

    func selectTool(_ tool: AnnotationTool) {
        commitActiveTextField()
        currentTool = tool
        selectedAnnotationID = nil
        updateCursor()
        updateToolbarState()
        needsDisplay = true
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        mosaicCache.removeValue(forKey: last.id)
        redoStack.append(last)
        selectedAnnotationID = nil
        updateToolbarState()
        needsDisplay = true
    }

    func redo() {
        guard let shape = redoStack.popLast() else { return }
        mosaicCache.removeValue(forKey: shape.id)
        annotations.append(shape)
        selectedAnnotationID = nil
        updateToolbarState()
        needsDisplay = true
    }

    // MARK: - 单个标注选择

    /// 点击命中测试：返回最上层的标注（后绘制的优先）
    private func hitTestAnnotation(at point: NSPoint) -> AnnotationShape? {
        for shape in annotations.reversed() {
            if boundingBox(of: shape).insetBy(dx: -6, dy: -6).contains(point) {
                return shape
            }
        }
        return nil
    }

    /// 计算标注的包围盒
    private func boundingBox(of shape: AnnotationShape) -> NSRect {
        switch shape.kind {
        case .rect, .ellipse, .arrow, .mosaic:
            guard shape.points.count >= 2 else { return .zero }
            let p1 = shape.points[0]
            let p2 = shape.points[1]
            let x = min(p1.x, p2.x)
            let y = min(p1.y, p2.y)
            let w = abs(p2.x - p1.x)
            let h = abs(p2.y - p1.y)
            return NSRect(x: x, y: y, width: w, height: h)
        case .pen:
            guard !shape.points.isEmpty else { return .zero }
            let xs = shape.points.map(\.x)
            let ys = shape.points.map(\.y)
            let xMin = xs.min()!, xMax = xs.max()!
            let yMin = ys.min()!, yMax = ys.max()!
            return NSRect(x: xMin, y: yMin, width: xMax - xMin, height: yMax - yMin)
        case .text:
            guard let point = shape.points.first, let text = shape.text else { return .zero }
            let font = shape.textFont
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let size = (text as NSString).size(withAttributes: attrs)
            // 文字以 point 为左下角向上绘制（非翻转坐标 draw(at:)），包围盒须与绘制区域一致才能命中拖动
            return NSRect(x: point.x, y: point.y, width: size.width, height: size.height)
        }
    }

    /// 只失效受影响区域：标注阶段遮罩与选区边框都是静态的，无需整视图重绘。
    /// 旧写法 `needsDisplay = true` 会在每个鼠标事件里重新合成整屏（5K 屏一次约 15MP），
    /// 画笔/拖拽标注时明显掉帧；包围盒不可用时回退整视图，保证不会漏绘
    private func invalidateRegion(_ rect: NSRect) {
        let expanded = rect.insetBy(dx: -8, dy: -8)
        guard expanded.width > 0, expanded.height > 0 else {
            needsDisplay = true
            return
        }
        setNeedsDisplay(expanded)
    }

    /// 删除选中的标注
    private func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = annotations.remove(at: index)
        mosaicCache.removeValue(forKey: removed.id)
        redoStack.append(removed)
        selectedAnnotationID = nil
        updateToolbarState()
        needsDisplay = true
    }

    // MARK: - 录制出口（统一捕获会话）

    /// 以当前选区/拾取窗口/全屏为录屏目标：先揭开会话面板，再走 3 秒录制倒计时；
    /// 倒计时完成 → finish(.recordRequested) 由上层复用现有录屏链路启动；
    /// 倒计时取消 → 恢复面板回到标注会话，选区与标注原样保留
    func startRecordingFromSelection() {
        commitActiveTextField()
        guard screenRecordingEnabled,
              recordCountdown == nil,
              let selection = selectionRect,
              let capture,
              let target = makeRecordTarget(from: selection, capture: capture) else { return }

        let quality = ScreenRecordingQuality.saved()
        let source = ScreenRecordingQuality.savedSource()
        var summary = String(
            format: String(localized: "质量：%@（%@）"), quality.displayName, quality.estimatedSizeLabel
        ) + " · " + String(format: String(localized: "声源：%@"), source.displayName)
        // 声源含麦克风时把当前选择一并写明：倒计时是录前最后一个确认点；
        // 以静音开始时也要写明，避免倒计时确认的与录出来的不一致
        if source != .systemAudio {
            let microphone = MicrophoneDeviceRegistry.selectedDeviceName()
                ?? String(localized: "跟随系统默认")
            summary += " · " + String(format: String(localized: "麦克风：%@"), microphone)
            if MicrophoneStartMutePreference.isEnabled() {
                summary += " · " + String(localized: "录音时静音")
            }
        }

        let countdown = RecordCountdownController(
            screen: capture.screen,
            regionInViewCoords: selection,
            settingsSummary: summary
        )
        countdown.onComplete = { [weak self] in
            guard let self else { return }
            self.recordCountdown = nil
            self.controller?.finish(.recordRequested(target: target))
        }
        countdown.onCancel = { [weak self] in
            guard let self else { return }
            self.recordCountdown = nil
            // 回到标注会话原地继续（与保存面板取消同一恢复路径）
            self.controller?.resumeHostWindowsAfterSystemPanel()
            self.updateCursor()
        }
        recordCountdown = countdown
        // 揭开冻结屏会话面板：倒计时层下是实时屏幕（录制内容即用户将看到的画面）
        controller?.suspendHostWindowsForSystemPanel()
        countdown.start()
    }

    /// 选区 → 录屏目标换算（视图坐标左下原点 → 显示屏内左上原点 points）：
    /// - 点击拾取窗口且此后未手动改动选区 → 独立窗口录制（移动/遮挡仍完整采集，优于区域录制）
    /// - 覆盖整屏（≥ 98%）→ 该屏全屏录制
    /// - 其余 → 该屏内区域录制
    private func makeRecordTarget(
        from selection: NSRect,
        capture: RegionSelectionController.CaptureData
    ) -> ScreenRecordingTarget? {
        guard let displayID = capture.screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else { return nil }

        // 判据用事件标志 capturedViaWindow（点选即置位，缩放/移动/全屏即失效），
        // 不再比较 `selection == 拾取时矩形`：浮点相等会把 ±1pt 的钳制差异误判成「改过」
        if capturedViaWindow, let windowID = pickedWindowID {
            return .window(id: windowID)
        }

        if selection == bounds
            || selection.width * selection.height >= bounds.width * bounds.height * 0.98 {
            return .display(id: displayID, regionInDisplayPoints: nil)
        }
        let topLeftRect = CGRect(
            x: selection.minX,
            y: bounds.height - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        guard topLeftRect.width >= 20, topLeftRect.height >= 20 else { return nil }
        return .display(id: displayID, regionInDisplayPoints: topLeftRect)
    }

    // MARK: - 确认/取消/复制/钉住

    /// 钉住当前截图：把选区内容（含已绘标注）栅格化为单张 PNG，
    /// 结束会话由上层开启置顶钉住窗口
    func pinSelection() {
        commitActiveTextField()
        guard let selection = selectionRect else { return }
        produceSelectionPNG(selection) { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.controller?.finish(.failed(String(localized: "生成截图失败，请重试")))
                return
            }
            self.controller?.finish(.pinned(png: data))
        }
    }

    /// OCR识别并钉住：把选区（含已绘标注）栅格化 PNG 交上层开启置顶钉住窗口，
    /// 并在钉住窗口右侧附一个可编辑、可复制的识别文字面板。
    /// 与「钉住」的唯一差别就是这块文字面板——单纯钉住时右侧没有文字
    func ocrAndPin() {
        commitActiveTextField()
        guard let selection = selectionRect else { return }
        produceSelectionPNG(selection) { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.controller?.finish(.failed(String(localized: "生成截图失败，请重试")))
                return
            }
            self.controller?.finish(.pinnedWithOCR(png: data))
        }
    }

    /// 保存为文件：弹系统保存面板让用户选择保存位置与文件名（默认名
    /// 「截图_年月日_时分秒.png」，默认定位到上次保存目录，无则桌面）。
    /// 悬浮层层级高于系统面板，弹面板期间须暂时揭开宿主遮罩；用户取消面板时
    /// 会话原地保留（已绘标注不丢），只有写盘成功才结束会话
    func saveToFile() {
        commitActiveTextField()
        guard let selection = selectionRect else { return }

        // 先栅格化 + 后台编码，拿到 PNG 后再弹保存面板（大图编码不再阻塞主线程）
        produceSelectionPNG(selection) { [weak self] data in
            guard let self else { return }
            guard let png = data else {
                self.controller?.finish(.failed(String(localized: "生成截图失败，请重试")))
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = Self.suggestedSaveFileName()
            panel.directoryURL = Self.defaultSaveDirectory()
            panel.canCreateDirectories = true
            panel.message = String(localized: "选择截图保存位置")

            // 弹面板前揭开 .screenSaver 层级的悬浮层，结束后恢复（App 为 accessory 态，
            // 不能 activate：applicationDidBecomeActive 会把主窗口弹出来）
            self.controller?.suspendHostWindowsForSystemPanel()
            let response = panel.runModal()
            self.controller?.resumeHostWindowsAfterSystemPanel()

            // 用户取消保存窗：不结束会话，回到标注态继续编辑
            guard response == .OK, let target = panel.url else { return }

            do {
                try png.write(to: target, options: .atomic)
                Self.rememberSaveDirectory(target.deletingLastPathComponent())
                Self.logger.info("截图已保存：\(target.path)")
                self.controller?.finish(.savedToDisk(path: target.path))
            } catch {
                Self.logger.error("保存截图失败：\(error.localizedDescription)")
                self.controller?.finish(.failed(
                    String(format: String(localized: "保存截图文件失败：%@"), error.localizedDescription)
                ))
            }
        }
    }

    // MARK: - 保存面板默认值

    /// 上次保存目录的偏好键（工程未启用 App Sandbox，直接存路径即可）
    private static let lastSaveDirectoryKey = "screenshot_last_save_directory"

    /// 建议文件名：截图_年月日_时分秒.png
    private static func suggestedSaveFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return "截图_\(formatter.string(from: Date())).png"
    }

    /// 保存面板默认定位目录：上次选择的目录 → 桌面 → 文稿 → 用户目录
    private static func defaultSaveDirectory() -> URL {
        if let last = UserDefaults.standard.string(forKey: lastSaveDirectoryKey),
           FileManager.default.fileExists(atPath: last) {
            return URL(fileURLWithPath: last, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func rememberSaveDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastSaveDirectoryKey)
    }

    func confirmSelection(copyOnly: Bool) {
        commitActiveTextField()
        guard let selection = selectionRect else { return }

        // 主线程只做栅格化（AppKit 需主线程），PNG 编码移到后台
        guard let originalCG = renderOriginalCGImage(selection) else {
            controller?.finish(.failed(String(localized: "生成截图失败，请重试")))
            return
        }
        let markedCG: CGImage? = annotations.isEmpty ? nil : renderMarkedCGImage(selection)
        let scale = pixelScale()
        let pixelWidth = Int(selection.width * scale)
        let pixelHeight = Int(selection.height * scale)
        let captureModeRaw = actualCaptureMode.rawValue
        let originalBox = ImageEncodeBox(originalCG)
        let markedBox = markedCG.map(ImageEncodeBox.init)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let originalPNG = await Self.encodePNGOffMain(originalBox) else {
                self.controller?.finish(.failed(String(localized: "生成截图失败，请重试")))
                return
            }
            var markedPNG: Data?
            if let markedBox {
                markedPNG = await Self.encodePNGOffMain(markedBox)
            }

            if copyOnly {
                let final = markedPNG ?? originalPNG
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(final, forType: .png)
                self.controller?.finish(.copied)
                return
            }

            self.controller?.finish(.saved(
                originalPNG: originalPNG,
                markedPNG: markedPNG,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                captureMode: captureModeRaw
            ))
        }
    }

    /// 原图（无标注）：裁剪冻结图为 CGImage（AppKit 不参与，主线程开销极低）
    private func renderOriginalCGImage(_ selection: NSRect) -> CGImage? {
        guard let capture else { return nil }
        let scale = pixelScale()
        let pixelRect = CGRect(
            x: selection.minX * scale,
            y: (bounds.height - selection.maxY) * scale,
            width: selection.width * scale,
            height: selection.height * scale
        ).integral
        let clamped = pixelRect.intersection(
            CGRect(x: 0, y: 0, width: capture.frozenImage.width, height: capture.frozenImage.height)
        )
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let crop = capture.frozenImage.cropping(to: clamped) else { return nil }
        return crop
    }

    /// 标注版：冻结图 + 标注栅格化为 CGImage（编码由调用方在后台完成）
    /// 全程走 AppKit 管线（NSImage/drawAnnotationShapes）：
    /// - rep 像素尺寸 = 选区 × backingScale，rep.size 设为选区点尺寸 → 上下文按视图点坐标绘制并自动按 DPI 栅格化
    /// - 坐标平移以绘制参数传递（不走 cgContext CTM，raw CTM 与 AppKit API 不互通）
    private func renderMarkedCGImage(_ selection: NSRect) -> CGImage? {
        guard let capture else { return nil }
        let scale = pixelScale()
        let pixelWidth = max(1, Int(selection.width * scale))
        let pixelHeight = max(1, Int(selection.height * scale))
        guard let rep = Self.makeRep(width: pixelWidth, height: pixelHeight) else { return nil }
        // 先设点尺寸再建上下文（上下文创建时按 rep.size 建立点→像素映射）
        rep.size = NSSize(width: selection.width, height: selection.height)
        guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        nsContext.imageInterpolation = .none

        // 冻结图：全屏点尺寸的 NSImage 平移绘制，选区左下角对齐输出原点；
        // NSImage 走 AppKit 管线天然正立且随 DPI 满分辨率栅格化
        NSImage(cgImage: capture.frozenImage, size: bounds.size)
            .draw(in: NSRect(
                x: -selection.minX,
                y: -selection.minY,
                width: bounds.width,
                height: bounds.height
            ))

        // 标注：视图坐标 → 输出画布坐标（平移到选区原点）
        drawAnnotationShapes(
            annotations,
            isFinal: true,
            offset: NSPoint(x: -selection.minX, y: -selection.minY)
        )

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: - PNG 编码（后台执行）

    /// PNG 编码（ImageIO，线程安全）。从主线程移出：大选区（5K 全屏 ~15MP）
    /// 在旧实现里同步编码会阻塞主线程数十~数百毫秒，表现为确认/复制截图时界面卡住。
    /// nonisolated：只用到 ImageIO 与不可变 CGImage，不触碰任何主线程状态
    nonisolated private static func encodePNG(_ box: ImageEncodeBox) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, box.image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    nonisolated private static func encodePNGOffMain(_ box: ImageEncodeBox) async -> Data? {
        await Task.detached(priority: .userInitiated) { Self.encodePNG(box) }.value
    }

    /// 主线程栅格化选区（含标注）→ 后台编码 PNG → 主线程回调。
    /// 无标注时走裁剪快路径，有标注时走 AppKit 栅格化（必须主线程）
    private func produceSelectionPNG(
        _ selection: NSRect,
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        let image: CGImage? = annotations.isEmpty
            ? renderOriginalCGImage(selection)
            : (renderMarkedCGImage(selection) ?? renderOriginalCGImage(selection))
        guard let image else {
            Task { @MainActor in completion(nil) }
            return
        }
        let box = ImageEncodeBox(image)
        Task { @MainActor in
            completion(await Self.encodePNGOffMain(box))
        }
    }

    private func pixelScale() -> CGFloat {
        guard let capture, bounds.width > 0 else { return 1 }
        return CGFloat(capture.frozenImage.width) / bounds.width
    }

    /// 标注提交时收敛点：几何类保留两点即可
    private func finalizePoints(_ shape: AnnotationShape) -> [NSPoint] {
        switch shape.kind {
        case .pen:
            return shape.points
        default:
            guard let first = shape.points.first, let last = shape.points.last else {
                return shape.points
            }
            return [first, last]
        }
    }

    // MARK: - 文字标注

    /// 双击已有文字标注 → 删除旧标注，按其属性重新进入编辑
    private func beginEditingExistingText(_ shape: AnnotationShape, fallback point: NSPoint) {
        selectedAnnotationID = nil
        if let index = annotations.firstIndex(where: { $0.id == shape.id }) {
            annotations.remove(at: index)
            mosaicCache.removeValue(forKey: shape.id)
            redoStack.append(shape)
        }
        currentFontSize = shape.fontSize
        currentIsBold = shape.isBold
        currentIsItalic = shape.isItalic
        currentColor = shape.color
        beginTextEditing(at: shape.points.first ?? point)
    }

    private func beginTextEditing(at point: NSPoint) {
        commitActiveTextField()
        let height = currentFontSize + 16
        let host = TextEditorHostView(
            frame: NSRect(x: point.x, y: point.y - currentFontSize - 5, width: 240, height: height),
            placeholder: String(localized: "输入文字"),
            font: textFont(ofSize: currentFontSize, bold: currentIsBold, italic: currentIsItalic),
            textColor: currentColor
        )
        host.textField.delegate = self
        addSubview(host)
        activeTextField = host.textField
        window?.makeFirstResponder(host.textField)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextField()
    }

    func controlTextDidChange(_ obj: Notification) {
        // 限长：避免 macOS 26 大文本同步布局挂死
        guard let field = obj.object as? NSTextField else { return }
        if field.stringValue.count > Self.maxTextLength {
            field.stringValue = String(field.stringValue.prefix(Self.maxTextLength))
        }
        (field.superview as? TextEditorHostView)?.setPlaceholderHidden(!field.stringValue.isEmpty)
    }

    /// field editor 按键命令拦截：ESC（cancel:）只丢弃文字框，不取消整个截图会话
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardActiveTextField()
            return true
        }
        return false
    }

    private func commitActiveTextField() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldFrame = field.superview?.convert(field.frame, to: self) ?? field.frame
        // 以输入框垂直中心对齐提交文字（draw(at:) 以左下角为原点向上绘制），避免提交后文字位置上跳
        let commitFont = field.font ?? textFont(ofSize: currentFontSize, bold: currentIsBold, italic: currentIsItalic)
        let textHeight = (text as NSString).size(withAttributes: [.font: commitFont]).height
        let origin = NSPoint(x: fieldFrame.minX, y: fieldFrame.midY - textHeight / 2)
        field.superview?.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else {
            // 空文本视为取消，不创建标注
            return
        }
        annotations.append(AnnotationShape(
            kind: .text,
            color: currentColor,
            points: [origin],
            text: text,
            fontSize: currentFontSize,
            isBold: currentIsBold,
            isItalic: currentIsItalic
        ))
        redoStack.removeAll()
        updateToolbarState()
        needsDisplay = true
    }

    /// 当前文字格式对应的输入/渲染字体
    private func textFont(ofSize size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// ESC 丢弃文字框：不创建标注，直接移除输入框
    private func discardActiveTextField() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        field.superview?.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    /// 当前选中标注在 annotations 中的索引
    private var selectedShapeIndex: Int? {
        guard let id = selectedAnnotationID else { return nil }
        return annotations.firstIndex(where: { $0.id == id })
    }

    /// 下排选项行应展示的工具：选中标注时按其类型，否则为当前工具
    private var effectiveOptionsTool: AnnotationTool {
        if let index = selectedShapeIndex {
            return AnnotationToolbar.tool(for: annotations[index].kind)
        }
        return currentTool
    }

    func selectFontSize(_ size: CGFloat) {
        // 选中标注时直接改其字号，否则改新标注的默认字号
        if let index = selectedShapeIndex, annotations[index].kind == .text {
            annotations[index].fontSize = size
            needsDisplay = true
        } else {
            currentFontSize = size
        }
        updateToolbarState()
    }

    func selectLineWidth(_ width: CGFloat) {
        // 选中标注时直接改其粗细/颗粒度，否则改新标注的默认值
        if let index = selectedShapeIndex {
            annotations[index].lineWidth = width
            if annotations[index].kind == .mosaic {
                mosaicCache.removeValue(forKey: annotations[index].id)
            }
            needsDisplay = true
        } else {
            currentLineWidth = width
        }
        updateToolbarState()
    }

    func selectColor(_ color: NSColor) {
        // 选中标注时直接改其颜色，否则改新标注的默认颜色
        if let index = selectedShapeIndex, annotations[index].kind != .mosaic {
            annotations[index].color = color
            needsDisplay = true
        } else {
            currentColor = color
        }
        updateToolbarState()
    }

    /// 统一的工具栏状态同步（字号/粗细/颜色/撤销重做都走这里）
    /// 选中标注时，下排显示并驱动该标注的属性；否则显示当前绘制参数
    private func updateToolbarState() {
        var displayColor = currentColor
        var displayFontSize = currentFontSize
        var displayLineWidth = currentLineWidth
        if let index = selectedShapeIndex {
            let shape = annotations[index]
            displayColor = shape.color
            displayFontSize = shape.fontSize
            displayLineWidth = shape.lineWidth
        }
        toolbar.updateState(
            activeTool: currentTool,
            optionsTool: effectiveOptionsTool,
            canUndo: !annotations.isEmpty,
            canRedo: !redoStack.isEmpty,
            activeColor: displayColor,
            fontSize: displayFontSize,
            lineWidth: displayLineWidth
        )
    }

    // MARK: - 光标

    private func updateCursor() {
        switch (phase, currentTool) {
        case (.selecting, _):
            // 悬停窗口 → 手型（点击可捕窗），否则十字准星
            if hoveredWindowRect != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        case (.annotating, .none), (.annotating, .select):
            NSCursor.arrow.set()
        case (.annotating, .text):
            NSCursor.iBeam.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    // MARK: - 工具栏

    private func makeToolbar() -> AnnotationToolbar {
        let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: 720, height: 58))
        toolbar.onSelectTool = { [weak self] tool in
            self?.selectTool(tool)
        }
        toolbar.onOptionsRowChanged = { [weak self] in
            guard let self else { return }
            self.toolbarSize = .zero
            self.layoutToolbar(animated: true)
        }
        toolbar.onSelectColor = { [weak self] color in
            self?.selectColor(color)
        }
        toolbar.onSelectFontSize = { [weak self] size in
            self?.selectFontSize(size)
        }
        toolbar.onSelectLineWidth = { [weak self] width in
            self?.selectLineWidth(width)
        }
        toolbar.onUndo = { [weak self] in
            self?.undo()
        }
        toolbar.onRedo = { [weak self] in
            self?.redo()
        }
        toolbar.onPin = { [weak self] in
            self?.pinSelection()
        }
        toolbar.onOCR = { [weak self] in
            self?.ocrAndPin()
        }
        toolbar.onConfirm = { [weak self] in
            self?.confirmSelection(copyOnly: false)
        }
        toolbar.onCancel = { [weak self] in
            self?.controller?.finish(.cancelled)
        }
        toolbar.onCopy = { [weak self] in
            self?.confirmSelection(copyOnly: true)
        }
        toolbar.onSave = { [weak self] in
            self?.saveToFile()
        }
        toolbar.onRecord = { [weak self] in
            self?.startRecordingFromSelection()
        }
        return toolbar
    }

    private func showToolbar() {
        if toolbar.superview == nil {
            addSubview(toolbar)
        }
        // 钉住窗口中钉住按钮保持选中且不可再操作
        toolbar.setPinned(isPinnedSession)
        // 统一捕获：仅全屏捕获会话展示「录制」按钮（首帧布局前设定，尺寸缓存不会过时）
        toolbar.setRecordingSupported(screenRecordingEnabled)
        updateToolbarState()
        layoutToolbar()
    }

    private func hideToolbar() {
        toolbar.removeFromSuperview()
    }

    private func layoutToolbar(animated: Bool = false) {
        guard let selection = selectionRect, toolbar.superview != nil else { return }
        if toolbarSize == .zero {
            toolbarSize = toolbar.preferredToolbarSize()
        }
        let width = toolbarSize.width
        let height = toolbarSize.height
        var x = selection.midX - width / 2
        x = min(max(x, bounds.minX + 4), bounds.maxX - width - 4)
        // 三级回退：选区下方外侧 → 选区上方外侧 → 选区内底部
        // （全屏/贴边窗口时外侧放不下，工具栏需落回选区内可见区域）
        var y = selection.minY - height - 10
        if y < bounds.minY + 4 {
            y = selection.maxY + 10
        }
        if y + height > bounds.maxY - 4 {
            y = selection.minY + 10
        }
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if animated {
            // 下排选项行显隐 → 高度补间，避免跳变
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                toolbar.animator().frame = frame
            }
        } else {
            toolbar.frame = frame
        }
    }

    // MARK: - 几何辅助

    private func normalizedRect(from p0: NSPoint, to p1: NSPoint) -> NSRect {
        NSRect(
            x: min(p0.x, p1.x),
            y: min(p0.y, p1.y),
            width: abs(p0.x - p1.x),
            height: abs(p0.y - p1.y)
        )
    }

    private func clamped(_ rect: NSRect) -> NSRect {
        var r = rect
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.width > bounds.width || r.height > bounds.height {
            r = bounds
        }
        return r
    }

    private func hitHandle(at point: NSPoint, in selection: NSRect) -> SelectionHandle? {
        SelectionHandle.allCases.first { $0.rect(for: selection).insetBy(dx: -3, dy: -3).contains(point) }
    }

    private func toolKind(for tool: AnnotationTool) -> AnnotationShape.Kind {
        switch tool {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .mosaic: return .mosaic
        case .pen: return .pen
        case .text: return .text
        case .none, .select: return .rect
        }
    }
}
#endif
