#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

/// CGImage 不可变且线程安全；包一层 @unchecked Sendable 盒，便于把 PNG 编码放到后台线程。
/// 刻意声明在**文件作用域**而不是 `@MainActor` 的视图类内部：类内嵌套类型会继承主 actor
/// 隔离，导致后台线程读取其属性时报 “Main actor-isolated … cannot be called from outside of the actor”。
final class ImageEncodeBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

// MARK: - 选区调节手柄

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    func rect(for selection: NSRect, size: CGFloat = 9) -> NSRect {
        let point: NSPoint
        switch self {
        case .topLeft: point = NSPoint(x: selection.minX, y: selection.maxY)
        case .top: point = NSPoint(x: selection.midX, y: selection.maxY)
        case .topRight: point = NSPoint(x: selection.maxX, y: selection.maxY)
        case .left: point = NSPoint(x: selection.minX, y: selection.midY)
        case .right: point = NSPoint(x: selection.maxX, y: selection.midY)
        case .bottomLeft: point = NSPoint(x: selection.minX, y: selection.minY)
        case .bottom: point = NSPoint(x: selection.midX, y: selection.minY)
        case .bottomRight: point = NSPoint(x: selection.maxX, y: selection.minY)
        }
        return NSRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
    }

    /// 拖动该手柄到 point 后的选区：仅手柄所在边移动，对侧边固定为起始矩形。
    /// 边手柄必须锁定垂直方向（否则宽度跟随光标，整块选区塌成细线）；
    /// 移动边不允许越过对侧边（保持最小尺寸），因此结果无需再归一化。
    /// - Parameter minSize: 最小选区边长（须与 OverlayAnnotationView.minSelectionSize 一致；
    ///   该常量为 MainActor 隔离，非隔离 enum 的默认参数不能引用，只能取字面量）
    func resizingRect(of start: NSRect, to point: NSPoint, minSize: CGFloat = 8) -> NSRect {
        var x0 = start.minX, x1 = start.maxX, y0 = start.minY, y1 = start.maxY
        switch self {
        case .topLeft:
            x0 = min(point.x, x1 - minSize)
            y1 = max(point.y, y0 + minSize)
        case .top:
            y1 = max(point.y, y0 + minSize)
        case .topRight:
            x1 = max(point.x, x0 + minSize)
            y1 = max(point.y, y0 + minSize)
        case .left:
            x0 = min(point.x, x1 - minSize)
        case .right:
            x1 = max(point.x, x0 + minSize)
        case .bottomLeft:
            x0 = min(point.x, x1 - minSize)
            y0 = min(point.y, y1 - minSize)
        case .bottom:
            y0 = min(point.y, y1 - minSize)
        case .bottomRight:
            x1 = max(point.x, x0 + minSize)
            y0 = min(point.y, y1 - minSize)
        }
        return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// 圆角矩形文字输入框：半透明灰底（layer 圆角，保证渲染）+ 居中「输入文字」占位符
final class TextEditorHostView: NSView {

    let textField: NSTextField
    private let placeholderLabel: NSTextField

    init(frame: NSRect, placeholder: String, font: NSFont, textColor: NSColor) {
        placeholderLabel = NSTextField(labelWithString: placeholder)
        placeholderLabel.font = .systemFont(ofSize: font.pointSize)
        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        // frame 是宿主在父视图中的坐标；输入框必须按宿主自身坐标系布局，
        // 若直接用 frame.insetBy 会把输入框放到宿主可见区域外（layer 裁剪后不可见且无法输入）
        // 输入框高度取字体行高并在宿主内垂直居中：无边框输入框编辑时 field editor 依框顶排版，
        // 框高于行高会导致光标/文字偏上不居中
        let lineHeight = font.ascender - font.descender + font.leading
        textField = NSTextField(frame: NSRect(
            x: 10,
            y: (frame.height - lineHeight) / 2,
            width: frame.width - 20,
            height: lineHeight
        ))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 8

        textField.font = font
        textField.textColor = textColor
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        addSubview(textField)

        setAccessibilityLabel(String(localized: "文字标注输入框"))
        setAccessibilityRole(.textField)

        placeholderLabel.sizeToFit()
        placeholderLabel.frame.origin = NSPoint(
            x: (frame.width - placeholderLabel.frame.width) / 2,
            y: (frame.height - placeholderLabel.frame.height) / 2
        )
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setPlaceholderHidden(_ hidden: Bool) {
        placeholderLabel.isHidden = hidden
    }

    /// 点击圆角框任意位置（含字段周围空白）→ 聚焦输入框
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
    }
}
#endif
