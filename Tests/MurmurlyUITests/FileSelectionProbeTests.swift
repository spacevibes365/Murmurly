import XCTest

/// A probe step that did not happen: not a regression, the run is inconclusive.
private struct ProbeTransportError: Error {
    let message: String
}

/// One app launch with `-FileProbeRoot`. Talks to the app's DEBUG FileProbe
/// only through files: requests, gates and acknowledgements. The order of
/// events is set by the gates and proven by the acknowledgements; UI waits only
/// let the tab settle into a state.
@MainActor
private final class FileProbeSession {
    let app = XCUIApplication()
    let root: URL
    private var requests = 0
    private var saves = 0
    private var openGates: Set<String> = []

    /// `realPanels`: the real open and save panels, opening in the root,
    /// instead of the probe's stand-in for the save panel.
    init(realPanels: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Kept after the test so the runner can count iteration files; named
        // here so it is removed by an owned list, not a glob.
        print("FILE-PROBE-ROOT \(root.path)")
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-FileProbeRoot", root.path]
            + (realPanels ? ["-FileProbeRealPanels"] : [])
            + AppLanguage.launchArguments
        app.launch()
    }

    func openFilesTab() throws {
        try openWindow()
        guard app.descendants(matching: .any)["fileDropZonePrompt"].waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the Files tab did not open")
        }
    }

    /// Opens the settings window on the Files tab, whatever the tab shows.
    func openWindow() throws {
        let statusItem = app.statusItems.firstMatch
        guard statusItem.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the Murmurly item did not appear in the menu bar")
        }
        statusItem.click()
        let menuItems = statusItem.menus.firstMatch.children(matching: .menuItem)
        guard menuItems.count >= 3 else {
            throw ProbeTransportError(message: "the Murmurly menu has too few items")
        }
        menuItems.element(boundBy: menuItems.count - 3).click()
        guard app.settingsSidebarSearchIsEmpty() else {
            throw ProbeTransportError(message: "the settings section search is not empty")
        }
        let files = app.buttons["settingsTab.files"]
        guard files.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "no Files tab")
        }
        files.click()
        guard app.descendants(matching: .any)["settingsContent.files"].waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the Files tab did not open")
        }
    }

    func closeWindow() throws {
        let window = app.windows.firstMatch
        let close = window.buttons[XCUIIdentifierCloseWindow]
        guard close.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the window has no close button")
        }
        close.click()
        guard window.waitForNonExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the window did not close")
        }
    }

    func makeFile(_ name: String) throws -> String {
        guard FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data()) else {
            throw ProbeTransportError(message: "file \(name) was not created")
        }
        return name
    }

    /// Hands the real drop handler a provider that waits for its gate; returns
    /// what `handleDrop` answered.
    func drop(_ id: String, _ file: String, fails: Bool = false) throws -> Bool {
        requests += 1
        let request: [String: String] = [
            "id": id, "action": "drop",
            "file": root.appendingPathComponent(file).path, "error": fails ? "1" : "0",
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        try data.write(to: root.appendingPathComponent("request-\(requests).json"), options: .atomic)
        let accepted = try read("\(id).accepted")
        if accepted == "true" { openGates.insert("\(id).release") }
        return accepted == "true"
    }

    /// A drop that must be pending for the scenario to test anything: refused
    /// at once, it would make a late answer impossible and the check empty.
    func dropPending(_ id: String, _ file: String, fails: Bool = false) throws {
        guard try drop(id, file, fails: fails) else {
            throw ProbeTransportError(message: "drop \(file) not accepted — a late answer is not checked")
        }
    }

    /// Opens a drop's gate and waits for this drop's own callback to finish on
    /// the main actor.
    func release(_ id: String) throws {
        try open("\(id).release")
        _ = try read("\(id).delivered", unless: "\(id).timeout")
        _ = try read("\(id).callback")
    }

    func dropApplied(_ id: String, _ file: String) throws {
        try dropPending(id, file)
        try release(id)
        guard waitShows(file) else { throw ProbeTransportError(message: "file \(file) was not chosen") }
    }

    func start(_ file: String) throws {
        let button = app.buttons["fileTranscribeButton"]
        guard button.waitForExistence(timeout: 5), button.isEnabled else {
            throw ProbeTransportError(message: "the Transcribe button is not available")
        }
        openGates.insert("run-\(file).release")
        button.click()
    }

    /// Runs the same file again behind a closed gate: the first run's gate and
    /// start acknowledgement are removed, so this run waits and is seen to start.
    func restart(_ file: String) throws {
        for name in ["run-\(file).release", "run-\(file).started"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try start(file)
    }

    func waitRunStarted(_ file: String) throws {
        _ = try read("run-\(file).started")
    }

    func releaseRun(_ file: String) throws {
        try open("run-\(file).release")
    }

    /// The name the real save panel was given, observed right after it was set;
    /// the panel's gate is opened in advance, so the save completes at once.
    func saveName() throws -> String {
        let number = try clickSave(holding: false)
        return try read("save-\(number).txt")
    }

    /// Clicks "Save .md" with the panel's gate closed: while the test
    /// keeps it closed, the tab waits in the probe's nested run loop.
    func clickSave(holding: Bool) throws -> Int {
        let button = app.buttons["fileSaveButton"]
        guard button.waitForExistence(timeout: 5), button.isEnabled else {
            throw ProbeTransportError(message: "the Save .md button is not available")
        }
        saves += 1
        if holding {
            openGates.insert("save-\(saves).release")
        } else {
            try open("save-\(saves).release")
        }
        button.click()
        return saves
    }

    /// A save the tab starts by itself ("Save .md…" in the sheet): its panel's
    /// gate is opened in advance, and its number is the one the probe gives it.
    func expectSave() throws -> Int {
        saves += 1
        try open("save-\(saves).release")
        return saves
    }

    func savedText(_ number: Int) throws -> String {
        try read("saved-\(number).md", unless: "save-\(number).timeout")
    }

    func savePanelName(_ number: Int) throws -> String {
        try read("save-\(number).txt")
    }

    /// Lets the held panel answer and returns what the tab wrote to its file.
    func finishSave(_ number: Int) throws -> String {
        try open("save-\(number).release")
        return try read("saved-\(number).md", unless: "save-\(number).timeout")
    }

    func shows(_ text: String) -> Bool { app.staticTexts[text].firstMatch.exists }

    func waitShows(_ text: String) -> Bool { app.staticTexts[text].firstMatch.waitForExistence(timeout: 5) }

    /// The sheet that asks before unsaved text is replaced.
    func waitAsked() -> Bool { app.sheets.firstMatch.waitForExistence(timeout: 5) }

    func answer(_ button: String) throws {
        let choice = app.sheets.firstMatch.buttons[button]
        guard choice.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the sheet has no “\(button)” button")
        }
        choice.click()
        // The button, not the sheet: "Save .md…" is followed by the panel's own.
        guard choice.waitForNonExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the sheet stayed after “\(button)”")
        }
    }

    /// The real save panel, which must come as a sheet on the window; answered
    /// with Return or Escape, which work in any layout and language.
    func answerSavePanel(save: Bool) throws {
        let panel = app.sheets.containing(.textField, identifier: nil).firstMatch
        guard panel.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "no save panel sheet on the window")
        }
        app.typeKey(save ? .return : .escape, modifierFlags: [])
        guard panel.waitForNonExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the save panel stayed")
        }
    }

    /// Quit from the app's own menu, as a person does; ⌘Q depends on the
    /// keyboard layout.
    func quitFromMainMenu() throws {
        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        guard appMenu.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "no app menu in the menu bar")
        }
        appMenu.click()
        let quit = appMenu.menuItems.matching(NSPredicate(
            format: "identifier == 'terminate:' OR title BEGINSWITH %@", AppLanguage.text("Quit")
        )).firstMatch
        guard quit.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "no Quit in the app menu")
        }
        quit.click()
    }

    /// What the tab wrote to a file the real panel saved in the root.
    func written(_ name: String) throws -> String {
        try read(name)
    }

    /// Opens every gate this iteration left closed, so a failed iteration
    /// cannot hold the next one.
    func releaseAll() {
        for gate in openGates {
            try? Data("release".utf8).write(to: root.appendingPathComponent(gate), options: .atomic)
        }
        openGates.removeAll()
    }

    func write(record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let id = record["id"] as? String ?? UUID().uuidString
        try? data.write(to: root.appendingPathComponent("iteration-\(id).json"), options: .atomic)
        print("FILE-PROBE-ITERATION \(json)")
    }

    private func open(_ gate: String) throws {
        try Data("release".utf8).write(to: root.appendingPathComponent(gate), options: .atomic)
        openGates.remove(gate)
    }

    /// Gate timeouts the app reported for this iteration: such an iteration
    /// proves nothing either way.
    func timeouts(of id: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".timeout") && $0.contains(id) }.sorted()
    }

    private func read(_ name: String, unless failure: String? = nil) throws -> String {
        let url = root.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            if let failure, FileManager.default.fileExists(atPath: root.appendingPathComponent(failure).path) {
                throw ProbeTransportError(message: "gate timed out: \(failure)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProbeTransportError(message: "the probe did not confirm \(name)")
        }
        return text
    }
}

/// The real Files tab: the real drop handler, the real run and the
/// real save panel's name, with a stand-in engine. Every test repeats its
/// scenario `FILE_PROBE_ITERATIONS` times (default 1) in one app launch; each
/// finished iteration is logged, attached and written with its observations.
/// A wrong result is a `REGRESSION` and the loop goes on; a probe step that did
/// not happen is a `PROBE` failure, counted apart.
@MainActor
final class FileSelectionProbeTests: XCTestCase {
    private let error = AppLanguage.text("Couldn’t read the dropped item.")

    func testDropAnsweredAfterTheRunStartedDoesNotRelabelIt() {
        iterate("late-drop") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.dropPending("\(id)-b", b)
            record["acceptedB"] = true
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.release("\(id)-b")
            try probe.releaseRun(a)
            let transcript = probe.waitShows("transcript \(a)")
            record["shownA"] = probe.shows(a)
            record["shownB"] = probe.shows(b)
            record["transcriptA"] = transcript
            return problems([
                (transcript, "no text A after the run"),
                (probe.shows(a), "name A disappeared"),
                (!probe.shows(b), "result A shown under name B"),
            ])
        }
    }

    func testDropErrorAnsweredAfterTheRunDoesNotReplaceItsResult() {
        iterate("late-error") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.dropPending("\(id)-b", b, fails: true)
            record["acceptedB"] = true
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            let finished = probe.waitShows("transcript \(a)")
            try probe.release("\(id)-b")
            record["finishedA"] = finished
            record["transcriptA"] = probe.shows("transcript \(a)")
            record["errorShown"] = probe.shows(error)
            return problems([
                (finished, "run A showed no text"),
                (!probe.shows(error), "error B replaced result A"),
                (probe.shows("transcript \(a)"), "text A disappeared"),
            ])
        }
    }

    func testOlderDropAnsweredLastDoesNotWin() {
        iterate("order") { probe, id, record in
            let b = try probe.makeFile("\(id)-B.wav")
            let c = try probe.makeFile("\(id)-C.wav")
            try probe.dropPending("\(id)-b", b)
            record["acceptedB"] = true
            try probe.dropPending("\(id)-c", c)
            record["acceptedC"] = true
            try probe.release("\(id)-c")
            let newest = probe.waitShows(c)
            try probe.release("\(id)-b")
            record["shownB"] = probe.shows(b)
            record["shownC"] = probe.shows(c)
            return problems([
                (newest, "the new choice C is not shown"),
                (probe.shows(c), "choice C disappeared"),
                (!probe.shows(b), "the late old drop B overwrote choice C"),
            ])
        }
    }

    func testSaveNameBelongsToTheFileOfTheResult() {
        iterate("save-name") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.dropPending("\(id)-b", b)
            record["acceptedB"] = true
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.release("\(id)-b")
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text, nothing to save")
            }
            let name = try probe.saveName()
            record["saveName"] = name
            return problems([(name == "\(id)-A.md", "save name “\(name)” instead of “\(id)-A.md”")])
        }
    }

    /// The save waits at the probe's gate while the main actor goes on, as
    /// with the real panel's sheet: a drop that finishes meanwhile must not
    /// empty the saved file.
    func testSaveWritesTheResultShownWhenItWasAsked() {
        iterate("save-snapshot") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text, nothing to save")
            }
            try probe.dropPending("\(id)-b", b)
            record["acceptedB"] = true
            let number = try probe.clickSave(holding: true)
            record["saveName"] = try probe.savePanelName(number)
            // B's real callback has to finish inside the panel's wait.
            try probe.release("\(id)-b")
            record["callbackDuringPanel"] = true
            let saved = try probe.finishSave(number)
            record["savedText"] = saved
            // B landed over the unsaved text of A, so it asked; that is not
            // what this test checks, the sheet is only put away.
            let asked = probe.waitAsked()
            record["askedForB"] = asked
            if asked { try probe.answer(AppLanguage.text("Cancel")) }
            return problems([
                (saved == "transcript \(a)", "the file has “\(saved)” instead of “transcript \(a)”"),
                (record["saveName"] as? String == "\(id)-A.md", "the save name is not A"),
            ])
        }
    }

    func testControlDropAppliedBeforeTheRunIsUsed() {
        iterate("control-applied") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.dropApplied("\(id)-b", b)
            try probe.start(b)
            try probe.waitRunStarted(b)
            try probe.releaseRun(b)
            let transcript = probe.waitShows("transcript \(b)")
            let name = transcript ? try probe.saveName() : ""
            record["shownB"] = probe.shows(b)
            record["transcriptB"] = transcript
            record["saveName"] = name
            return problems([
                (transcript, "no text B"),
                (probe.shows(b), "name B not shown"),
                (name == "\(id)-B.md", "save name “\(name)” instead of “\(id)-B.md”"),
            ])
        }
    }

    func testControlDropDuringTheRunIsRefused() {
        iterate("control-busy") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            let accepted = try probe.drop("\(id)-b", b)
            try probe.releaseRun(a)
            let transcript = probe.waitShows("transcript \(a)")
            record["acceptedB"] = accepted
            record["shownA"] = probe.shows(a)
            record["shownB"] = probe.shows(b)
            return problems([
                (!accepted, "a drop during the run was accepted"),
                (transcript, "no text A"),
                (probe.shows(a) && !probe.shows(b), "the choice changed during the run"),
            ])
        }
    }

    /// A second run starts from its own status: the previous run's "Done — …"
    /// under the new spinner would say the new run is already over.
    func testSecondRunDoesNotShowThePreviousDone() {
        let done = AppLanguage.text("Done — %lld lines.", 1)
        let starting = AppLanguage.text("Starting…")
        iterate("restart-status") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)"), probe.waitShows(done) else {
                throw ProbeTransportError(message: "the first run did not finish with “\(done)”")
            }
            // Saved, so the second run needs no confirmation on any build.
            _ = try probe.saveName()
            try probe.restart(a)
            try probe.waitRunStarted(a)
            let started = probe.waitShows(starting)
            let stale = probe.shows(done)
            record["startingShown"] = started
            record["doneDuringSecondRun"] = stale
            try probe.releaseRun(a)
            return problems([
                (started, "no “\(starting)” on the second run"),
                (!stale, "“\(done)” of the first run is shown during the second"),
            ])
        }
    }

    /// A design decision: closing the window does not stop a run; open it again
    /// and the run is still going, then shows its result.
    func testClosingTheWindowDoesNotStopTheRun() {
        iterate("close-window") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.closeWindow()
            try probe.openWindow()
            try probe.releaseRun(a)
            let transcript = probe.waitShows("transcript \(a)")
            record["transcriptA"] = transcript
            record["shownA"] = probe.shows(a)
            return problems([
                (transcript, "the run did not survive closing the window"),
                (probe.shows(a), "name A disappeared"),
            ])
        }
    }

    /// A new file over unsaved text waits for an answer: "Cancel" keeps the
    /// text and its name, "Replace" takes the new file without the old text.
    func testDroppingOverUnsavedTextAsksFirst() {
        let cancel = AppLanguage.text("Cancel")
        let replace = AppLanguage.text("Replace")
        iterate("replace") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text")
            }
            try probe.dropPending("\(id)-b", b)
            try probe.release("\(id)-b")
            let asked = probe.waitAsked()
            record["asked"] = asked
            guard asked else { return ["B replaced the unsaved text of A without asking"] }
            try probe.answer(cancel)
            let kept = probe.shows(a) && probe.shows("transcript \(a)") && !probe.shows(b)
            record["keptAfterCancel"] = kept

            try probe.dropPending("\(id)-b2", b)
            try probe.release("\(id)-b2")
            guard probe.waitAsked() else { return ["the second drop of B did not ask"] }
            try probe.answer(replace)
            let replaced = probe.waitShows(b) && !probe.shows("transcript \(a)") && !probe.shows(a)
            record["replacedAfterReplace"] = replaced
            return problems([
                (kept, "“Cancel” did not keep A, its text and its name"),
                (replaced, "“Replace” did not take B without the text of A"),
            ])
        }
    }

    /// "Save .md…" in the sheet writes the text that is there, and only then
    /// takes the new file.
    func testSavingFirstKeepsTheTextThenTakesTheNewFile() {
        let saveFirst = AppLanguage.text("Save .md…")
        iterate("save-first") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text")
            }
            try probe.dropPending("\(id)-b", b)
            try probe.release("\(id)-b")
            guard probe.waitAsked() else { return ["B replaced the unsaved text of A without asking"] }
            let number = try probe.expectSave()
            try probe.answer(saveFirst)
            let saved = try probe.savedText(number)
            record["savedText"] = saved
            let taken = probe.waitShows(b) && !probe.shows("transcript \(a)")
            record["tookB"] = taken
            return problems([
                (saved == "transcript \(a)", "the file has “\(saved)” instead of “transcript \(a)”"),
                (taken, "B was not taken after the save"),
            ])
        }
    }

    /// "Saved as" belongs to the result that was written: a new result is
    /// unsaved again, and says so.
    func testSavedNoteFollowsTheResult() {
        iterate("saved-note") { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text")
            }
            let unsaved = probe.app.staticTexts["fileUnsavedNote"]
            let saved = probe.app.staticTexts["fileSavedNote"]
            let unsavedFirst = unsaved.waitForExistence(timeout: 5)
            let number = try probe.clickSave(holding: false)
            _ = try probe.savedText(number)
            // The name of the file written, which the probe's panel answers.
            let name = "saved-\(number).md"
            // A SwiftUI text with an identifier carries its words as the value.
            let savedShown = saved.waitForExistence(timeout: 5)
                && saved.value as? String == AppLanguage.text("Saved as %@", name)
            let unsavedGone = !unsaved.exists
            try probe.restart(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "the second run showed no text")
            }
            let unsavedAgain = unsaved.waitForExistence(timeout: 5) && !saved.exists
            record["unsavedFirst"] = unsavedFirst
            record["savedShown"] = savedShown
            record["unsavedAgain"] = unsavedAgain
            return problems([
                (unsavedFirst, "a new result does not say it is kept only in the app"),
                (savedShown && unsavedGone, "after saving, “Saved as \(name)” is not shown alone"),
                (unsavedAgain, "the new result of a saved file passes for saved"),
            ])
        }
    }

    /// The real save panel is a sheet, not a modal loop, and writes the text
    /// shown under the result's name.
    func testRealSavePanelIsASheetAndWritesTheText() {
        iterate("real-save", realPanels: true) { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text")
            }
            let save = probe.app.buttons["fileSaveButton"]
            guard save.waitForExistence(timeout: 5) else {
                throw ProbeTransportError(message: "the Save .md button is not available")
            }
            save.click()
            try probe.answerSavePanel(save: true)
            let text = try probe.written("\(id)-A.md")
            let note = probe.app.staticTexts["fileSavedNote"]
            let saved = note.waitForExistence(timeout: 5)
                && note.value as? String == AppLanguage.text("Saved as %@", "\(id)-A.md")
            record["savedText"] = text
            record["savedNote"] = saved
            return problems([
                (text == "transcript \(a)", "the file has “\(text)” instead of “transcript \(a)”"),
                (saved, "no “Saved as \(id)-A.md”"),
            ])
        }
    }

    /// "Save .md…" in the replace sheet with the real panel: cancelling the
    /// panel keeps the unsaved text and does not take the new file; saving
    /// writes the text, then takes it.
    func testRealSavePanelDecidesTheReplacement() {
        let saveFirst = AppLanguage.text("Save .md…")
        iterate("real-save-first", realPanels: true) { probe, id, record in
            let a = try probe.makeFile("\(id)-A.wav")
            let b = try probe.makeFile("\(id)-B.wav")
            try probe.dropApplied("\(id)-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else {
                throw ProbeTransportError(message: "run A showed no text")
            }
            try probe.dropPending("\(id)-b", b)
            try probe.release("\(id)-b")
            guard probe.waitAsked() else { return ["B replaced the unsaved text of A without asking"] }
            try probe.answer(saveFirst)
            try probe.answerSavePanel(save: false)
            let kept = probe.shows("transcript \(a)") && probe.shows(a) && !probe.shows(b)
                && probe.app.staticTexts["fileUnsavedNote"].exists
            record["keptAfterCancel"] = kept

            try probe.dropPending("\(id)-b2", b)
            try probe.release("\(id)-b2")
            guard probe.waitAsked() else { return ["the second drop of B did not ask"] }
            try probe.answer(saveFirst)
            try probe.answerSavePanel(save: true)
            let text = try probe.written("\(id)-A.md")
            let taken = probe.waitShows(b) && !probe.shows("transcript \(a)")
            record["savedText"] = text
            record["tookB"] = taken
            return problems([
                (kept, "a cancelled panel did not keep A, its text and its unsaved note"),
                (text == "transcript \(a)", "the file has “\(text)” instead of “transcript \(a)”"),
                (taken, "B was not taken after the save"),
            ])
        }
    }

    /// The real open panel comes as a sheet on the window, not as a modal
    /// window of its own; cancelling it changes nothing.
    func testRealOpenPanelIsASheet() {
        iterate("real-open", realPanels: true) { probe, _, record in
            let prompt = probe.app.descendants(matching: .any)["fileDropZonePrompt"]
            guard prompt.waitForExistence(timeout: 5) else {
                throw ProbeTransportError(message: "no drop zone prompt")
            }
            prompt.click()
            let sheet = probe.app.sheets.firstMatch
            let asSheet = sheet.waitForExistence(timeout: 5)
            record["openPanelIsSheet"] = asSheet
            probe.app.typeKey(.escape, modifierFlags: [])
            let closed = probe.app.sheets.firstMatch.waitForNonExistence(timeout: 5)
                && probe.app.dialogs.firstMatch.waitForNonExistence(timeout: 5)
            record["closed"] = closed
            return problems([
                (asSheet, "the open panel is not a sheet on the window"),
                (closed && prompt.exists, "cancelling the open panel left it open or changed the tab"),
            ])
        }
    }

    /// "Transcribe" in the window's title bar was a bare waveform, and
    /// nothing said it was the button to press. The main action shows its
    /// name beside its icon, so it is much wider than it is tall.
    func testTranscribeButtonShowsItsName() {
        let probe: FileProbeSession
        do {
            probe = try FileProbeSession()
            try probe.openFilesTab()
        } catch {
            return XCTFail("PROBE: launch not prepared: \(error)")
        }
        defer { probe.app.terminate() }
        let button = probe.app.buttons["fileTranscribeButton"]
        guard button.waitForExistence(timeout: 5) else {
            return XCTFail("PROBE: no Transcribe button")
        }
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, frame.height * 2, "REGRESSION: Transcribe is an icon without its name: \(frame)")
    }

    /// №4 as the app wires it: Quit from the app menu while a Files run goes
    /// only warns, and the run goes on; quitting again quits.
    func testQuitDuringAFilesRunWarnsFirstThenQuits() {
        let warning = AppLanguage.text("A file is being transcribed in Files — quit again to stop it")
        let probe: FileProbeSession
        do {
            probe = try FileProbeSession()
            try probe.openFilesTab()
        } catch {
            return XCTFail("PROBE: launch not prepared: \(error)")
        }
        defer {
            probe.releaseAll()
            probe.app.terminate()
        }
        do {
            let a = try probe.makeFile("quit-A.wav")
            try probe.dropApplied("quit-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.quitFromMainMenu()
            guard probe.waitShows(warning) else {
                return XCTFail("REGRESSION: the first Quit did not warn about the Files run")
            }
            XCTAssertTrue(probe.app.buttons["fileCancelButton"].exists, "REGRESSION: the warning stopped the run")
            try probe.quitFromMainMenu()
            XCTAssertTrue(probe.app.wait(for: .notRunning, timeout: 10), "REGRESSION: the second Quit did not quit")
        } catch {
            XCTFail("PROBE: \(error)")
        }
    }

    // MARK: Harness

    private func problems(_ checks: [(Bool, String)]) -> [String] {
        checks.filter { !$0.0 }.map(\.1)
    }

    private func iterate(
        _ scenario: String,
        realPanels: Bool = false,
        _ body: (FileProbeSession, String, inout [String: Any]) throws -> [String]
    ) {
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["FILE_PROBE_ITERATIONS"] ?? "") ?? 1)
        let probe: FileProbeSession
        do {
            probe = try FileProbeSession(realPanels: realPanels)
            try probe.openFilesTab()
        } catch {
            XCTFail("PROBE: launch not prepared: \(error)")
            return
        }
        defer { probe.app.terminate() }

        var counts = ["pass": 0, "regression": 0, "transport": 0]
        for number in 1...iterations {
            let id = "\(scenario)-\(number)-\(UUID().uuidString.prefix(8))"
            var record: [String: Any] = ["id": id, "scenario": scenario, "iteration": number]
            do {
                let found = try body(probe, id, &record)
                let timeouts = probe.timeouts(of: id)
                if !timeouts.isEmpty {
                    // A gate gave up: the observed result is not evidence.
                    throw ProbeTransportError(message: "gates timed out: \(timeouts.joined(separator: ", "))")
                }
                record["outcome"] = found.isEmpty ? "pass" : "regression"
                record["problems"] = found
                for problem in found { XCTFail("REGRESSION: \(problem) [\(id)]") }
            } catch let failure as ProbeTransportError {
                record["outcome"] = "transport"
                record["problems"] = [failure.message]
                XCTFail("PROBE: \(failure.message) [\(id)]")
            } catch {
                record["outcome"] = "transport"
                record["problems"] = ["\(error)"]
                XCTFail("PROBE: \(error) [\(id)]")
            }
            probe.releaseAll()
            let outcome = record["outcome"] as? String ?? "transport"
            counts[outcome, default: 0] += 1
            probe.write(record: record)
            attach(record, named: "iteration-\(id).json")
        }
        let summary: [String: Any] = [
            "id": "\(scenario)-summary", "scenario": scenario, "iterations": iterations,
            "pass": counts["pass"] ?? 0, "regression": counts["regression"] ?? 0,
            "transport": counts["transport"] ?? 0,
        ]
        probe.write(record: summary)
        attach(summary, named: "summary-\(scenario).json")
    }

    private func attach(_ record: [String: Any], named name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
