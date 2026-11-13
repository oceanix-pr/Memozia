import XCTest

/// 无障碍（VoiceOver）审计：用 `performAccessibilityAudit` 对主界面做与
/// Accessibility Inspector 一致的自动化审计。
///
/// 默认**只报告不失败**：审计发现的每个问题都会作为测试附件记录（便于分诊），
/// 但不会让套件变红——因为当前应用确实存在需要单独排期的无障碍缺口。
/// 需要强制门禁时设 `STRICT_UI_ACCESSIBILITY=1`，此时发现任何问题即失败。
///
/// 注意：审计回调会被送往其它隔离域（Swift 6 严格并发），因此必须**不捕获 self**
/// （XCTestCase 非 Sendable），只把问题交给一个 `@unchecked Sendable` 的收集器。
final class AccessibilityAuditUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMainWindowAccessibilityAudit() throws {
        try audit(.base)
    }

    /// 多语言界面同样跑一遍审计：CJK / RTL 文案下的元素描述与命中区域更容易出问题
    func testAccessibilityAuditUnderArabic() throws {
        try audit(.language(.arabic))
    }

    private func audit(
        _ configuration: UITestLaunchConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let app = UITestAppLauncher.launch(configuration)
        let collector = AccessibilityIssueCollector()

        try app.performAccessibilityAudit(for: .all) { issue in
            collector.record(issue)
            // 一律"已处理"：是否严格由收尾断言按环境变量决定
            return true
        }

        let issues = collector.snapshot
        let attachment = XCTAttachment(
            string: issues.isEmpty ? "未发现无障碍审计问题" : issues.joined(separator: "\n")
        )
        attachment.name = "accessibility-audit-\(configuration.name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        if ProcessInfo.processInfo.environment["STRICT_UI_ACCESSIBILITY"] == "1" {
            XCTAssertTrue(
                issues.isEmpty,
                "无障碍审计发现 \(issues.count) 项问题：\n\(issues.joined(separator: "\n"))",
                file: file,
                line: line
            )
        }
    }
}

/// 跨隔离域收集审计问题（`@unchecked Sendable`：内部用锁保护可变数组）
private final class AccessibilityIssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [String] = []

    func record(_ issue: XCUIAccessibilityAuditIssue) {
        lock.lock()
        defer { lock.unlock() }
        var line = issue.compactDescription
        if let element = issue.element, !element.identifier.isEmpty {
            line += " [identifier=\(element.identifier)]"
        }
        issues.append(line)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return issues
    }
}
