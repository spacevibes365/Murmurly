import CoreGraphics
import XCTest

/// `⌘F` shows the notepad's search bar, typing fills in the counter and
/// `⌘G` steps to the next match, Esc hides it again. Needs the notepad to be
/// key: a click in its note field makes it key, as a click anywhere on it
/// does.
@MainActor
final class NotepadSearchUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-LiveTranscriptProbe"]
            + AppLanguage.launchArguments
        app.launch()
        return app
    }

    /// What the key at this physical place types in the active layout, as
    /// `MeetingsWindowTests.physicalCharacter(of:)`.
    private func physicalCharacter(of virtualKey: CGKeyCode) -> String? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) else { return nil }
        var count = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: count)
    }

    func testCommandFShowsSearchCountsAndEscapeHides() throws {
        let keys = (physicalCharacter(of: 3), physicalCharacter(of: 5))  // kVK_ANSI_F, kVK_ANSI_G
        try XCTSkipUnless(keys == ("f", "g"), "⌘F and ⌘G through typeKey depend on the keyboard layout: the physical keys give \(String(describing: keys))")

        let app = launch()
        defer { app.terminate() }

        let state = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the live-transcript panel did not appear")
        app.textFields["notepadNoteField"].click()

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["notepadSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not show the search field")

        field.typeText("the")
        let count = app.staticTexts["notepadSearchCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "1/3")

        app.typeKey("g", modifierFlags: .command)
        XCTAssertEqual(count.value as? String, "2/3")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc did not hide the search field")
    }
}
