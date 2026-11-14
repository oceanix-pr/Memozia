#if os(macOS)
import AppKit

/// 将 SF Symbol 的可见笔画放入普通模板图，避免状态按钮再次应用字体基线偏移。
@MainActor
enum MenuBarIconRenderer {
    static let canvasSide = 22
    static let visibleSide = 18

    static func makeTemplate(from symbol: NSImage) -> NSImage? {
        guard let configured = symbol.withSymbolConfiguration(
            .init(pointSize: 26, weight: .regular)
        ) else { return nil }
        let size = NSSize(width: canvasSide, height: canvasSide)
        let image = NSImage(size: size)
        // 分别栅格化，保证普通、Retina 和更高密度屏幕均有对应的清晰表示。
        for scale in [1, 2, 3] {
            let width = Int(ceil(configured.size.width * CGFloat(scale)))
            let height = Int(ceil(configured.size.height * CGFloat(scale)))
            guard let source = bitmap(width: width, height: height),
                  let context = NSGraphicsContext(bitmapImageRep: source) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            configured.draw(in: NSRect(origin: .zero, size: configured.size),
                            from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            guard let bounds = inkBounds(source),
                  let cropped = source.cgImage?.cropping(to: bounds),
                  let output = bitmap(width: canvasSide * scale, height: canvasSide * scale),
                  let outputContext = NSGraphicsContext(bitmapImageRep: output) else { return nil }
            let factor = CGFloat(visibleSide * scale) / max(bounds.width, bounds.height)
            let inkSize = CGSize(width: bounds.width * factor, height: bounds.height * factor)
            let canvas = CGFloat(canvasSide * scale)
            let destination = CGRect(x: (canvas - inkSize.width) / 2,
                                     y: (canvas - inkSize.height) / 2,
                                     width: inkSize.width, height: inkSize.height)
            outputContext.cgContext.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            outputContext.cgContext.interpolationQuality = .high
            outputContext.cgContext.draw(cropped, in: destination)
            output.size = size
            image.addRepresentation(output)
        }
        image.alignmentRect = NSRect(origin: .zero, size: size)
        image.isTemplate = true
        image.accessibilityDescription = "Memozia"
        return image
    }

    private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [],
                         bytesPerRow: width * 4, bitsPerPixel: 32)
    }

    private static func inkBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        guard let pixels = bitmap.bitmapData else { return nil }
        var left = bitmap.pixelsWide, right = -1, top = bitmap.pixelsHigh, bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
#endif
