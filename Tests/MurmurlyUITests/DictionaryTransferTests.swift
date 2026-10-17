import XCTest

/// Export… and Import… in the Dictionary section of the main window. With
/// the DEBUG file probe the tab's panels are answered by files in the probe's
/// root: the n-th import reads `dictionary-import-<n>.json` (none there is a
/// cancel) once the test opens its gate, and its panel answers at once unless
/// the test holds it (`.hold` until `.chosen`); the n-th export writes
/// `dictionary-export-<n>.json` once it opens that one. A test process never
/// opens a real panel. Nothing is read or written outside the root, and the
/// settings are the test copy's own.
@MainActor
final class DictionaryTransferTests: XCTestCase {
    private func entry(_ number: Int, _ heard: [String], _ written: String, enabled: Bool = true) -> [String: Any] {
        [
            "id": String(format: "00000000-0000-0000-0000-%012d", number),
            "heard": heard, "written": written, "enabled": enabled,
        ]
    }

    private lazy var claudeCode = entry(1, ["клод код"], "Claude Code")
    private lazy var github = entry(2, ["гитхаб"], "GitHub", enabled: false)
    private lazy var vscode = entry(3, ["вскод"], "VS Code")
    /// One of `claudeCode`'s spellings under another id.
    private lazy var claude = entry(4, ["Клод-Код"], "Claude")
    private lazy var zoom = entry(5, ["зум"], "Zoom")

    /// The empty dictionary takes the file as it is, without asking, and
    /// Export gives the same entries back.
    func testImportIntoAnEmptyDictionaryAsksNothingAndExportGivesItBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = [claudeCode, github]
        try offer(file, as: 1, in: root)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }

        let export = app.buttons["dictionaryExport"]
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertFalse(export.isEnabled, "an empty dictionary offers Export")
        XCTAssertTrue(importButton.isEnabled)
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 2))
        XCTAssertFalse(app.sheets.firstMatch.exists, "an empty dictionary was asked to add or replace")
        XCTAssertTrue(waitForEntries(2, in: app), "the entries did not show")
        XCTAssertEqual(row("Claude Code", in: app).flatMap(isOn), true)
        XCTAssertEqual(row("GitHub", in: app).flatMap(isOn), false, "the switched-off entry came in switched on")

        XCTAssertTrue(becomesEnabled(export), "Export stays off with entries")
        try release("dictionary-export-1", in: root)
        export.click()
        XCTAssertEqual(
            waitForNote(in: app),
            AppLanguage.text("Exported to “%@”. Entries: %lld.", "dictionary-export-1.json", 2)
        )
        let exported = try Data(contentsOf: root.appendingPathComponent("dictionary-export-1.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        XCTAssertEqual(document["entries"] as? NSArray, file as NSArray, "the exported entries are not the imported ones")
    }

    /// A filled dictionary is asked first: Cancel changes nothing, Add keeps
    /// what is there and switches off a spelling already taken, Replace takes
    /// the file as it is. Every file is a whole dictionary on its own: only
    /// the merge with yours may switch an entry off.
    func testImportIntoAFilledDictionaryAsksToAddOrReplace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode, github], as: 1, in: root)
        // github is yours as it is; claude has a spelling of your claudeCode.
        try offer([github, vscode, claude], as: 2, in: root)
        try offer([github, vscode, claude], as: 3, in: root)
        try offer([zoom], as: 4, in: root)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 2))
        XCTAssertTrue(waitForEntries(2, in: app))

        importButton.click()
        guard let cancel = question(AppLanguage.text("Cancel"), in: app) else { return }
        XCTAssertTrue(app.sheets.firstMatch.buttons[AppLanguage.text("Add to My Dictionary")].exists)
        XCTAssertTrue(app.sheets.firstMatch.buttons[AppLanguage.text("Replace My Dictionary")].exists)
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "the question stayed after Cancel")
        XCTAssertTrue(waitForEntries(2, in: app), "Cancel changed the dictionary")
        XCTAssertNil(row("VS Code", in: app), "Cancel took entries of the file")
        XCTAssertEqual(row("Claude Code", in: app).flatMap(isOn), true)
        XCTAssertEqual(row("GitHub", in: app).flatMap(isOn), false)
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "Cancel reported an import")
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after Cancel")

        importButton.click()
        guard let add = question(AppLanguage.text("Add to My Dictionary"), in: app) else { return }
        add.click()
        XCTAssertEqual(waitForNote(in: app), [
            AppLanguage.text("Added: %lld.", 2),
            AppLanguage.text("Switched off, as you already have their spelling: %lld.", 1),
            AppLanguage.text("Already in your dictionary: %lld.", 1),
        ].joined(separator: " "))
        XCTAssertTrue(waitForEntries(4, in: app), "Add did not leave yours and the two new ones")
        XCTAssertEqual(row("Claude Code", in: app).flatMap(isOn), true)
        XCTAssertEqual(row("GitHub", in: app).flatMap(isOn), false)
        XCTAssertEqual(row("VS Code", in: app).flatMap(isOn), true)
        XCTAssertEqual(row("Claude", in: app).flatMap(isOn), false, "a taken spelling came in switched on")

        importButton.click()
        guard let replace = question(AppLanguage.text("Replace My Dictionary"), in: app) else { return }
        replace.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Dictionary replaced. Entries: %lld.", 1))
        XCTAssertTrue(waitForEntries(1, in: app), "Replace kept entries of yours")
        XCTAssertNotNil(row("Zoom", in: app), "Replace did not take the file")
    }

    /// A file that is not a whole dictionary is refused with its reason, the
    /// dictionary stays, and the tab is free again; so after a cancel.
    func testRefusedFileImportsNothingAndSaysWhy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode], as: 1, in: root)
        try offer([vscode, entry(6, ["т.е."], "i.e.", enabled: false)], as: 2, in: root)
        try Data("not json".utf8).write(to: root.appendingPathComponent("dictionary-import-3.json"))
        try release("dictionary-import-3", in: root)
        // No dictionary-import-4.json: the panel is cancelled.
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))

        let refused = AppLanguage.text("Nothing was imported.")
        importButton.click()
        XCTAssertEqual(waitForError(in: app), refused + " " + AppLanguage.text(
            "Entry %lld: %@", 2,
            AppLanguage.text("“%@” may hold only letters, digits, spaces and hyphens.", "т.е.")
        ))
        XCTAssertFalse(app.sheets.firstMatch.exists, "a refused file was asked about")
        XCTAssertTrue(waitForEntries(1, in: app), "a refused file changed the dictionary")
        XCTAssertNil(row("VS Code", in: app), "the good entry of a refused file came in")
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after a refusal")

        importButton.click()
        XCTAssertEqual(waitForError(in: app), refused + " " + AppLanguage.text("This file is not a Murmurly dictionary."))

        importButton.click()
        XCTAssertTrue(
            app.staticTexts["dictionaryTransferError"].waitForNonExistence(timeout: 5),
            "a new import left the old outcome"
        )
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "a cancelled import reported something")
        XCTAssertTrue(waitForEntries(1, in: app))
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after a cancel")
    }

    /// An export holds both buttons from its panel to the end of its write,
    /// and lets them go when the write is done or has failed: a second write
    /// to the same file could otherwise land first and be overwritten by the
    /// older one.
    func testExportHoldsExportAndImportUntilItsWriteEnds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode], as: 1, in: root)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let export = app.buttons["dictionaryExport"]
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(becomesEnabled(export))

        export.click()
        guard waitForHeldWrite("dictionary-export-1", in: root) else { return }
        XCTAssertFalse(export.isEnabled, "Export is offered while the last export is still writing")
        XCTAssertFalse(importButton.isEnabled, "Import is offered while an export is still writing")
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "the export reported before its write ended")
        try release("dictionary-export-1", in: root)
        XCTAssertEqual(
            waitForNote(in: app),
            AppLanguage.text("Exported to “%@”. Entries: %lld.", "dictionary-export-1.json", 1)
        )
        XCTAssertTrue(becomesEnabled(export), "Export stayed off after the write")
        XCTAssertTrue(becomesEnabled(importButton), "Import stayed off after the write")

        export.click()
        guard waitForHeldWrite("dictionary-export-2", in: root) else { return }
        XCTAssertFalse(export.isEnabled, "Export is offered while the second export is still writing")
        XCTAssertFalse(importButton.isEnabled)
        try Data().write(to: root.appendingPathComponent("dictionary-export-2.fail"))
        let failed = waitForError(in: app) ?? ""
        let prefix = AppLanguage.text("Couldn’t export the dictionary: %@", "")
        XCTAssertTrue(failed.hasPrefix(prefix), "“\(failed)” does not say the export failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dictionary-export-2.json").path))
        XCTAssertTrue(becomesEnabled(export), "Export stayed off after a failed write")
        XCTAssertTrue(becomesEnabled(importButton), "Import stayed off after a failed write")
    }

    /// While the file is read nothing on the tab changes the dictionary; a
    /// tab changed meanwhile drops the import, so its late answer asks
    /// nothing, and a new import goes its own way and keeps its outcome.
    func testATabChangedWhileTheFileIsReadDropsItsAnswer() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode], as: 1, in: root)
        try offer([vscode], as: 2, in: root, held: true)
        try offer([zoom], as: 3, in: root)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(waitForEntries(1, in: app))
        guard let entry = row("Claude Code", in: app) else { return XCTFail("no entry to lock") }

        importButton.click()
        guard waitForProbe("dictionary-import-2.reading", in: root) else { return }
        for (control, name) in [
            (app.buttons["dictionaryAdd"], "Add…"),
            (app.buttons["dictionaryExport"], "Export…"),
            (importButton, "Import…"),
            (entry.checkBoxes.firstMatch, "the entry's switch"),
            (entry.buttons[AppLanguage.text("Edit…")], "Edit…"),
            (entry.buttons[AppLanguage.text("Delete")], "Delete"),
        ] {
            XCTAssertTrue(control.exists, "\(name) is not there")
            XCTAssertFalse(control.isEnabled, "\(name) is offered while the file is read")
        }

        guard app.transcribeAFileFromMenuBar() else { return }
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after the import was dropped")
        importButton.click()
        guard let add = question(AppLanguage.text("Add to My Dictionary"), in: app) else { return }
        add.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(waitForEntries(2, in: app))

        try release("dictionary-import-2", in: root)
        guard waitForProbe("dictionary-import-2.handled", in: root) else { return }
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1), "the dropped import asked after all")
        XCTAssertTrue(waitForEntries(2, in: app))
        XCTAssertNotNil(row("Zoom", in: app), "the new import's entry is gone")
        XCTAssertNil(row("VS Code", in: app), "the dropped import's entry came in")
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1), "the new import's outcome was replaced")
        XCTAssertFalse(app.staticTexts["dictionaryTransferError"].exists)
    }

    /// Into an empty dictionary a file is taken without asking, so a late
    /// answer of a dropped import would save it unseen.
    func testATabChangedWhileTheFileIsReadSavesNothingIntoAnEmptyDictionary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([vscode], as: 1, in: root, held: true)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        guard waitForProbe("dictionary-import-1.reading", in: root) else { return }
        XCTAssertFalse(app.buttons["dictionaryAdd"].isEnabled, "Add… is offered while the file is read")
        XCTAssertFalse(importButton.isEnabled, "Import… is offered while the file is read")

        guard app.transcribeAFileFromMenuBar() else { return }
        _ = app.showMainSection("dictionary")
        try release("dictionary-import-1", in: root)
        guard waitForProbe("dictionary-import-1.handled", in: root) else { return }
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1), "the dropped import asked after all")
        XCTAssertTrue(waitForEntries(0, in: app), "the dropped import was saved")
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "the dropped import reported an outcome")
        XCTAssertFalse(app.staticTexts["dictionaryTransferError"].exists)
        XCTAssertTrue(becomesEnabled(importButton))
    }

    /// Neither is offered until the unreadable dictionary is cleared.
    func testUnreadableDictionaryOffersNeitherExportNorImport() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a dictionary document: the store reads the key as damaged.
        let app = launch(root: root, extra: ["-dictionary.entries", "damaged"])
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        XCTAssertTrue(app.buttons["dictionaryClear"].waitForExistence(timeout: 5), "the dictionary passed for readable")
        XCTAssertFalse(app.buttons["dictionaryExport"].isEnabled, "Export is offered")
        XCTAssertFalse(app.buttons["dictionaryImport"].isEnabled, "Import is offered")
        XCTAssertFalse(app.buttons["dictionaryAdd"].isEnabled, "Add… is offered")
    }

    /// A question already shown stays through a tab changed from the menu
    /// bar, the app goes on running, and the answer counts as it would on the
    /// Dictionary tab. Taking the question away there crashed the app: SwiftUI
    /// closed the alert's sheet inside the layout of the switched tab.
    func testAQuestionShownStaysThroughATabChangeAndItsAnswerCounts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode], as: 1, in: root)
        try offer([vscode], as: 2, in: root)
        try offer([zoom], as: 3, in: root)
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))

        importButton.click()
        guard let add = question(AppLanguage.text("Add to My Dictionary"), in: app) else { return }
        guard app.transcribeAFileFromMenuBar() else { return }
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the tab change")
        XCTAssertFalse(add.waitForNonExistence(timeout: 1), "the question went away with the tab")
        add.click()
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "the question stayed after Add")
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(waitForEntries(2, in: app), "the answer given over Files did not count")
        XCTAssertNotNil(row("VS Code", in: app))
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after the answer")

        importButton.click()
        guard let cancel = question(AppLanguage.text("Cancel"), in: app) else { return }
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForEntries(2, in: app), "Cancel changed the dictionary")
        XCTAssertTrue(becomesEnabled(importButton))
    }

    /// The entry sheet stays over a tab changed from the menu bar, with its
    /// draft, until it is answered there: Cancel saves nothing and the next
    /// sheet starts empty, Save over Files saves the entry. The same check in
    /// `HistoryProbeTests` starts from a history row's context menu; here it
    /// needs no row, so it runs whatever happens to that click.
    func testATabChangedFromTheMenuBarKeepsTheEntrySheet() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let add = app.buttons["dictionaryAdd"]
        let heard = app.textFields["dictionaryHeardField"]
        let written = app.textFields["dictionaryWrittenField"]
        add.click()
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "Add… opened no sheet")
        heard.click()
        // Digits only: they do not depend on the active keyboard layout.
        heard.typeText("42")
        guard app.transcribeAFileFromMenuBar(), staysUp(heard, "the sheet", in: app) else { return }
        XCTAssertEqual(heard.value as? String, "42", "the draft changed with the tab")
        app.buttons["dictionaryCancel"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet stayed after Cancel")
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(waitForEntries(0, in: app), "Cancel saved the draft")

        add.click()
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "Add… opened no sheet")
        XCTAssertEqual(heard.value as? String ?? "", "", "the draft came back")
        XCTAssertEqual(written.value as? String ?? "", "", "the draft came back")
        heard.click()
        heard.typeText("42")
        written.click()
        written.typeText("77")
        guard app.transcribeAFileFromMenuBar(), staysUp(heard, "the sheet", in: app) else { return }
        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet stayed after Save")
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(waitForEntries(1, in: app), "Save over Files did not save the entry")
        XCTAssertNotNil(row("77", in: app), "the saved entry is not the draft")
    }

    /// The panels stay through a tab changed from the menu bar until they
    /// come and are answered, on the tab's window: Export then writes the
    /// very entry to its file, an Import nobody chose a file for changes
    /// nothing. Closing a panel on the change crashed the app: its close
    /// animation ran inside the layout of the switched tab. The panels are
    /// the probe's: whether AppKit attaches a real one is checked by hand.
    func testPanelsStayThroughATabChangeOnTheirWindow() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        // Digits only: they do not depend on the active keyboard layout.
        app.buttons["dictionaryAdd"].click()
        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "Add… opened no sheet")
        heard.click()
        heard.typeText("42")
        app.textFields["dictionaryWrittenField"].click()
        app.textFields["dictionaryWrittenField"].typeText("77")
        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet did not close after Save")
        XCTAssertTrue(waitForEntries(1, in: app))
        try Data().write(to: root.appendingPathComponent("present.hold"))
        try release("dictionary-export-1", in: root)

        let export = app.buttons["dictionaryExport"]
        export.click()
        guard waitForProbe("present-1.holding", in: root), app.transcribeAFileFromMenuBar() else { return }
        try release("present-1", in: root)
        XCTAssertTrue(owner(1, in: root).hasPrefix("main"), "the export's panel went elsewhere: \(owner(1, in: root))")
        _ = app.showMainSection("dictionary")
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Exported to “%@”. Entries: %lld.", "dictionary-export-1.json", 1))
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("dictionary-export-1.json"))) as? [String: Any]
        let written = (document?["entries"] as? [[String: Any]])?.first
        XCTAssertEqual(written?["heard"] as? [String], ["42"])
        XCTAssertEqual(written?["written"] as? String, "77")
        XCTAssertTrue(becomesEnabled(export), "Export stayed off after the write")

        let importButton = app.buttons["dictionaryImport"]
        importButton.click()
        guard waitForProbe("present-2.holding", in: root), app.transcribeAFileFromMenuBar() else { return }
        try release("present-2", in: root)
        XCTAssertTrue(owner(2, in: root).hasPrefix("main"), "the import's panel went elsewhere: \(owner(2, in: root))")
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after a panel nobody chose in")
        XCTAssertTrue(waitForEntries(1, in: app))
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "a cancelled panel reported something")
        XCTAssertFalse(app.staticTexts["dictionaryTransferError"].exists)
    }

    /// A panel held between the click and its coming, its window closed
    /// meanwhile, comes nowhere: Export writes nothing and Import reads
    /// nothing, and the section, opened again, offers both again.
    func testAHeldPanelComesNowhereWithItsWindow() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([vscode], as: 1, in: root)
        let mine = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [claudeCode]])
        let app = launch(root: root, extra: ["-dictionary.entries", "<" + mine.map { String(format: "%02x", $0) }.joined() + ">"])
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        XCTAssertTrue(waitForEntries(1, in: app))
        try Data().write(to: root.appendingPathComponent("present.hold"))
        let main = app.windows["main"]

        app.buttons["dictionaryExport"].click()
        guard waitForProbe("present-1.holding", in: root) else { return }
        main.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(main.waitForNonExistence(timeout: 5), "the window stayed")
        try release("present-1", in: root)
        XCTAssertEqual(owner(1, in: root), "cancelled", "the export's panel came for a window that was gone")
        guard openDictionary(in: app) else { return }
        XCTAssertTrue(becomesEnabled(app.buttons["dictionaryExport"]), "Export stayed off after a panel that never came")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dictionary-export-1.json").path))
        XCTAssertFalse(app.staticTexts["dictionaryTransferNote"].exists, "a panel that never came reported something")

        app.buttons["dictionaryImport"].click()
        guard waitForProbe("present-2.holding", in: root) else { return }
        main.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(main.waitForNonExistence(timeout: 5), "the window stayed")
        try release("present-2", in: root)
        XCTAssertEqual(owner(2, in: root), "cancelled", "the import's panel came for a window that was gone")
        guard openDictionary(in: app) else { return }
        XCTAssertTrue(becomesEnabled(app.buttons["dictionaryImport"]), "Import stayed off after a panel that never came")
        XCTAssertTrue(app.buttons["dictionaryAdd"].isEnabled, "the section stayed locked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dictionary-import-1.reading").path),
                       "the import read a file nobody chose")
        XCTAssertTrue(waitForEntries(1, in: app), "the entries changed")
    }

    /// An import's panel answered after a tab changed from the menu bar
    /// counts: the file is read, asked about over Files, and the answer
    /// applies. Only a file already being read is dropped by the change.
    func testAPanelAnsweredAfterATabChangeStillImports() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try offer([claudeCode], as: 1, in: root)
        try offer([vscode], as: 2, in: root)
        try Data().write(to: root.appendingPathComponent("dictionary-import-2.hold"))
        let app = launch(root: root)
        defer { app.terminate() }
        guard openDictionary(in: app) else { return }
        let importButton = app.buttons["dictionaryImport"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.click()
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(waitForEntries(1, in: app))

        importButton.click()
        guard waitForProbe("dictionary-import-2.choosing", in: root) else { return }
        XCTAssertFalse(importButton.isEnabled, "Import… is offered while its panel is up")
        XCTAssertFalse(app.buttons["dictionaryAdd"].isEnabled, "Add… is offered while the panel is up")
        guard app.transcribeAFileFromMenuBar() else { return }
        // The panel answers well after the change has gone through the tab.
        Thread.sleep(forTimeInterval: 1)
        try Data().write(to: root.appendingPathComponent("dictionary-import-2.chosen"))
        guard let add = question(AppLanguage.text("Add to My Dictionary"), in: app) else { return }
        XCTAssertTrue(app.descendants(matching: .any)["mainContent.files"].exists, "the question was not over Files")
        add.click()
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "the question stayed after Add")
        _ = app.showMainSection("dictionary")
        XCTAssertTrue(waitForEntries(2, in: app), "the answer given after the tab change did not count")
        XCTAssertNotNil(row("VS Code", in: app), "the chosen file's entry did not come in")
        XCTAssertEqual(waitForNote(in: app), AppLanguage.text("Added: %lld.", 1))
        XCTAssertTrue(becomesEnabled(importButton), "the tab stayed locked after the answer")
    }

    // MARK: Helpers

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func launch(root: URL, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-FileProbeRoot", root.path]
            + extra + AppLanguage.launchArguments
        app.launch()
        return app
    }

    /// Opens the gate of the import read or export write named so.
    private func release(_ name: String, in root: URL) throws {
        try Data().write(to: root.appendingPathComponent("\(name).release"))
    }

    /// The window the n-th panel went on, by its identifier, or "cancelled".
    private func owner(_ number: Int, in root: URL) -> String {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let owner = try? String(contentsOf: root.appendingPathComponent("present-\(number).owner"), encoding: .utf8) {
                return owner
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("present-\(number).cancelled").path) {
                return "cancelled"
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return "<not said>"
    }

    /// True once the probe wrote that acknowledgement; false, after failing
    /// the test as inconclusive, when it never did.
    private func waitForProbe(_ marker: String, in root: URL) -> Bool {
        let url = root.appendingPathComponent(marker)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("the probe never wrote \(marker) — the check proves nothing")
            return false
        }
        return true
    }

    private func waitForHeldWrite(_ export: String, in root: URL) -> Bool {
        waitForProbe("\(export).writing", in: root)
    }

    /// The file the n-th import reads, its gate open unless `held`.
    private func offer(_ entries: [[String: Any]], as number: Int, in root: URL, held: Bool = false) throws {
        let document: [String: Any] = ["version": 1, "entries": entries]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: root.appendingPathComponent("dictionary-import-\(number).json"))
        if !held { try release("dictionary-import-\(number)", in: root) }
    }

    /// Opens Settings from the menu bar on the Dictionary tab; false, after
    /// failing the test, when it did not show.
    /// The main window on its Dictionary section.
    private func openDictionary(in app: XCUIApplication) -> Bool {
        app.openMainSection("dictionary")
    }

    /// True when the panel is still on the window two seconds after the tab
    /// changed, long enough for the change to have gone through the tab it
    /// left; false, after failing the test, when it went away.
    private func staysUp(_ panel: XCUIElement, _ what: String, in app: XCUIApplication) -> Bool {
        let gone = panel.waitForNonExistence(timeout: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the tab change")
        guard !gone else {
            XCTFail("\(what) went away with the tab")
            return false
        }
        return true
    }

    /// A button of the import's question; nil, after failing the test, when
    /// nothing asked.
    private func question(_ button: String, in app: XCUIApplication) -> XCUIElement? {
        let choice = app.sheets.firstMatch.buttons[button]
        guard choice.waitForExistence(timeout: 5) else {
            XCTFail("the import did not ask, or its question has no “\(button)”")
            return nil
        }
        return choice
    }

    private func becomesEnabled(_ element: XCUIElement) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: 5) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// The outcome under the buttons, once it shows.
    private func waitForNote(in app: XCUIApplication) -> String? {
        let note = app.staticTexts["dictionaryTransferNote"]
        return note.waitForExistence(timeout: 5) ? text(of: note) : nil
    }

    private func waitForError(in app: XCUIApplication) -> String? {
        let error = app.staticTexts["dictionaryTransferError"]
        return error.waitForExistence(timeout: 5) ? text(of: error) : nil
    }

    private func entries(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "dictionaryEntry")
    }

    private func waitForEntries(_ count: Int, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while entries(in: app).count != count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return entries(in: app).count == count
    }

    /// The row whose entry is written so.
    private func row(_ written: String, in app: XCUIApplication) -> XCUIElement? {
        let rows = entries(in: app)
        return (0..<rows.count).lazy.map { rows.element(boundBy: $0) }.first { $0.staticTexts[written].exists }
    }

    private func isOn(_ row: XCUIElement) -> Bool? {
        switch row.checkBoxes.firstMatch.value {
        case let number as NSNumber: number.boolValue
        case let text as String: text == "1"
        default: nil
        }
    }
}
