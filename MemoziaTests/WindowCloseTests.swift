import AppKit
import Testing
@testable import Memozia

@Suite(.serialized) @MainActor
struct WindowCloseTests {
    private func window() -> TrackingWindow {
        let window = TrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func notification(_ name: Notification.Name, _ window: NSWindow) -> Notification {
        Notification(name: name, object: window)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("普通或缩放窗口关闭时只隐藏，不销毁或切换全屏")
    func windowedCloseHidesImmediately() {
        let window = window()
        let delegate = HideOnCloseWindowDelegate()
        #expect(!delegate.windowShouldClose(window))
        #expect(window.hideCount == 1)
        #expect(window.fullScreenToggleCount == 0)
    }

    @Test("全屏关闭先退出 Space，退出完成的下一轮才隐藏并通知完成")
    func fullScreenCloseWaitsForExit() async {
        let window = window()
        window.simulatedFullScreen = true
        let delegate = HideOnCloseWindowDelegate()
        let original = ForwardedDelegate()
        delegate.forwardTo = original
        var completed = false
        delegate.hide(window) { completed = true }
        #expect(window.hideCount == 0)
        #expect(window.fullScreenToggleCount == 1)
        #expect(!completed)
        #expect(!delegate.windowShouldClose(window))
        #expect(window.fullScreenToggleCount == 1)

        delegate.windowWillExitFullScreen(notification(NSWindow.willExitFullScreenNotification, window))
        window.simulatedFullScreen = false
        delegate.windowDidExitFullScreen(notification(NSWindow.didExitFullScreenNotification, window))
        #expect(original.events == ["willExit", "didExit"])
        #expect(window.hideCount == 0)
        await drainMainQueue()
        #expect(window.hideCount == 1)
        #expect(completed)
    }

    @Test("进入全屏动画中关闭，会等进入完成后退出，不提前隐藏")
    func closeDuringEntryWaitsForBothTransitions() async {
        let window = window()
        let delegate = HideOnCloseWindowDelegate()
        let original = ForwardedDelegate()
        delegate.forwardTo = original
        delegate.windowWillEnterFullScreen(notification(NSWindow.willEnterFullScreenNotification, window))
        #expect(!delegate.windowShouldClose(window))
        #expect(window.hideCount == 0)
        #expect(window.fullScreenToggleCount == 0)

        window.simulatedFullScreen = true
        delegate.windowDidEnterFullScreen(notification(NSWindow.didEnterFullScreenNotification, window))
        await drainMainQueue()
        #expect(window.fullScreenToggleCount == 1)
        #expect(window.hideCount == 0)
        #expect(original.events == ["willEnter", "didEnter"])
        window.simulatedFullScreen = false
        delegate.windowDidExitFullScreen(notification(NSWindow.didExitFullScreenNotification, window))
        await drainMainQueue()
        #expect(window.hideCount == 1)
    }

    @Test("用户已经开始退出全屏时关闭，不重复切换全屏")
    func closeDuringExitUsesExistingTransition() async {
        let window = window()
        window.simulatedFullScreen = true
        let delegate = HideOnCloseWindowDelegate()
        delegate.windowWillExitFullScreen(notification(NSWindow.willExitFullScreenNotification, window))
        #expect(!delegate.windowShouldClose(window))
        #expect(window.fullScreenToggleCount == 0)
        #expect(window.hideCount == 0)
        window.simulatedFullScreen = false
        delegate.windowDidExitFullScreen(notification(NSWindow.didExitFullScreenNotification, window))
        await drainMainQueue()
        #expect(window.hideCount == 1)
    }

    @Test("重新显示窗口可取消已排队的隐藏与 Dock 隐藏回调")
    func restoreCancelsQueuedHide() async {
        let window = window()
        window.simulatedFullScreen = true
        let delegate = HideOnCloseWindowDelegate()
        var completed = false
        delegate.hide(window) { completed = true }
        window.simulatedFullScreen = false
        delegate.windowDidExitFullScreen(notification(NSWindow.didExitFullScreenNotification, window))
        delegate.cancelPendingHide()
        await drainMainQueue()
        #expect(window.hideCount == 0)
        #expect(!completed)
        #expect(!delegate.windowShouldClose(window))
        #expect(window.hideCount == 1)
    }

    @Test("退出全屏失败时不隐藏全屏窗口，允许用户再次关闭")
    func failedExitKeepsWindowAvailable() {
        let window = window()
        window.simulatedFullScreen = true
        let delegate = HideOnCloseWindowDelegate()
        let original = ForwardedDelegate()
        delegate.forwardTo = original
        var completed = false
        delegate.hide(window) { completed = true }
        delegate.windowDidFailToExitFullScreen(window)
        #expect(window.hideCount == 0)
        #expect(!completed)
        #expect(original.events == ["failedExit"])
        #expect(!delegate.windowShouldClose(window))
        #expect(window.fullScreenToggleCount == 2)
    }

    @Test("进入全屏失败后，可继续隐藏普通窗口")
    func failedEntryCompletesWindowedHide() async {
        let window = window()
        let delegate = HideOnCloseWindowDelegate()
        let original = ForwardedDelegate()
        delegate.forwardTo = original
        delegate.windowWillEnterFullScreen(notification(NSWindow.willEnterFullScreenNotification, window))
        delegate.hide(window)
        delegate.windowDidFailToEnterFullScreen(window)
        await drainMainQueue()
        #expect(window.hideCount == 1)
        #expect(window.fullScreenToggleCount == 0)
        #expect(original.events == ["willEnter", "failedEntry"])
    }
}

@MainActor
private final class TrackingWindow: NSWindow {
    var simulatedFullScreen = false
    var hideCount = 0
    var fullScreenToggleCount = 0

    override var styleMask: NSWindow.StyleMask {
        get {
            simulatedFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen)
        }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }

    override func orderOut(_ sender: Any?) { hideCount += 1 }
    override func toggleFullScreen(_ sender: Any?) { fullScreenToggleCount += 1 }
}

@MainActor
private final class ForwardedDelegate: NSObject, NSWindowDelegate {
    var events: [String] = []
    func windowWillEnterFullScreen(_ notification: Notification) { events.append("willEnter") }
    func windowDidEnterFullScreen(_ notification: Notification) { events.append("didEnter") }
    func windowWillExitFullScreen(_ notification: Notification) { events.append("willExit") }
    func windowDidExitFullScreen(_ notification: Notification) { events.append("didExit") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { events.append("failedEntry") }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { events.append("failedExit") }
}
