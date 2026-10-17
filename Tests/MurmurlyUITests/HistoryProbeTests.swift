import AppKit
import XCTest

/// The history list in the main window's Dictations section. The app's DEBUG history
/// probe appends dictations through the shared store on request; it has no
/// refresh logic, and the same probe is applied to the tree before the fix.
@MainActor
final class HistoryProbeTests: XCTestCase {
    func testOpenHistoryShowsDictationSavedWhileOpen() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        // Both initial reads (list and statistics) finished before the append,
        // so it cannot slip into them and pass without a subscription.
        try openHistory(in: app, expectedCount: (0, 0), visibleText: "historyEmpty")

        let text = "probe appended \(UUID().uuidString.prefix(8))"
        guard requestAppend(text: text, root: root) else { return }

        // Same window, same (empty) search: the change must show up by itself.
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5), "new dictation not shown")
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "count not refreshed")
    }

    func testOpenHistoryKeepsItsFilterWhileArchiveChanges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        // One non-matching entry before the window opens makes the end of the
        // filtered read observable: the row goes away and the count says 0 of 1.
        let seed = "probe seed"
        guard requestAppend(text: seed, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: seed)
        let search = app.textFields["historySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        // Digits only: they do not depend on the active keyboard layout.
        search.typeText("4242")
        XCTAssertEqual(search.value as? String, "4242")
        XCTAssertTrue(app.staticTexts[seed].waitForNonExistence(timeout: 5), "filter not applied")
        XCTAssertTrue(waitForCount(in: app, 0, of: 1), "filtered count not settled")

        let matching = "probe 4242 match"
        guard requestAppend(text: matching, root: root) else { return }
        XCTAssertTrue(app.staticTexts[matching].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForCount(in: app, 1, of: 2))

        // One that does not match, then one that does: the list shows the
        // second only from a read made after both, so what it leaves out is
        // what that read filtered. The total comes first, from a count of its
        // own, while the list may still be the old one or being read again.
        let other = "probe other"
        guard requestAppend(text: other, root: root) else { return }
        XCTAssertTrue(waitForCount(in: app, 1, of: 3), "total not refreshed")
        let again = "probe 4242 again"
        guard requestAppend(text: again, root: root) else { return }
        XCTAssertTrue(app.staticTexts[again].waitForExistence(timeout: 5), "the list was not read again")
        XCTAssertTrue(waitForCount(in: app, 2, of: 4))
        XCTAssertFalse(app.staticTexts[other].exists, "the filter was dropped on refresh")
        XCTAssertFalse(app.staticTexts[seed].exists, "the filter was dropped on refresh")
        XCTAssertTrue(app.staticTexts[matching].exists)
        XCTAssertEqual(search.value as? String, "4242")
    }

    /// Dictations and Storage, open together in their two windows, count
    /// the archive each its own way and both follow every change: a new
    /// dictation, a deletion, a clear, and a clear that failed after it
    /// emptied the index, as the audio could not be removed: no lines, the
    /// audio left still counted and Clear All still on, until a repeat
    /// clears it. Dictations counts with Settings never opened.
    func testBothWindowsSeeEveryChangeOfTheArchive() throws {
        let root = try makeRoot()
        let month = root.appendingPathComponent("2026/10", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: month.path)
            try? FileManager.default.removeItem(at: root)
        }
        let app = launch(root: root)
        defer { app.terminate() }
        guard app.openMainSection("dictations") else { return }
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "Dictations did not count with Settings never opened")
        guard openSettings(in: app) else { return }
        app.windows["settings"].buttons["settingsTab.storage"].click()
        XCTAssertTrue(waitForStorage(dictations: 0, in: app), "Storage did not count")
        let empty = storageLine(in: app)

        let text = "probe 7171"
        guard requestAppend(text: text, root: root) else { return }
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "Dictations missed the new dictation")
        XCTAssertTrue(waitForStorage(dictations: 1, in: app), "Storage missed the new dictation")

        let main = app.windows["main"]
        main.descendants(matching: .any)["mainSection.dictations"].click()
        main.staticTexts[text].rightClick()
        app.menuItems[AppLanguage.text("Delete…")].click()
        app.sheets.firstMatch.buttons[AppLanguage.text("Delete")].click()
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "Dictations missed the deletion")
        XCTAssertTrue(waitForStorage(dictations: 0, in: app), "Storage missed the deletion")

        let clear = main.buttons["clearHistoryButton"]
        func clearAll() {
            clear.click()
            app.sheets.firstMatch.buttons[AppLanguage.text("Clear All")].click()
        }
        guard requestAppend(text: "probe 7272", root: root) else { return }
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "Dictations missed the dictation to clear")
        XCTAssertTrue(waitForStorage(dictations: 1, in: app), "Storage missed the dictation to clear")
        clearAll()
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "Dictations missed the clear")
        XCTAssertTrue(waitForStorage(dictations: 0, in: app), "Storage missed the clear")

        // A dictation's audio in a month folder whose entries can't be
        // removed: the clear empties the index, then fails on the audio.
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let audio = month.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        try Data(repeating: 1, count: 64 * 1024).write(to: audio)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: month.path)
        guard requestAppend(text: "probe 7373", root: root) else { return }
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "Dictations missed the dictation to clear")
        XCTAssertTrue(waitForStorage(dictations: 1, in: app), "Storage missed the dictation to clear")
        clearAll()
        let ok = app.sheets.firstMatch.buttons[AppLanguage.text("OK")]
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "the clear that failed said nothing")
        ok.click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "the audio went — the check proves nothing")
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "Dictations missed the emptied index")
        XCTAssertTrue(waitForStorage(dictations: 0, in: app), "Storage missed the emptied index")
        XCTAssertNotEqual(storageLine(in: app), empty, "Storage does not count the audio left")
        XCTAssertTrue(waitUntil { clear.isEnabled }, "Clear All is off with the audio left")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: month.path)
        clearAll()
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: audio.path) }, "the repeat left the audio")
        XCTAssertTrue(waitUntil { storageLine(in: app) == empty }, "Storage still counts the audio: \(storageLine(in: app) ?? "")")
        XCTAssertTrue(waitUntil { !clear.isEnabled }, "Clear All is on with nothing to clear")
        XCTAssertFalse(app.sheets.firstMatch.exists, "the repeat failed")
    }

    /// Storage's legend line for dictations ends with their count.
    private func waitForStorage(dictations count: Int, in app: XCUIApplication) -> Bool {
        waitUntil(seconds: 10) { storageLine(in: app)?.hasSuffix(" · \(count)") == true }
    }

    /// Storage's legend line for dictations: their size and count.
    private func storageLine(in app: XCUIApplication) -> String? {
        let prefix = AppLanguage.text("Dictations") + " · "
        let line = app.windows["settings"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)).firstMatch
        guard line.exists else { return nil }
        return (line.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? line.label
    }

    private func waitUntil(seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// №9: a count that failed says so and can be repeated, instead of
    /// "Counting…" for ever. A folder where `history.jsonl` belongs makes every
    /// read of the history fail; once it is gone, Try Again counts again.
    func testStorageSaysTheCountFailedAndCountsAgainOnRetry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let app = launch(root: root)
        defer { app.terminate() }
        // Settings alone: the history is the main window's, never opened here.
        guard openSettings(in: app) else { return }
        let storageTab = app.buttons["settingsTab.storage"]
        XCTAssertTrue(storageTab.waitForExistence(timeout: 5))
        storageTab.click()
        // Only the selected tab is exposed: without this, a click lost to
        // another window would pass the "Counting…" check below.
        XCTAssertTrue(app.buttons["meetingsFolderChoose"].waitForExistence(timeout: 5), "Storage did not open")

        let retry = app.buttons["storageRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "a failed count offers no retry")
        let counting = app.staticTexts[AppLanguage.text("Counting…")]
        XCTAssertTrue(counting.waitForNonExistence(timeout: 5), "still “Counting…” after the count failed")

        try FileManager.default.removeItem(at: history)
        retry.click()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5), "Try Again did not count again")
    }

    /// A history that cannot be read is reported in Dictations, not as a
    /// sheet over whatever section the window opens on: every section is
    /// built at once, so the read runs and fails with the window, whichever
    /// is shown. In Dictations it is a line with Try Again, not a sheet.
    func testUnreadableHistoryIsReportedOnlyInHistory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let app = launch(root: root)
        defer { app.terminate() }
        guard app.openMainSection("meetings") else { return }
        // Only the shown section is in the accessibility tree.
        XCTAssertFalse(
            app.descendants(matching: .any)["mainContent.dictations"].exists,
            "the window opened on Dictations — the check proves nothing"
        )

        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 3), "the history error covers another section")

        guard app.showMainSection("dictations") else { return }
        // Said in the section itself, with Try Again; no sheet anywhere.
        XCTAssertTrue(app.buttons["historyRetry"].waitForExistence(timeout: 5), "History does not report the error")
        XCTAssertFalse(app.sheets.firstMatch.exists, "the read error came as a sheet")
    }

    /// An archive with no dictations says so: "Nothing found — Try another
    /// search" is for a search that matched nothing.
    func testEmptyHistorySaysThereAreNoDictations() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        guard app.openMainSection("dictations") else { return }
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "history did not settle")

        XCTAssertTrue(
            app.staticTexts[AppLanguage.text("No dictations yet")].waitForExistence(timeout: 5),
            "an empty archive is not called empty"
        )
        XCTAssertFalse(
            app.staticTexts[AppLanguage.text("Try another search")].exists,
            "an empty archive is told to search again"
        )
    }

    /// Audio left in the archive by a clear that failed halfway
    /// keeps Clear All available, and repeating it removes the rest.
    func testClearAllStaysAvailableWhileAudioIsLeft() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Named as the archive names its audio: only such files are its own.
        let leftover = root.appendingPathComponent("2026/10/\(UUID().uuidString.lowercased()).caf")
        try FileManager.default.createDirectory(
            at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 4_096).write(to: leftover)
        let app = launch(root: root)
        defer { app.terminate() }
        try openHistory(in: app, expectedCount: (0, 0), visibleText: "historyEmpty")

        // With an empty list the toolbar's trash is the tab's only button.
        let clear = app.descendants(matching: .any)["mainContent.dictations"].buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.isEnabled, "Clear All is off while audio is still in the archive")
        clear.click()
        let confirm = app.sheets.firstMatch.buttons[AppLanguage.text("Clear All")]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: leftover.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "the repeat left the audio")
    }

    /// With nothing to clear, the trash looked as available as ever and a
    /// click did nothing. Off, its icon stands out from the background
    /// clearly less than on.
    func testTrashLooksOffWhenThereIsNothingToClear() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        try openHistory(in: app, expectedCount: (0, 0), visibleText: "historyEmpty")
        // With an empty list the toolbar's trash is the tab's only button,
        // and it stays the first one once a dictation is listed below it.
        let clear = app.descendants(matching: .any)["mainContent.dictations"].buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertFalse(clear.isEnabled, "the trash is on with nothing to clear")
        let place = clear.frame
        let off = try XCTUnwrap(iconContrast(of: clear))

        guard requestAppend(text: "probe 4242", root: root) else { return }
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "count did not settle")
        let deadline = Date().addingTimeInterval(5)
        while !clear.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(clear.isEnabled, "the trash stays off with a dictation to clear")
        XCTAssertEqual(clear.frame, place, "another button was measured — the check proves nothing")
        let on = try XCTUnwrap(iconContrast(of: clear))

        XCTAssertLessThan(off, on * 0.8, "the trash looks the same off (\(off)) as on (\(on))")
    }

    /// A history that cannot be read says so in History with a
    /// way to read it again, instead of "Counting…" for ever over an empty list.
    func testUnreadableHistoryShowsTheErrorAndReadsAgain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let app = launch(root: root)
        defer { app.terminate() }
        guard app.openMainSection("dictations") else { return }
        // Older builds report the read error in a sheet; Return closes it.
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 3) {
            app.activate()
            app.typeKey(.return, modifierFlags: [])
            _ = sheet.waitForNonExistence(timeout: 5)
        }

        let count = app.staticTexts["historyResultCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let counting = AppLanguage.text("Counting…")
        let deadline = Date().addingTimeInterval(5)
        while text(of: count) == counting, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertNotEqual(text(of: count), counting, "History still says “Counting…” after the count failed")
        let retry = app.buttons["historyRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no way to read the history again")

        try FileManager.default.removeItem(at: history)
        retry.click()
        XCTAssertTrue(app.staticTexts["historyEmpty"].waitForExistence(timeout: 5), "the repeat did not read")
        XCTAssertTrue(waitForCount(in: app, 0, of: 0), "the repeat did not count")
    }

    /// With a search typed and the total already counted, a
    /// count that fails says so in the tab: no sheet, no "Counting…" for
    /// ever, and Try Again counts again once the history can be read.
    func testFailedSearchCountSaysSoAndCountsAgain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let seed = "probe seed"
        guard requestAppend(text: seed, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: seed)
        let search = app.textFields["historySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        // Digits only: they do not depend on the active keyboard layout.
        search.typeText("4242")
        XCTAssertTrue(waitForCount(in: app, 0, of: 1), "filtered count not settled")

        // The index becomes unreadable under the open window; the total
        // counted before stays.
        let history = root.appendingPathComponent("history.jsonl")
        let kept = root.appendingPathComponent("history.kept")
        try FileManager.default.moveItem(at: history, to: kept)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        search.typeText("1")

        let count = app.staticTexts["historyResultCount"]
        let counting = AppLanguage.text("Counting…")
        let deadline = Date().addingTimeInterval(5)
        while text(of: count) == counting || text(of: count).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotEqual(text(of: count), counting, "the search count still says “Counting…” after it failed")
        XCTAssertFalse(app.sheets.firstMatch.exists, "the count failure came as a sheet")
        let retry = app.buttons["historyRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no way to count again")

        try FileManager.default.removeItem(at: history)
        try FileManager.default.moveItem(at: kept, to: history)
        retry.click()
        XCTAssertTrue(waitForCount(in: app, 0, of: 1), "Try Again did not count again")
    }

    /// A row's actions showed only under the mouse. Its context menu reaches
    /// them without hovering, and Delete there asks first like the row's
    /// trash: Cancel keeps the dictation.
    func testRowContextMenuDeleteAsksFirstAndCancelKeepsTheDictation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let seed = "probe context menu"
        guard requestAppend(text: seed, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: seed)

        app.staticTexts[seed].rightClick()
        let delete = app.menuItems[AppLanguage.text("Delete…")]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row has no context menu with Delete…")
        XCTAssertTrue(app.menuItems[AppLanguage.text("Copy Text")].exists, "a row with text offers no Copy Text")
        delete.click()
        let cancel = app.sheets.firstMatch.buttons[AppLanguage.text("Cancel")]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Delete… did not ask first")
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "the question stayed")
        XCTAssertTrue(app.staticTexts[seed].exists, "Cancel did not keep the dictation")
        XCTAssertTrue(waitForCount(in: app, 1, of: 1), "the count changed after Cancel")
    }

    /// The same search is counted again after a change
    /// of the archive, and that count fails: the number from the count before
    /// does not stay beside the error.
    func testFailedRecountOfTheSameSearchDropsTheEarlierNumber() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let seed = "probe 4242"
        guard requestAppend(text: seed, root: root), requestAppend(text: "probe 1717", root: root) else { return }
        try openHistory(in: app, expectedCount: (2, 2), visibleText: seed)
        let search = app.textFields["historySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        // Digits only: they do not depend on the active keyboard layout.
        search.typeText("4242")
        XCTAssertTrue(waitForCount(in: app, 1, of: 2), "filtered count not settled")

        // The search stays; the index becomes unreadable and the archive
        // announces a change, so the same search is counted again.
        let history = root.appendingPathComponent("history.jsonl")
        let kept = root.appendingPathComponent("history.kept")
        try FileManager.default.moveItem(at: history, to: kept)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        guard requestChange(root: root) else { return }

        let count = app.staticTexts["historyResultCount"]
        let failed = AppLanguage.text("Couldn’t count")
        let deadline = Date().addingTimeInterval(5)
        while text(of: count) != failed, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(text(of: count), failed, "the earlier count stays beside the failed one")
        let retry = app.buttons["historyRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no way to count again")

        try FileManager.default.removeItem(at: history)
        try FileManager.default.moveItem(at: kept, to: history)
        retry.click()
        XCTAssertTrue(waitForCount(in: app, 1, of: 2), "Try Again did not count again")
    }

    // MARK: Add to Dictionary

    /// The whole way from a history row: the sheet shows the dictation as
    /// recognized, a selection becomes one spelling, the entry is saved and
    /// shows on the Dictionary tab, and the history line stays byte for byte,
    /// typing in the sheet's copy included.
    func testAddToDictionaryFromARowSavesTheSelectedWords() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let shown = "Claude Code 4242"
        let recognized = "клод код 4242"
        guard requestAppend(text: shown, rawText: recognized, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: shown)
        let index = root.appendingPathComponent("history.jsonl")
        let before = try Data(contentsOf: index)

        guard let source = openAddToDictionary(from: shown, in: app) else { return }
        XCTAssertEqual(source.value as? String, recognized, "the sheet does not show the text as recognized")
        selectWords(2, in: source)
        let use = app.buttons["dictionaryUseSelection"]
        XCTAssertTrue(use.isEnabled, "the selection did not reach the sheet")
        use.click()
        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertEqual(heard.value as? String, "клод код", "the selection is not the field")

        let written = app.textFields["dictionaryWrittenField"]
        written.click()
        // Digits only: they do not depend on the active keyboard layout.
        written.typeText("42")
        source.click()
        source.typeKey(.downArrow, modifierFlags: .command)
        source.typeText("7")
        XCTAssertEqual(source.value as? String, recognized + "7", "the copy took no typing — the check proves nothing")
        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet did not close after Save")

        XCTAssertEqual(try Data(contentsOf: index), before, "the history line changed")
        XCTAssertTrue(app.staticTexts[shown].exists, "the history row changed")
        guard app.showMainSection("dictionary") else { return }
        let entry = app.descendants(matching: .any)["dictionaryEntry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no entry in the Dictionary section")
        XCTAssertTrue(entry.staticTexts["42"].exists, "the entry is not the one saved")
        XCTAssertTrue(entry.staticTexts["клод код"].exists, "the selection was not saved as one spelling")
    }

    /// A comma in the selection would make two spellings of one phrase: the
    /// field stays as it was and the reason shows, nothing is cut away.
    func testAddToDictionaryRefusesASelectionWithAComma() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let shown = "клод, код 77"
        guard requestAppend(text: shown, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: shown)

        guard let source = openAddToDictionary(from: shown, in: app) else { return }
        selectWords(2, in: source)
        app.buttons["dictionaryUseSelection"].click()
        XCTAssertTrue(
            app.staticTexts["dictionarySelectionError"].waitForExistence(timeout: 5),
            "a selection with a comma was taken without a word"
        )
        let heard = app.textFields["dictionaryHeardField"].value as? String ?? ""
        XCTAssertFalse(heard.contains("клод") || heard.contains("код"), "the field took “\(heard)”")
        app.buttons["dictionaryCancel"].click()
    }

    /// The Dictionary tab locks editing until the dictionary is cleared
    /// there; from the history the sheet says so and leads to the tab.
    func testAddToDictionaryLeadsToTheTabWhileTheDictionaryCannotBeRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a dictionary document: the store reads the key as damaged.
        let app = launch(root: root, extra: ["-dictionary.entries", "damaged"])
        defer { app.terminate() }
        let shown = "клод код 55"
        guard requestAppend(text: shown, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: shown)

        app.staticTexts[shown].rightClick()
        let add = app.menuItems[AppLanguage.text("Add to Dictionary…")]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the row offers no Add to Dictionary…")
        add.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["dictionaryUnreadableNote"].waitForExistence(timeout: 5),
            "the sheet does not say the dictionary can’t be read"
        )
        XCTAssertFalse(app.textFields["dictionaryHeardField"].exists, "the sheet offers fields it could not save")
        app.buttons["dictionaryOpenTab"].click()
        XCTAssertTrue(
            app.windows["main"].descendants(matching: .any)["mainContent.dictionary"].waitForExistence(timeout: 5),
            "Open Dictionary did not lead to the Dictionary section"
        )
        XCTAssertFalse(app.windows["settings"].exists, "Open Dictionary opened Settings")
        XCTAssertTrue(app.buttons["dictionaryClear"].waitForExistence(timeout: 5), "the tab offers no way to clear")
    }

    /// Tabs are only hidden, never closed: the sheet stays over a tab changed
    /// from the menu bar, with its draft, until it is answered there. Cancel
    /// saves nothing, and the next sheet's fields start empty. The Dictionary
    /// tab's own sheet is checked in `DictionaryTransferTests`.
    func testATabChangedFromTheMenuBarKeepsTheDictionarySheet() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = launch(root: root)
        defer { app.terminate() }
        let shown = "клод код 66"
        guard requestAppend(text: shown, root: root) else { return }
        try openHistory(in: app, expectedCount: (1, 1), visibleText: shown)

        guard let source = openAddToDictionary(from: shown, in: app) else { return }
        selectWords(1, in: source)
        app.buttons["dictionaryUseSelection"].click()
        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertEqual(heard.value as? String, "клод")
        guard app.transcribeAFileFromMenuBar() else { return }
        // Long enough for the change to have gone through the tab it left.
        let gone = heard.waitForNonExistence(timeout: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the tab change")
        guard !gone else { return XCTFail("the sheet went away with the tab") }
        XCTAssertEqual(heard.value as? String, "клод", "the draft changed with the tab")
        app.buttons["dictionaryCancel"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet stayed after Cancel")

        guard app.showMainSection("dictionary") else { return }
        XCTAssertTrue(app.buttons["dictionaryAdd"].waitForExistence(timeout: 5), "the Dictionary section did not show")
        XCTAssertFalse(app.descendants(matching: .any)["dictionaryEntry"].exists, "Cancel saved the draft")
        guard app.showMainSection("dictations") else { return }
        guard openAddToDictionary(from: shown, in: app) != nil else { return }
        XCTAssertEqual(heard.value as? String ?? "", "", "the draft came back")
        XCTAssertEqual(app.textFields["dictionaryWrittenField"].value as? String ?? "", "", "the draft came back")
        app.buttons["dictionaryCancel"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5))
    }

    /// The row's context menu → the sheet; nil, after failing the test, when
    /// it did not open on the dictation's text.
    private func openAddToDictionary(from text: String, in app: XCUIApplication) -> XCUIElement? {
        app.staticTexts[text].firstMatch.rightClick()
        let add = app.menuItems[AppLanguage.text("Add to Dictionary…")]
        guard add.waitForExistence(timeout: 5) else {
            XCTFail("the row offers no Add to Dictionary…")
            return nil
        }
        add.click()
        // The identifier may land on the editor's scroll view or on its text
        // view; the text view is what takes clicks, keys and the value.
        let tagged = app.descendants(matching: .any)["dictionarySourceText"].firstMatch
        guard tagged.waitForExistence(timeout: 5) else {
            XCTFail("the sheet shows no text from the dictation")
            return nil
        }
        return tagged.elementType == .textView ? tagged : tagged.textViews.firstMatch
    }

    /// From the start of the text, word by word: arrow keys with modifiers
    /// are key codes, so the active keyboard layout does not matter.
    private func selectWords(_ count: Int, in source: XCUIElement) {
        source.click()
        source.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<count {
            source.typeKey(.rightArrow, modifierFlags: [.option, .shift])
        }
    }

    // MARK: Helpers

    private func launch(root: URL, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-HistoryProbeRoot", root.path]
            + extra + AppLanguage.launchArguments
        app.launch()
        return app
    }

    private func openHistory(in app: XCUIApplication, expectedCount: (Int, Int), visibleText: String) throws {
        guard app.openMainSection("dictations") else { return }
        XCTAssertTrue(app.staticTexts[visibleText].waitForExistence(timeout: 5), "history did not settle")
        XCTAssertTrue(waitForCount(in: app, expectedCount.0, of: expectedCount.1), "count did not settle")
    }

    /// Opens Settings from the menu bar; false, after failing the test, when
    /// its sections cannot be trusted to be there.
    private func openSettings(in app: XCUIApplication) -> Bool {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "The Murmurly item did not appear in the menu bar")
        statusItem.click()
        // MenuBarExtra exposes no identifiers; Settings is third from the end.
        let menuItems = statusItem.menus.firstMatch.children(matching: .menuItem)
        guard menuItems.count >= 3 else {
            XCTFail("The Murmurly menu has too few items")
            return false
        }
        menuItems.element(boundBy: menuItems.count - 3).click()
        return app.settingsSidebarSearchIsEmpty()
    }

    /// The "N of M" count found by its identifier and read as two numbers:
    /// the words around them change with the language, the numbers do not.
    private func waitForCount(in app: XCUIApplication, _ matching: Int, of total: Int) -> Bool {
        let count = app.staticTexts["historyResultCount"]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if count.exists {
                let text = (count.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? count.label
                let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
                if numbers == [matching, total] { return true }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// How far the element's most distinct pixel stands from its background
    /// (the corner pixel), 0…1, by luminance: in a light or a dark
    /// appearance alike, how visible its icon is.
    private func iconContrast(of element: XCUIElement) -> Double? {
        guard let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func luminance(_ index: Int) -> Double {
            (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])) / 255
        }
        let background = luminance(0)
        return stride(from: 0, to: pixels.count, by: 4).map { abs(luminance($0) - background) }.max()
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// Asks the probe to append and returns once it confirmed. A missing
    /// confirmation fails the run as inconclusive, not as a red.
    private func requestAppend(text: String, rawText: String? = nil, root: URL) -> Bool {
        let id = UUID().uuidString
        let marker = root.appendingPathComponent("appended-\(id).json")
        var request: [String: String] = ["id": id, "text": text]
        request["raw_text"] = rawText
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              (try? data.write(to: root.appendingPathComponent("append-request.json"), options: .atomic)) != nil
        else {
            XCTFail("could not write the request for the probe")
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let confirmation = try? Data(contentsOf: marker),
              let json = try? JSONSerialization.jsonObject(with: confirmation) as? [String: String],
              json["appended"] == "true" else {
            XCTFail("the probe did not confirm the append — the check proves nothing")
            return false
        }
        return true
    }

    /// Asks the probe to announce a change of the archive and returns once
    /// it did. No announcement fails the run as inconclusive, not as a red.
    private func requestChange(root: URL) -> Bool {
        let request = root.appendingPathComponent("change-request")
        guard (try? Data().write(to: request, options: .atomic)) != nil else {
            XCTFail("could not write the request for the probe")
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: request.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !FileManager.default.fileExists(atPath: request.path) else {
            XCTFail("the probe did not announce the change — the check proves nothing")
            return false
        }
        return true
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
