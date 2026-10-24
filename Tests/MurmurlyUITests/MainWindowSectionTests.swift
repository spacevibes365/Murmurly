import AVFoundation
import CoreGraphics
import XCTest

/// The main window's sections: the menu's commands open the window on theirs,
/// Settings' tabs never steer them, and what is up over a section (an alert,
/// a sound, a file being read) follows the main window's own changes of
/// section, as it followed Settings' tabs before. The history and Files run
/// through their DEBUG probes, in roots of the test's own.
@MainActor
final class MainWindowSectionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("main-sections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // A test that took write access away gives it back first.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Each command opens the main window, or brings it forward, on its
    /// section: with no window open, over another section, and with
    /// Settings open and key, which stays. A command for Settings leaves the
    /// main window's section alone, and Open Murmurly shows the last one.
    func testMenuCommandsOpenTheirSection() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertEqual(app.windows.count, 0)

        XCTAssertTrue(try openFullHistory(app), "Open Full History… did not open Dictations")
        XCTAssertFalse(app.windows["settings"].exists, "Open Full History… opened Settings")

        guard app.showMainSection("files") else { return }
        XCTAssertTrue(try openFullHistory(app), "Open Full History… left the window on Files")

        close(app.windows["main"])
        try openSettings(app)
        try menu(app, AppLanguage.text("Transcribe a File…"))
        XCTAssertTrue(shows("files", in: app), "Transcribe a File… did not open Files")
        XCTAssertTrue(app.windows["settings"].exists, "Settings went away")

        let languages = try submenuCommand(app, [AppLanguage.text("Dictation Language"), AppLanguage.text("More Languages…")]) {
            app.windows["settings"].descendants(matching: .any)["settingsContent.dictation"].waitForExistence(timeout: 5)
        }
        XCTAssertTrue(languages, "More Languages… did not open Settings on Dictation")
        XCTAssertTrue(shows("files", in: app), "a command for Settings changed the main window's section")

        close(app.windows["main"])
        try menu(app, AppLanguage.text("Open Murmurly"))
        XCTAssertTrue(shows("files", in: app), "Open Murmurly did not show the last section")
    }

    /// Settings' tabs are another window's: switching them changes nothing
    /// in the main window. Its section, the history's search, and a file the
    /// dictionary is reading stay; the read is answered as it would be.
    func testSettingsTabsLeaveTheMainWindowAlone() throws {
        let probe = root.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try offerDictionary(as: 1, in: probe)
        let app = launch(["-FileProbeRoot", probe.path])
        defer { app.terminate() }
        guard app.openMainSection("dictations") else { return }
        let window = app.windows["main"]
        let search = window.textFields["historySearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("4242")

        guard app.showMainSection("dictionary") else { return }
        window.buttons["dictionaryImport"].click()
        XCTAssertTrue(waitFor("dictionary-import-1.reading", in: probe), "the import is not reading")
        try openSettings(app)
        for tab in ["storage", "permissions", "dictation"] {
            app.windows["settings"].buttons["settingsTab.\(tab)"].click()
            XCTAssertTrue(app.windows["settings"].descendants(matching: .any)["settingsContent.\(tab)"].waitForExistence(timeout: 5))
        }
        try Data().write(to: probe.appendingPathComponent("dictionary-import-1.release"))
        XCTAssertTrue(waitFor("dictionary-import-1.handled", in: probe))
        XCTAssertTrue(shows("dictionary", in: app), "a tab of Settings changed the main window's section")
        let note = window.staticTexts["dictionaryTransferNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the read was dropped by a tab of Settings")
        XCTAssertEqual(note.value as? String, AppLanguage.text("Added: %lld.", 1))

        guard app.showMainSection("dictations") else { return }
        XCTAssertEqual(window.textFields["historySearchField"].value as? String, "4242", "the search went with Settings' tabs")
    }

    /// The read of a file to import is dropped by any change of section,
    /// the Dictionary section hidden all along included: its panel answered
    /// over Files, the file read while Dictations comes, nothing is asked
    /// and nothing saved, into an empty dictionary or a full one.
    func testAReadAfterASectionChangeIsDroppedByTheNext() throws {
        for filled in [false, true] {
            let probe = root.appendingPathComponent("probe-\(filled)", isDirectory: true)
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            try offerDictionary(as: 1, in: probe)
            try Data().write(to: probe.appendingPathComponent("dictionary-import-1.hold"))
            var extra = ["-FileProbeRoot", probe.path]
            if filled { extra += ["-dictionary.entries", try dictionaryArgument([entry(9, ["девять"], "Nine")])] }
            let app = launch(extra)
            defer { app.terminate() }
            guard app.openMainSection("dictionary") else { return }
            let window = app.windows["main"]
            let entries = window.descendants(matching: .any).matching(identifier: "dictionaryEntry")
            let before = entries.count
            window.buttons["dictionaryImport"].click()
            XCTAssertTrue(waitFor("dictionary-import-1.choosing", in: probe), "the import's panel is not up")

            guard app.transcribeAFileFromMenuBar() else { return }
            try Data().write(to: probe.appendingPathComponent("dictionary-import-1.chosen"))
            XCTAssertTrue(waitFor("dictionary-import-1.reading", in: probe), "the panel's answer read nothing")
            // Another change of section, the dictionary hidden all along.
            guard app.showMainSection("dictations") else { return }
            try Data().write(to: probe.appendingPathComponent("dictionary-import-1.release"))
            XCTAssertTrue(waitFor("dictionary-import-1.handled", in: probe))

            XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "the dropped read asked about the file (filled: \(filled))")
            guard app.showMainSection("dictionary") else { return }
            XCTAssertTrue(window.buttons["dictionaryImport"].waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil { window.buttons["dictionaryImport"].isEnabled }, "the section stayed locked")
            XCTAssertEqual(entries.count, before, "the dropped read saved its entries (filled: \(filled))")
            XCTAssertFalse(window.staticTexts["dictionaryTransferNote"].exists, "the dropped read reported something")
            app.terminate()
        }
    }

    /// An error shown over Dictations stays through a change of section from
    /// the menu bar until its OK: closing it from the change ran AppKit's
    /// close animation inside the window's layout. A deletion the archive's
    /// folder refuses gives the error.
    func testAShownHistoryErrorStaysThroughASectionChange() throws {
        let app = launch(["-HistoryProbeRoot", root.path])
        defer { app.terminate() }
        let text = "probe 5151"
        guard append(text, id: UUID()) else { return }
        guard app.openMainSection("dictations") else { return }
        let window = app.windows["main"]
        XCTAssertTrue(window.staticTexts[text].waitForExistence(timeout: 5))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        window.staticTexts[text].rightClick()
        let delete = app.menuItems[AppLanguage.text("Delete…")]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row offers no Delete…")
        delete.click()
        let confirm = app.sheets.firstMatch.buttons[AppLanguage.text("Delete")]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let alert = app.sheets.firstMatch.buttons[AppLanguage.text("OK")]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the failed deletion said nothing")

        guard app.transcribeAFileFromMenuBar() else { return }
        XCTAssertEqual(app.state, .runningForeground, "the app did not survive the change of section")
        XCTAssertFalse(alert.waitForNonExistence(timeout: 2), "the change of section closed the alert")
        alert.click()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "OK did not close the alert")
    }

    /// The history's sound plays on through a change of Settings' tab and
    /// stops when the main window leaves Dictations. The dictation's audio
    /// is silence: a test copy makes no sound.
    func testLeavingDictationsStopsItsSound() throws {
        let app = launch(["-HistoryProbeRoot", root.path])
        defer { app.terminate() }
        let id = UUID()
        try silence(at: root.appendingPathComponent("probe/\(id.uuidString).caf"))
        let text = "probe 6161"
        guard append(text, id: id) else { return }
        guard app.openMainSection("dictations") else { return }
        let window = app.windows["main"]
        XCTAssertTrue(window.staticTexts[text].waitForExistence(timeout: 5))
        XCTAssertTrue(contextMenu(of: text, in: app, offers: "Play Recording", choosing: true), "no Play Recording")
        XCTAssertTrue(contextMenu(of: text, in: app, offers: "Stop Playback"), "the dictation does not play")

        try openSettings(app)
        app.windows["settings"].buttons["settingsTab.storage"].click()
        XCTAssertTrue(app.windows["settings"].descendants(matching: .any)["settingsContent.storage"].waitForExistence(timeout: 5))
        // Settings over the row: it goes before the row is used again.
        close(app.windows["settings"])
        XCTAssertTrue(contextMenu(of: text, in: app, offers: "Stop Playback"), "a tab of Settings stopped the sound")

        guard app.showMainSection("files"), app.showMainSection("dictations") else { return }
        XCTAssertTrue(contextMenu(of: text, in: app, offers: "Play Recording"), "leaving Dictations did not stop the sound")
    }

    /// Every section keeps the window: at the size it opens with and at
    /// its least, a change of section moves and resizes nothing, the
    /// sidebar's button and Settings… stay put, and each section's own
    /// control is inside the window. Refresh is on only for the meetings.
    func testSectionsKeepTheWindowAndItsChrome() throws {
        let app = launch()
        defer { app.terminate() }
        guard app.openMainSection("meetings") else { return }
        let window = app.windows["main"]
        let toggle = window.buttons["mainSidebarToggle"]
        let settings = window.buttons["mainSidebarSettings"]
        let refresh = window.buttons["mainRefresh"]
        let controls = ["meetings": window.outlines["meetingList"],
                        "starred": window.outlines["meetingList"],
                        "dictations": window.textFields["historySearchField"],
                        "dictionary": window.buttons["dictionaryAdd"],
                        "files": window.buttons["fileTranscribeButton"]]
        func still() -> CGRect {
            var frame = window.frame
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.2)
                let next = window.frame
                if next == frame { break }
                frame = next
            }
            return frame
        }
        for size in ["opening", "least"] {
            if size == "least" {
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
                corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -800, dy: -400)))
            }
            let start = still()
            let toggleAt = toggle.frame
            let settingsAt = settings.frame
            for section in ["dictations", "dictionary", "files", "starred", "meetings"] {
                guard app.showMainSection(section) else { return }
                let place = "\(section) at the \(size) size"
                XCTAssertEqual(still(), start, "the window moved or resized on \(place)")
                XCTAssertEqual(toggle.frame, toggleAt, "the sidebar's button moved on \(place)")
                XCTAssertEqual(settings.frame, settingsAt, "Settings… moved on \(place)")
                let control = controls[section]!
                XCTAssertTrue(control.waitForExistence(timeout: 5), "no control of \(place)")
                XCTAssertTrue(start.contains(CGPoint(x: control.frame.maxX - 1, y: control.frame.midY)), "\(place): its control is cut: \(control.frame) in \(start)")
                XCTAssertEqual(refresh.isEnabled, section == "meetings" || section == "starred", "Refresh on \(place)")
            }
        }
    }

    /// A tab of Settings stored by an earlier version (History, Dictionary,
    /// Files) opens no window at launch, and Settings… then shows its
    /// default tab.
    func testAnOldSettingsTabOpensNoWindow() throws {
        for old in ["history", "dictionary", "files"] {
            let app = launch(["-ui.settingsTab", old])
            XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            XCTAssertEqual(app.windows.count, 0, "\(old): a window opened at launch")
            try openSettings(app)
            XCTAssertTrue(
                app.windows["settings"].descendants(matching: .any)["settingsContent.dictation"].waitForExistence(timeout: 5),
                "\(old): Settings did not open on Dictation"
            )
            app.terminate()
        }
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore"] + extra + AppLanguage.launchArguments
        app.launch()
        return app
    }

    /// An item of the menu bar's menu, through its submenus.
    private func menu(_ app: XCUIApplication, _ path: String...) throws {
        try menu(app, path)
    }

    /// Found the same way as before (`menuItems[title]`, which never fails
    /// the test outright, only answers exists or not), but acted on by a
    /// point derived from the item's own frame rather than by asking the
    /// item to click or hover itself: that re-walks the whole path from the
    /// menu bar's own menu down and registers a hard XCTest failure, not a
    /// catchable one, the moment a submenu closes or is rebuilt in between —
    /// which the menu bar's menu is, by permission polling and the like. Up
    /// to 3 opens of the menu bar's own menu per call.
    private func menu(_ app: XCUIApplication, _ path: [String]) throws {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no Murmurly item in the menu bar")

        for attempt in 1...3 {
            statusItem.click()
            if reachMenu(statusItem: statusItem, path: path) { return }
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
            _ = waitUntil(seconds: 5) { !statusItem.menus.firstMatch.exists }
            print("MENU: \(path.joined(separator: " › ")) not reached, attempt \(attempt)")
        }
        XCTFail("the menu did not open to \(path.joined(separator: " › "))")
    }

    /// Walks one path through the menu bar's own menu, already open. Returns
    /// false, without failing the test, the moment a step can't be found or
    /// acted on, so the caller can retry from a freshly opened menu.
    private func reachMenu(statusItem: XCUIElement, path: [String]) -> Bool {
        let base = statusItem.frame
        func point(_ frame: CGRect, dx: CGFloat) -> XCUICoordinate {
            statusItem.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: dx - base.minX, dy: frame.midY - base.minY))
        }
        // A frame mid-rebuild (permission polling and the like) can answer
        // with NaN or a zero size; read it once and judge that one reading,
        // never a second, possibly different, one taken right after.
        func usable(_ frame: CGRect) -> Bool {
            frame.minX.isFinite && frame.minY.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        func onScreen(_ coordinate: XCUICoordinate) -> Bool {
            let point = coordinate.screenPoint
            guard point.x.isFinite && point.y.isFinite else { return false }
            // screenPoint is in Quartz's top-left-origin display space, the
            // same one CGGetActiveDisplayList/CGDisplayBounds report; a
            // reading off every display's union is a real, unusable
            // coordinate, not one caught mid-rebuild.
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success, count > 0 else {
                return false
            }
            return (0..<Int(count)).contains { CGDisplayBounds(displays[$0]).contains(point) }
        }

        var menu = statusItem.menus.firstMatch
        guard menu.waitForExistence(timeout: 5) else { return false }
        for (index, title) in path.enumerated() {
            let item = menu.menuItems[title]
            guard item.waitForExistence(timeout: 5), item.isEnabled else { return false }
            let frame = item.frame
            guard usable(frame) else { return false }
            if index == path.count - 1 {
                let target = point(frame, dx: frame.midX)
                guard onScreen(target) else { return false }
                target.click()
            } else {
                // Toward the right edge, so the pointer's path to the
                // submenu goes sideways, not back over neighboring items.
                let middle = point(frame, dx: frame.midX)
                let edge = point(frame, dx: frame.maxX - 4)
                guard onScreen(middle), onScreen(edge) else { return false }
                middle.hover()
                edge.hover()
                menu = item.menus.firstMatch
                guard menu.waitForExistence(timeout: 5) else { return false }
            }
        }
        return true
    }

    /// Open Full History…, in the Dictation History submenu.
    private func openFullHistory(_ app: XCUIApplication) throws -> Bool {
        try submenuCommand(app, [AppLanguage.text("Dictation History"), AppLanguage.text("Open Full History…")]) {
            shows("dictations", in: app, within: 5)
        }
    }

    /// An item of a submenu of the menu bar's menu. A click in a submenu
    /// that is closing sometimes does not land in a UI test: the command is
    /// given once more, never more, if what it does did not show.
    private func submenuCommand(_ app: XCUIApplication, _ path: [String], done: () -> Bool) throws -> Bool {
        for attempt in 1...2 {
            try menu(app, path)
            if done() { return true }
            print("MENU: \(path.last ?? "") did not land, attempt \(attempt)")
            app.typeKey(.escape, modifierFlags: [])
        }
        return false
    }

    /// Settings from the menu bar, third item from its end.
    private func openSettings(_ app: XCUIApplication) throws {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let items = statusItem.menus.firstMatch.children(matching: .menuItem)
        XCTAssertGreaterThanOrEqual(items.count, 3)
        items.element(boundBy: items.count - 3).click()
        XCTAssertTrue(app.windows["settings"].waitForExistence(timeout: 10), "no Settings")
    }

    private func shows(_ section: String, in app: XCUIApplication, within seconds: TimeInterval = 10) -> Bool {
        app.windows["main"].descendants(matching: .any)["mainContent.\(section)"].waitForExistence(timeout: seconds)
    }

    private func close(_ window: XCUIElement) {
        XCTAssertTrue(window.exists, "no such window to close")
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), "the window stayed")
    }

    /// The row's context menu has the item titled so (its catalog key); it
    /// is chosen, or the menu closed again.
    private func contextMenu(of text: String, in app: XCUIApplication, offers key: String, choosing: Bool = false) -> Bool {
        app.windows["main"].staticTexts[text].firstMatch.rightClick()
        let item = app.menuItems[AppLanguage.text(key)]
        let offered = item.waitForExistence(timeout: 3)
        if offered, choosing {
            item.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        return offered
    }

    /// The history probe appends one dictation and says so.
    private func append(_ text: String, id: UUID) -> Bool {
        let request: [String: String] = ["id": id.uuidString, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              (try? data.write(to: root.appendingPathComponent("append-request.json"), options: .atomic)) != nil else {
            XCTFail("the append request was not written")
            return false
        }
        guard waitFor("appended-\(id.uuidString).json", in: root) else { return false }
        return true
    }

    /// Thirty seconds of silence, as the archive's audio would be.
    private func silence(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 30))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
    }

    private func entry(_ number: Int, _ heard: [String], _ written: String) -> [String: Any] {
        ["id": String(format: "00000000-0000-0000-0000-%012d", number), "heard": heard, "written": written, "enabled": true]
    }

    /// The n-th import's file in the probe's root, its read held until
    /// `dictionary-import-<n>.release`.
    private func offerDictionary(as number: Int, in probe: URL) throws {
        let document: [String: Any] = ["version": 1, "entries": [entry(1, ["клод код"], "Claude Code")]]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: probe.appendingPathComponent("dictionary-import-\(number).json"))
    }

    /// Entries for the settings through the argument domain only.
    private func dictionaryArgument(_ entries: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
        return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }

    private func waitFor(_ marker: String, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(marker)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("the probe never wrote \(marker) — the check proves nothing")
            return false
        }
        return true
    }

    private func waitUntil(seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
