import XCTest

/// The system audio status in the real Settings → Permissions tab. The stored system audio check
/// is seeded at launch (`-SeedSystemAudioCheck`, fixed date) into the isolated
/// settings; the test reads what the tab really shows. The permission count in
/// the header is derived from the real microphone and Accessibility rows, so
/// the result does not depend on the grants of the machine running the test.
/// Expected texts come from the app's own catalog in the language it runs in.
@MainActor
final class SystemAudioStatusTests: XCTestCase {
    /// Same instant as `SystemAudioCheckSeed.date`, formatted like the tab does.
    private let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)
        .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))

    func testCreatedSourceIsNotShownAsAGrantedPermission() throws {
        let app = try openPermissions(seed: "created")
        defer { app.terminate() }
        attachScreenshot(of: app, named: "permissions-created")
        let status = statusText(in: app)
        XCTAssertFalse(status.contains(AppLanguage.text("Granted")), "a created source shown as a permission: “\(status)”")
        XCTAssertEqual(status, AppLanguage.text("Audio source created · %@", checkedAt))
        assertHeaderCountsOnlyPermissions(in: app)
    }

    func testUncheckedSourceIsNotCountedAsAMissingPermission() throws {
        let app = try openPermissions(seed: "none")
        defer { app.terminate() }
        attachScreenshot(of: app, named: "permissions-none")
        XCTAssertEqual(statusText(in: app), AppLanguage.text("Not checked"))
        assertHeaderCountsOnlyPermissions(in: app)
    }

    func testFailedSourceIsNotShownAsADeniedPermission() throws {
        let app = try openPermissions(seed: "failed")
        defer { app.terminate() }
        attachScreenshot(of: app, named: "permissions-failed")
        // Exactly the check's own failure, never a permission's "not granted".
        XCTAssertEqual(statusText(in: app), AppLanguage.text("Couldn’t create an audio source · %@", checkedAt))
        assertHeaderCountsOnlyPermissions(in: app)
    }

    // MARK: Helpers

    private func openPermissions(seed: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-SeedSystemAudioCheck", seed]
            + AppLanguage.launchArguments
        app.launch()
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "The Murmurly item did not appear in the menu bar")
        statusItem.click()
        let menuItems = statusItem.menus.firstMatch.children(matching: .menuItem)
        guard menuItems.count >= 3 else {
            XCTFail("The Murmurly menu has too few items")
            return app
        }
        menuItems.element(boundBy: menuItems.count - 3).click()
        guard app.settingsSidebarSearchIsEmpty() else { return app }
        let tab = app.buttons["settingsTab.permissions"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
        XCTAssertTrue(app.staticTexts["systemAudioCheckStatus"].waitForExistence(timeout: 5))
        return app
    }

    /// For a human check that the long footnote and the failed status are not
    /// cut off; kept with the result bundle, asserts nothing.
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func statusText(in app: XCUIApplication) -> String {
        let status = app.staticTexts["systemAudioCheckStatus"]
        return (status.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? status.label
    }

    /// "N not granted" / "Main permissions granted" must follow the microphone
    /// and Accessibility rows only; the system audio check is not a permission.
    private func assertHeaderCountsOnlyPermissions(
        in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let microphone = app.descendants(matching: .any)["microphonePermissionGranted"].exists
        let accessibility = app.descendants(matching: .any)["accessibilityPermissionGranted"].exists
        let missing = (microphone ? 0 : 1) + (accessibility ? 0 : 1)
        let expected = missing == 0
            ? AppLanguage.text("Main permissions granted") : AppLanguage.text("%lld not granted", missing)
        XCTAssertTrue(
            app.staticTexts[expected].waitForExistence(timeout: 5),
            "the header has no “\(expected)” — system audio was counted as a permission",
            file: file, line: line
        )
    }
}
