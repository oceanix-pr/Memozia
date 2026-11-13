import XCTest
import CoreGraphics
import ImageIO
import Foundation

/// UI 测试支持：统一的应用启动入口、多语言/RTL/伪本地化参数，以及截图基线工具。
///
/// 设计要点：
/// - 被测应用以 `--ui-testing` 启动，跳过单实例守卫（详见 `AppRuntime.isUITesting`），
///   否则用户机器上已有实例时被测进程会立即退出，UI 测试拿不到窗口；
/// - 语言/地区通过 `-AppleLanguages` / `-AppleLocale` 传入（工程非沙盒，参数不会被丢弃）；
/// - 伪本地化走 AppKit 既定开关：`-NSDoubleLocalizedStrings`（字符串加长）与
///   `-NSForceRightToLeft`（强制 RTL 排版）。
enum UITestLanguage: String, CaseIterable {
    case zhHans = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    /// 工程内唯一的真实 RTL 语言，用于验证界面镜像
    case arabic = "ar"

    var localeIdentifier: String {
        switch self {
        case .zhHans: return "zh_Hans"
        case .english: return "en_US"
        case .japanese: return "ja_JP"
        case .arabic: return "ar"
        }
    }

    /// 截图基线文件名用的稳定标识
    var baselineName: String {
        rawValue.replacingOccurrences(of: "-", with: "_").lowercased()
    }
}

/// 一次启动的完整配置
struct UITestLaunchConfiguration {
    var name: String
    var language: UITestLanguage?
    var forceRightToLeft = false
    var doubleLengthStrings = false
    var extraArguments: [String] = []

    static let base = UITestLaunchConfiguration(name: "base")

    static func language(_ language: UITestLanguage) -> UITestLaunchConfiguration {
        UITestLaunchConfiguration(name: language.baselineName, language: language)
    }

    /// 伪本地化：英文界面 + 字符串加长，暴露布局截断/换行问题
    static let doubleLengthPseudo =
        UITestLaunchConfiguration(name: "pseudo_double_length", language: .english, doubleLengthStrings: true)

    /// 伪 RTL：英文界面 + 强制从右到左排版
    static let forcedRTLPseudo =
        UITestLaunchConfiguration(name: "pseudo_rtl", language: .english, forceRightToLeft: true)
}

enum UITestAppLauncher {
    /// 启动被测应用并等待主窗口出现
    @discardableResult
    static func launch(
        _ configuration: UITestLaunchConfiguration = .base,
        waitForWindow: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        if let language = configuration.language {
            app.launchArguments += ["-AppleLanguages", "(\(language.rawValue))"]
            app.launchArguments += ["-AppleLocale", language.localeIdentifier]
        }
        if configuration.doubleLengthStrings {
            app.launchArguments += ["-NSDoubleLocalizedStrings", "YES"]
        }
        if configuration.forceRightToLeft {
            app.launchArguments += ["-NSForceRightToLeft", "YES"]
        }
        app.launchArguments += configuration.extraArguments
        app.launch()

        if waitForWindow {
            let window = app.windows.firstMatch
            XCTAssertTrue(
                window.waitForExistence(timeout: 30),
                "主窗口未在 30s 内出现（\(configuration.name)）",
                file: file,
                line: line
            )
        }
        return app
    }
}

/// 截图基线：把关键界面截图与仓库内基线比对。
///
/// 基线读取自**测试 bundle 资源**（仓库内 `MemoziaUITests/Baselines/*.png`，随构建打包，
/// 沙盒 runner 只读）。UI 测试 runner 受沙盒 + TCC 限制，无法写入项目目录，因此
/// **基线缺失时会自动记录**到 runner 可写目录（路径会打印到测试日志，
/// 形如 `Memozia_UI_BASELINE_WRITTEN <path>`），此时不判定失败。
///
/// 记录/更新基线的推荐流程（runner 容器受 TCC 保护，外部工具读不到，改用结果包附件）：
/// 1. `xcodebuild ... test -only-testing:MemoziaUITests -resultBundlePath /tmp/ui.xcresult`
/// 2. `xcrun xcresulttool export attachments --path /tmp/ui.xcresult --output-path /tmp/ui-attach`
/// 3. 按 `/tmp/ui-attach/manifest.json` 的建议名把 PNG 拷回 `MemoziaUITests/Baselines/` 并提交。
///
/// 若在 scheme 的 Test action 里设置了可写目录 `Memozia_UI_BASELINE_DIR`，记录会写入该目录；
/// `UPDATE_UI_BASELINES=1` 可强制重录（这两者须经 scheme 环境变量传给 runner，shell 变量不会透传）。
///
/// 基线存在时按容差判定差异。
extension XCTestCase {
    /// 不同像素占比阈值：留出光标闪烁、抗锯齿、时间戳等轻微差异
    static var screenshotTolerance: Double { 0.02 }

    /// 缩放到固定宽度后比较，消除窗口尺寸差异并显著降低比较开销
    private static var normalizedWidth: Int { 480 }

    /// 记录模式的输出目录：优先 `Memozia_UI_BASELINE_DIR`，否则落在 runner 的临时目录
    /// （UI 测试 runner 受沙盒 + TCC 限制，无法直接写入受保护的项目目录）。
    private static var recordDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["Memozia_UI_BASELINE_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Memozia-ui-baselines", isDirectory: true)
    }

    private static var isRecordingBaselines: Bool {
        ProcessInfo.processInfo.environment["UPDATE_UI_BASELINES"] == "1"
    }

    private static func bundledBaselineURL(named name: String) -> URL? {
        Bundle(for: BaselineBundleToken.self).url(forResource: name, withExtension: "png")
    }

    /// 基线缺失必须失败；只允许在 CI 外显式录制经人工审核的基线。
    func verifyScreenshot(
        _ screenshot: XCUIScreenshot,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let data = screenshot.pngRepresentation

        let bundledBaseline = Self.bundledBaselineURL(named: name)
        let forceRecord = Self.isRecordingBaselines

        if forceRecord && ProcessInfo.processInfo.environment["MEMOZIA_CI"] == "1" {
            XCTFail("CI 不得自动录制截图基线", file: file, line: line)
            return
        }
        // 只能显式录制；审核 PNG 后手动加入仓库，正常测试绝不自动接受新外观。
        if forceRecord {
            recordBaseline(
                data: data,
                to: Self.recordDirectory.appendingPathComponent("\(name).png"),
                file: file,
                line: line
            )
            return
        }

        guard let baselineURL = bundledBaseline else {
            XCTFail("缺少截图基线 \(name).png；请在固定环境显式录制、审核并提交基线", file: file, line: line)
            return
        }

        guard let baselineData = try? Data(contentsOf: baselineURL) else {
            XCTFail("无法读取基线截图 \(name).png", file: file, line: line)
            return
        }
        guard let ratio = PixelDiff.differingPixelRatio(
            baselineData,
            data,
            normalizedWidth: Self.normalizedWidth
        ) else {
            XCTFail("无法解码基线或当前截图（\(name)）", file: file, line: line)
            return
        }

        XCTAssertLessThanOrEqual(
            ratio,
            Self.screenshotTolerance,
            String(
                format: "截图 %@ 与基线差异 %.2f%%，超过阈值 %.2f%%（当前截图见附件；确认无误后记录并更新基线）",
                name,
                ratio * 100,
                Self.screenshotTolerance * 100
            ),
            file: file,
            line: line
        )
    }

    private func recordBaseline(data: Data, to url: URL, file: StaticString, line: UInt) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            // 打到测试日志，便于从 xcodebuild 输出定位记录目录
            print("Memozia_UI_BASELINE_WRITTEN \(url.path)")
            add(XCTAttachment(string: "已写入基线：\(url.path)"))
        } catch {
            XCTFail("写入基线失败 \(url.lastPathComponent)：\(error.localizedDescription)", file: file, line: line)
        }
    }
}

/// `Bundle(for:)` 需要一个类；UI 测试 bundle 内的标题类作为锚点
private final class BaselineBundleToken {}

/// 图片像素差异：双方等比缩放到同一宽度后，按每像素 RGB 距离统计差异占比。
enum PixelDiff {
    static func differingPixelRatio(_ lhs: Data, _ rhs: Data, normalizedWidth: Int) -> Double? {
        guard let a = normalizedRGBA(lhs, width: normalizedWidth),
              let b = normalizedRGBA(rhs, width: normalizedWidth),
              a.pixels.count == b.pixels.count else { return nil }

        let pixels = a.pixels.count / 4
        guard pixels > 0 else { return nil }
        var differing = 0
        // 单通道差值超过该阈值即视为该像素不同（抑制抗锯齿/压缩噪声）
        let channelThreshold = 24
        for index in 0..<pixels {
            let offset = index * 4
            let dr = abs(Int(a.pixels[offset]) - Int(b.pixels[offset]))
            let dg = abs(Int(a.pixels[offset + 1]) - Int(b.pixels[offset + 1]))
            let db = abs(Int(a.pixels[offset + 2]) - Int(b.pixels[offset + 2]))
            if dr > channelThreshold || dg > channelThreshold || db > channelThreshold {
                differing += 1
            }
        }
        return Double(differing) / Double(pixels)
    }

    private struct Bitmap {
        let pixels: [UInt8]
    }

    private static func normalizedRGBA(_ data: Data, width: Int) -> Bitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }

        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Bitmap(pixels: buffer)
    }
}
