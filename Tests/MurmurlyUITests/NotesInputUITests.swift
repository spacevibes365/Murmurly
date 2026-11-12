import XCTest

/// Typing a note and pressing Return puts it in the feed; a double-click
/// edits it in place, taking the keyboard focus on its own — the same
/// pattern as the meeting title's own rename (`MeetingsView.swift`), so
/// typing right after the double-click, with no extra click on the field,
/// must already land there.
@MainActor
final class NotesInputUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-LiveTranscriptProbe"]
            + AppLanguage.launchArguments
        app.launch()
        return app
    }

    func testTypingANoteAndReturnShowsItInTheFeedThenDoubleClickEditsWithoutAnotherClick() throws {
        let app = launch()
        defer { app.terminate() }

        let state = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "the live-transcript panel did not appear")

        let field = app.textFields["notepadNoteField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the note field never appeared")
        field.click()
        field.typeText("Проверить меню снова\r")

        let note = app.staticTexts["notepadNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the note did not reach the feed")
        XCTAssertEqual(note.value as? String, "Проверить меню снова")

        note.doubleClick()
        let editField = app.textFields["notepadNoteEditField"]
        XCTAssertTrue(editField.waitForExistence(timeout: 5), "the double-click did not open editing")

        // Typed at once, with no other click: the field must already hold
        // the keyboard focus from the double-click alone — AppKit selects a
        // freshly focused field's whole text, so typing replaces it.
        app.typeText("правленая заметка\r")

        let edited = app.staticTexts["notepadNote"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        XCTAssertEqual(edited.value as? String, "правленая заметка")
    }
}
