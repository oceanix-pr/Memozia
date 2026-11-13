import XCTest

/// 冒烟测试：应用能启动、主窗口出现，并产出主界面截图基线。
final class MemoziaSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchesAndShowsMainWindow() {
        let app = UITestAppLauncher.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "主窗口应存在")
        XCTAssertTrue(app.state == .runningForeground, "应用应处于前台运行状态")
    }

    func testMainWindowScreenshotBaseline() {
        let app = UITestAppLauncher.launch()
        let window = app.windows.firstMatch
        verifyScreenshot(window.screenshot(), named: "main_window_base")
    }
}
