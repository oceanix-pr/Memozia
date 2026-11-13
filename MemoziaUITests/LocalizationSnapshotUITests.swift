import XCTest

/// 多语言 / RTL / 伪本地化截图基线。
///
/// 每种语言与伪本地化配置单独启动一次并截取主窗口，与 `Baselines/` 下的基线比对：
/// 基线缺失时仅提示（不失败），存在时按容差判定差异。
final class LocalizationSnapshotUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 多语言循环里允许继续，逐个语言产出截图与结论
        continueAfterFailure = true
    }

    func testLanguageScreenshots() {
        for language in UITestLanguage.allCases {
            let app = UITestAppLauncher.launch(.language(language))
            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists, "\(language.rawValue) 下主窗口应存在")
            verifyScreenshot(window.screenshot(), named: "main_window_\(language.baselineName)")
            app.terminate()
        }
    }

    func testPseudoLocalizationScreenshots() {
        for configuration in [
            UITestLaunchConfiguration.doubleLengthPseudo,
            UITestLaunchConfiguration.forcedRTLPseudo
        ] {
            let app = UITestAppLauncher.launch(configuration)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists, "\(configuration.name) 下主窗口应存在")
            verifyScreenshot(window.screenshot(), named: "main_window_\(configuration.name)")
            app.terminate()
        }
    }

    /// 真实 RTL 语言（阿拉伯语）：界面应完成镜像而不错位，并可作为基线复核
    func testArabicRightToLeftLayout() {
        let app = UITestAppLauncher.launch(.language(.arabic))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "阿拉伯语下主窗口应存在")
        XCTAssertGreaterThan(window.frame.width, 0, "主窗口应有有效宽度")
        verifyScreenshot(window.screenshot(), named: "main_window_rtl_ar")
    }
}
