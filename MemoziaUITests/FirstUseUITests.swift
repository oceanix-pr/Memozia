import XCTest

/// Exercise macOS menu commands and the real sheets in isolated, empty storage.
@MainActor
final class FirstUseUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testGermanFirstUse() throws {
        try checkFirstUse(language: "de", help: "Hilfe", guide: "Erste Schritte",
                          faq: "Besprechungsprotokoll", helpTitle: "Memozia-Hilfe")
    }

    func testArabicFirstUse() throws {
        try checkFirstUse(language: "ar", help: "مساعدة", guide: "دليل البدء",
                          faq: "محضر", helpTitle: "مساعدة Memozia")
    }

    private func checkFirstUse(language: String, help: String, guide: String, faq: String, helpTitle: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchEnvironment["CFFIXED_USER_HOME"] = folder.path
        app.launchArguments = ["--ui-testing", "--first-use-ui-test", "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language, "-AppInterfaceLanguage", language, "-app_experience_mode", "standard",
                               "-Memozia_storage_directory", folder.appendingPathComponent("Entries").path,
                               "-standard_recording_mode", "unset", "-hasAcceptedPrivacyPolicy", "NO"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let privacy = app.sheets.firstMatch
        let accept = privacy.buttons["acceptPrivacy"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
        app.activate()
        let languageMenu = privacy.popUpButtons["interfaceLanguage"]
        XCTAssertTrue(languageMenu.waitForExistence(timeout: 5))
        XCTAssertFalse(accept.isEnabled)
        attachSheet(app, "\(language)-privacy")
        languageMenu.click()
        XCTAssertTrue(app.menuItems["English"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        // Exercise the first main window after consent without changing the user's stored consent.
        app.terminate()
        app.launchArguments.removeLast(2)
        app.launchArguments += ["-hasAcceptedPrivacyPolicy", "YES", "-privacyPolicyVersion", "7.1",
                                "-hasCompletedOnboarding", "NO", "-onboardingCompletedVersion", ""]
        app.launch()
        app.activate()
        let record = app.buttons["firstRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let firstGuide = app.descendants(matching: .any)["firstUseGuide"].firstMatch
        XCTAssertTrue(firstGuide.waitForExistence(timeout: 5))
        firstGuide.click()
        let guideWindow = app.windows[guide]
        let closeGuide = guideWindow.buttons["closeGettingStarted"]
        XCTAssertTrue(closeGuide.waitForExistence(timeout: 5))
        closeGuide.click()
        XCTAssertTrue(guideWindow.waitForNonExistence(timeout: 8))
        record.click()
        XCTAssertTrue(app.buttons["startMeeting_inPersonMeeting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startMeeting_onlineMeeting"].isHittable)
        let meetingSheet = app.sheets.firstMatch
        meetingSheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(meetingSheet.waitForNonExistence(timeout: 8))

        let bar = app.menuBars.firstMatch
        let helpMenu = bar.menuBarItems[help]
        let menu = helpMenu.exists ? helpMenu : bar.menuBarItems.element(boundBy: bar.menuBarItems.count - 1)
        var initialPage: String?
        for pass in 0..<2 {
            menu.click()
            menu.menuItems[guide].click()
            let window = app.windows[guide]
            let close = window.buttons["closeGettingStarted"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            app.activate()
            let next = window.buttons["nextGuidePage"]
            XCTAssertTrue(next.wait(for: \.isHittable, toEqual: true, timeout: 8))
            XCTAssertEqual(next.frame.midX < close.frame.midX, language == "ar",
                           "Guide navigation must follow the interface reading direction")
            let heading = window.staticTexts["guidePageTitle"]
            if pass == 0 {
                initialPage = heading.value as? String ?? heading.label
                next.click()
                XCTAssertNotEqual(heading.value as? String ?? heading.label, initialPage)
                attach(window, "\(language)-guide")
                close.click()
            } else {
                XCTAssertEqual(heading.value as? String ?? heading.label, initialPage)
                window.typeKey(.escape, modifierFlags: [])
            }
            XCTAssertTrue(window.waitForNonExistence(timeout: 8))
        }

        menu.click()
        menu.menuItems[helpTitle].click()
        let search = app.textFields["helpSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.activate()
        search.click()
        search.typeText(faq)
        let destination = app.buttons["helpOpenIntelligence"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["closeHelp"].frame.midX < search.frame.midX, language == "ar")
        attachSheet(app, "\(language)-help")
        XCTAssertTrue(destination.wait(for: \.isHittable, toEqual: true, timeout: 8))
        destination.click()
        let about = app.descendants(matching: .any)["settingsSection_about"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        let interfaceLanguage = app.popUpButtons["interfaceLanguage"]
        XCTAssertTrue(interfaceLanguage.waitForExistence(timeout: 5))
        XCTAssertEqual(about.frame.midX > interfaceLanguage.frame.midX, language == "ar",
                       "Settings sidebar must be at the leading edge")
        attachSheet(app, "\(language)-settings")
    }

    private func attachSheet(_ app: XCUIApplication, _ name: String) {
        let sheet = app.sheets.firstMatch
        attach(sheet.exists ? sheet : app.windows.firstMatch, name)
    }

    private func attach(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
