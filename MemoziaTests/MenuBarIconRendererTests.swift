import AppKit
import Testing
@testable import Memozia

@Suite @MainActor
struct MenuBarIconRendererTests {
    @Test(arguments: [1, 2, 3])
    func visiblePixelsAreCenteredAtEachDisplayDensity(scale: Int) throws {
        let source = try #require(NSImage(symbolName: "MemoziaMenuBar", bundle: .main, variableValue: 0))
        let image = try #require(MenuBarIconRenderer.makeTemplate(from: source))
        #expect(image.isTemplate)
        let bitmap = try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == 22 * scale })
        let data = try #require(bitmap.bitmapData)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 16 {
                xs.append(x); ys.append(y)
            }
        }
        let left = try #require(xs.min()), right = try #require(xs.max()) + 1
        let top = try #require(ys.min()), bottom = try #require(ys.max()) + 1
        #expect(abs(Double(left + right - bitmap.pixelsWide)) <= 1)
        #expect(abs(Double(top + bottom - bitmap.pixelsHigh)) <= 1)
        #expect(abs(max(right - left, bottom - top) - 18 * scale) <= 1)
    }
}
