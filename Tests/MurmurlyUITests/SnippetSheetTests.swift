import XCTest

/// Adding a snippet from the Dictionary section: the kind picker, the
/// multi-line "Text" field, the row's mark, and that editing and re-saving
/// the entry keep its kind, its text byte for byte (blank lines and the
/// edges included) and the dictionary document's version 2. Typed text is
/// digits only, so the active keyboard layout never matters (see CLAUDE.md,
/// Traps).
@MainActor
final class SnippetSheetTests: XCTestCase {
    func testSnippetIsAddedFromTheDictionarySection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        guard app.openMainSection("dictionary") else { return }

        app.buttons["dictionaryAdd"].click()
        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "Add… opened no sheet")

        let picker = app.descendants(matching: .any)["dictionaryKindPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "a new entry's sheet has no kind picker")
        let snippetSegment = app.radioButtons[AppLanguage.text("Snippet")]
        XCTAssertTrue(snippetSegment.waitForExistence(timeout: 5), "no Snippet segment in the kind picker")
        snippetSegment.click()

        let text = app.textViews["dictionarySnippetTextField"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "choosing Snippet did not show the Text field")
        XCTAssertFalse(app.textFields["dictionaryWrittenField"].exists, "a snippet still shows the replacement's Write as")

        heard.click()
        heard.typeText("12 34")
        text.click()
        // A blank line, the chosen one and another, with a leading and a
        // trailing blank line of their own: the draft must keep this exactly.
        text.typeText(" \n56\n78\n ")

        // Switching the kind back and forth must not pour this snippet text
        // into the replacement's single-line field, or lose it there.
        let replacementSegment = app.radioButtons[AppLanguage.text("Replacement")]
        XCTAssertTrue(replacementSegment.waitForExistence(timeout: 5), "no Replacement segment in the kind picker")
        replacementSegment.click()
        let writtenField = app.textFields["dictionaryWrittenField"]
        XCTAssertTrue(writtenField.waitForExistence(timeout: 5), "switching to Replacement did not show Write as")
        writtenField.click()
        writtenField.typeText("99")
        snippetSegment.click()
        XCTAssertTrue(text.waitForExistence(timeout: 5), "switching back to Snippet did not show the Text field")
        XCTAssertEqual(
            text.value as? String, " \n56\n78\n ",
            "switching kinds lost the snippet's own text"
        )
        XCTAssertFalse(app.textFields["dictionaryWrittenField"].exists, "a snippet still shows the replacement's Write as")

        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet did not close after Save")

        let mark = app.descendants(matching: .any)["dictionarySnippetMark"].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "the snippet's row has no mark")
        guard let row = entryRow(in: app) else { return }
        XCTAssertTrue(row.staticTexts["12 34"].exists, "the row does not show the spoken phrase")
        XCTAssertTrue(row.staticTexts["56"].exists, "the row does not show the text's first non-empty line")

        // Edit…: the picker shows Snippet and cannot be changed, and both
        // fields come back exactly as saved.
        row.buttons[AppLanguage.text("Edit…")].click()
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "Edit… opened no sheet")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no kind picker when editing a snippet")
        XCTAssertFalse(picker.isEnabled, "the kind can still be changed while editing")
        // A disabled segment's `isSelected` is not reliable on macOS; its raw
        // AX value still is.
        XCTAssertEqual(stringValue(of: snippetSegment), "1", "editing did not keep Snippet selected")
        XCTAssertFalse(app.textFields["dictionaryWrittenField"].exists, "editing a snippet shows the replacement's Write as")
        XCTAssertEqual(heard.value as? String, "12 34")
        XCTAssertEqual(text.value as? String, " \n56\n78\n ", "editing lost the exact text")

        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet did not close after the second Save")
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "the row lost its mark after editing")

        // Export…, to check the saved document itself: the entry's kind, its
        // text byte for byte, and the document's version.
        try release("dictionary-export-1", in: root)
        app.buttons["dictionaryExport"].click()
        let note = app.staticTexts["dictionaryTransferNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the export did not report its outcome")

        let exported = try Data(contentsOf: root.appendingPathComponent("dictionary-export-1.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 2, "a dictionary with a snippet must be version 2")
        let entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1, "saving the entry twice must not create a second one")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["kind"] as? String, "snippet", "editing turned the snippet into a replacement")
        XCTAssertEqual(entry["heard"] as? [String], ["12 34"])
        XCTAssertEqual(entry["written"] as? String, " \n56\n78\n ", "the saved text is not exactly what was typed")
        XCTAssertEqual(entry["enabled"] as? Bool, true, "a newly added snippet must be enabled")
    }

    // MARK: Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-sheet-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func launch(root: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-FileProbeRoot", root.path] + AppLanguage.launchArguments
        app.launch()
        return app
    }

    /// Opens the export's write gate.
    private func release(_ name: String, in root: URL) throws {
        try Data().write(to: root.appendingPathComponent("\(name).release"))
    }

    /// The one row in the entries list; nil, after failing the test, when
    /// there isn't one.
    /// A radio button's AX value, coerced from whatever type it comes as.
    private func stringValue(of element: XCUIElement) -> String? {
        switch element.value {
        case let number as NSNumber: number.stringValue
        case let string as String: string
        default: nil
        }
    }

    private func entryRow(in app: XCUIApplication) -> XCUIElement? {
        let row = app.descendants(matching: .any).matching(identifier: "dictionaryEntry").firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no entry row in the dictionary list")
            return nil
        }
        return row
    }
}
