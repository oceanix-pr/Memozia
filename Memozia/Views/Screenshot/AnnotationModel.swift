#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - 标注数据模型

/// 单个标注形状（绘制在悬浮层视图坐标系中，确认时统一栅格化为 PNG）
struct AnnotationShape: Identifiable {
    enum Kind {
        case rect
        case ellipse
        case arrow
        case pen
        case text
        case mosaic
    }

    let id: UUID
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    /// rect/ellipse/arrow/mosaic: [起点, 终点]；pen: 轨迹点；text: [文字左上角]
    var points: [NSPoint]
    var text: String?
    var fontSize: CGFloat
    /// 文字格式：粗体 / 斜体（仅 text 使用）
    var isBold: Bool
    var isItalic: Bool

    init(
        kind: Kind,
        color: NSColor,
        lineWidth: CGFloat = 3,
        points: [NSPoint],
        text: String? = nil,
        fontSize: CGFloat = 18,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.id = UUID()
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.points = points
        self.text = text
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
    }

    /// 文字标注渲染字体（粗细 + 斜体 traits）
    var textFont: NSFont {
        var font = NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        if isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

/// 标注工具
enum AnnotationTool: CaseIterable {
    case none      // 默认：调整选区（移动/缩放/重新框选）
    case select    // 选择/移动/删除单个标注
    case rect
    case ellipse
    case arrow
    case pen
    case text
    case mosaic
}
#endif
