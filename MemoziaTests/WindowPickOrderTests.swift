import Foundation
import CoreGraphics
import AppKit
import Testing

@testable import Memozia

/// 窗口拾取的「前→后」顺序。
///
/// 背景：可拾取窗口由 `SCShareableContent.windows` 枚举，但 Apple 未承诺该数组的顺序。
/// 若直接按枚举序做 `first { contains }`，点击最前面的窗口可能命中它后面被遮挡的窗口，
/// 录制出口据此升级为独立窗口录制（`desktopIndependentWindow` 与遮挡无关、完整采集），
/// 于是就录到了「当前窗口后面的窗口」。
///
/// 因此可拾取窗口必须按 `CGWindowListCopyWindowInfo` 的权威前→后顺序重排。
/// 本文件钉住该重排逻辑：命中检测取到的一定是最前面的窗口，未出现在 z 序中的窗口退到末尾。
struct WindowPickOrderTests {

    private func window(
        _ id: CGWindowID,
        x: CGFloat = 0,
        y: CGFloat = 0
    ) -> (rect: NSRect, screenFrame: NSRect, id: CGWindowID) {
        (
            NSRect(x: x, y: y, width: 100, height: 100),
            NSRect(x: 0, y: 0, width: 1000, height: 1000),
            id
        )
    }

    @Test("按 z 序重排后，命中检测取到的是最前面的窗口")
    func frontmostWindowWins() {
        // 输入故意打乱；zIndex 越小越靠前
        let windows = [window(30), window(10), window(20)]
        let zIndex: [CGWindowID: Int] = [10: 0, 20: 1, 30: 2]

        let ordered = RegionSelectionController.sortedFrontToBack(windows, zIndex: zIndex)
        #expect(ordered.map { $0.id } == [10, 20, 30])

        // 三个窗口矩形完全重叠：first { contains } 必须命中 z 序最前的 10，而不是后面的 20/30
        let hit = ordered.first { $0.rect.contains(NSPoint(x: 50, y: 50)) }
        #expect(hit?.id == 10)
    }

    @Test("未出现在 z 序中的窗口退到末尾，并保持原有相对顺序")
    func unknownWindowsGoToEnd() {
        // 99 不在 zIndex（模拟两次枚举之间窗口增删）；20/77 的相对顺序由 z 序决定
        let windows = [window(99), window(20), window(77)]
        let zIndex: [CGWindowID: Int] = [20: 0, 77: 1]

        let ordered = RegionSelectionController.sortedFrontToBack(windows, zIndex: zIndex)
        #expect(ordered.map { $0.id } == [20, 77, 99])
    }

    @Test("未提供任何 z 序时保持输入顺序（稳定排序）")
    func preservesOrderWithoutZIndex() {
        let windows = [window(7), window(3), window(5)]

        let ordered = RegionSelectionController.sortedFrontToBack(windows, zIndex: [:])
        #expect(ordered.map { $0.id } == [7, 3, 5])
    }

    @Test("空输入不崩")
    func emptyInput() {
        #expect(RegionSelectionController.sortedFrontToBack([], zIndex: [:]).isEmpty)
    }
}
