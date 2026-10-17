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

    /// Every panel is the probe's: a test process never opens a real one.
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Kept after the test so the runner can count iteration files; named
        // here so it is removed by an owned list, not a glob.
        print("FILE-PROBE-ROOT \(root.path)")
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-FileProbeRoot", root.path]
            + AppLanguage.launchArguments
        app.launch()
    }

    func openFilesTab() throws {
        try openWindow()
        guard app.descendants(matching: .any)["fileDropZonePrompt"].waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the Files tab did not open")
        }
    }

    /// Opens the main window on the Files section from the menu bar's
    /// "Transcribe a File…", whatever the window shows.
    func openWindow() throws {
        guard app.transcribeAFileFromMenuBar() else {
            throw ProbeTransportError(message: "the Files section did not open")
        }
    }

    func closeSettings() throws {
        try close(app.windows["settings"])
    }

    /// The window Files is in.
    func closeWindow() throws {
        try close(app.windows["main"])
    }

    private func close(_ window: XCUIElement) throws {
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

    /// Runs the same file again behind a closed gate: the first run's gate,
    /// start and choice acknowledgements are removed, so this run waits and is
    /// seen to start, and an old choice is never taken for its own.
    func restart(_ file: String) throws {
        for name in ["run-\(file).release", "run-\(file).started", "run-\(file).choice"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try start(file)
    }

    func waitRunStarted(_ file: String) throws {
        _ = try read("run-\(file).started")
    }

    /// What the run was started with, as the probe got it: `engine:code`,
    /// or `as dictation`.
    func runChoice(_ file: String) throws -> String {
        try read("run-\(file).choice")
    }

    /// The tab's options menu: the choice it shows.
    var choiceShown: String? {
        app.descendants(matching: .any)["fileChoiceMenu"].value as? String
    }

    /// Picks from the tab's options menu as a person does: an item of an
    /// engine's submenu, the engine found by the start of its name (one not
    /// downloaded carries a note), or the top item when no engine is given.
    func choose(_ item: String, engine: String? = nil) throws {
        let menu = app.descendants(matching: .any)["fileChoiceMenu"]
        guard menu.waitForExistence(timeout: 5), menu.isEnabled else {
            throw ProbeTransportError(message: "the options menu is not available")
        }
        menu.click()
        var scope: XCUIElement = app
        if let engine {
            let submenu = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", engine)).firstMatch
            guard submenu.waitForExistence(timeout: 5) else {
                throw ProbeTransportError(message: "the options menu has no “\(engine)”")
            }
            submenu.hover()
            scope = submenu
        }
        let entry = scope.menuItems[item]
        guard entry.waitForExistence(timeout: 5) else {
            throw ProbeTransportError(message: "the options menu has no “\(item)”")
        }
        entry.click()
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

    /// The open panel's answer: the n-th Choose File… takes `file`.
    func offerChoice(_ file: String, as number: Int) throws {
        try Data(root.appendingPathComponent(file).path.utf8)
            .write(to: root.appendingPathComponent("choose-file-\(number).txt"), options: .atomic)
    }

    /// Every panel from now on waits for its own `present-<n>.release`.
    func holdPanels() throws {
        try Data().write(to: root.appendingPathComponent("present.hold"), options: .atomic)
    }

    func waitPanelHeld(_ number: Int) throws {
        _ = try read("present-\(number).holding")
        openGates.insert("present-\(number).release")
    }

    func releasePanel(_ number: Int) throws {
        try open("present-\(number).release")
    }

    /// The window the n-th panel went on, by its identifier, or "cancelled"
    /// when that window was gone.
    func panelWindow(_ number: Int) throws -> String {
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
        throw ProbeTransportError(message: "the probe did not say where panel \(number) went")
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    /// Opens Settings from the menu bar (third item from its end): it
    /// becomes the key window, over the main one.
    func openSettings() throws {
        let statusItem = app.statusItems.firstMatch
        statusItem.click()
        let items = statusItem.menus.firstMatch.children(matching: .menuItem)
        guard items.count >= 3 else {
            throw ProbeTransportError(message: "the Murmurly menu has too few items")
        }
        items.element(boundBy: items.count - 3).click()
        guard app.windows["settings"].waitForExistence(timeout: 10) else {
            throw ProbeTransportError(message: "no Settings")
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

    /// The options row is there before any file; a choice other than the
    /// settings' reaches the run as its argument, the same file run again over
    /// its text in another choice, through "Replace", reaches that run and
    /// shows its text, and the choice outlives the window, the text and its
    /// file staying too, until "As Dictation" takes the choice back and leaves
    /// the text. Each iteration saves its text, so the next one's file is
    /// taken without a question.
    func testFilesChoiceReachesTheRunAndOutlivesTheWindow() {
        let auto = AppLanguage.text("Auto")
        let asDictation = AppLanguage.text("As Dictation · %@ · %@", "Parakeet", auto)
        let replace = AppLanguage.text("Replace")
        iterate("choice") { probe, id, record in
            let initial = probe.choiceShown
            let a = try probe.makeFile("\(id)-A.wav")
            let text = "transcript \(a)"
            try probe.dropApplied("\(id)-a", a)
            try probe.choose(auto, engine: "Parakeet")
            try probe.start(a)
            try probe.waitRunStarted(a)
            let first = try probe.runChoice(a)
            try probe.releaseRun(a)
            guard probe.waitShows(text) else {
                throw ProbeTransportError(message: "the first run showed no text")
            }
            try probe.choose(auto, engine: "Whisper")
            try probe.restart(a)
            guard probe.waitAsked() else { throw ProbeTransportError(message: "no question over the unsaved text") }
            try probe.answer(replace)
            // Started, so the first run's text is gone: what shows next is this run's.
            try probe.waitRunStarted(a)
            let second = try probe.runChoice(a)
            try probe.releaseRun(a)
            let secondShown = probe.waitShows(text)
            try probe.closeWindow()
            try probe.openWindow()
            let reopened = probe.choiceShown
            let textKept = probe.waitShows(text)
            let fileKept = probe.shows(a)
            try probe.choose(AppLanguage.text("As Dictation (%@ · %@)", "Parakeet", auto))
            let back = probe.choiceShown
            let textLeft = probe.shows(text) && probe.shows(a)
            let save = try probe.clickSave(holding: false)
            let saved = try probe.savedText(save)
            let savedNoted = probe.app.descendants(matching: .any)["fileSavedNote"].waitForExistence(timeout: 5)
            record["initial"] = initial ?? "none"
            record["first"] = first
            record["second"] = second
            record["secondShown"] = secondShown
            record["reopened"] = reopened ?? "none"
            record["textKept"] = textKept
            record["fileKept"] = fileKept
            record["back"] = back ?? "none"
            record["textLeft"] = textLeft
            record["saved"] = saved
            return problems([
                (initial == asDictation, "the row did not start as the dictation: \(initial ?? "none")"),
                (first == "parakeet:auto", "the first run was started with \(first)"),
                (second == "whisper:auto", "the run again was started with \(second)"),
                (secondShown, "the run again showed no text"),
                (reopened == "Whisper · \(auto)", "the window came back with \(reopened ?? "none")"),
                (textKept, "the text did not come back with the window"),
                (fileKept, "the file name did not come back with the window"),
                (back == asDictation, "“As Dictation” left \(back ?? "none")"),
                (textLeft, "“As Dictation” took the text or its file name"),
                (saved == text && savedNoted, "the text was not saved for the next iteration: \(saved)"),
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

    /// A drop answered while the Dictionary tab's entry sheet stays over
    /// unsaved text after a tab change: the sheet, its draft and the text
    /// stay, the question about the text waits until the sheet is answered,
    /// and its Cancel keeps the text. Nothing in the window starts the second
    /// sheet: the drop's answer was on its way before the first one opened.
    func testADropAnsweredUnderTheEntrySheetAsksOnceTheSheetIsAnswered() {
        let cancel = AppLanguage.text("Cancel")
        let replace = AppLanguage.text("Replace")
        iterate("entry-sheet") { probe, id, record in
            let app = probe.app
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

            guard app.showMainSection("dictionary") else {
                throw ProbeTransportError(message: "the Dictionary section did not show")
            }
            let add = app.buttons["dictionaryAdd"]
            guard add.waitForExistence(timeout: 5) else {
                throw ProbeTransportError(message: "the Dictionary section did not show")
            }
            add.click()
            let heard = app.textFields["dictionaryHeardField"]
            guard heard.waitForExistence(timeout: 5) else {
                throw ProbeTransportError(message: "Add… opened no sheet")
            }
            heard.click()
            // Digits only: they do not depend on the active keyboard layout.
            heard.typeText("42")
            guard app.transcribeAFileFromMenuBar() else {
                throw ProbeTransportError(message: "the Files tab did not show")
            }
            try probe.release("\(id)-b")
            // Long enough for the answer to have gone through the tab.
            let sheetStayed = !heard.waitForNonExistence(timeout: 2)
            let running = app.state == .runningForeground
            let draftKept = sheetStayed && heard.value as? String == "42"
            let textKept = probe.shows(a) && probe.shows("transcript \(a)") && !probe.shows(b)
            let waited = !app.sheets.buttons[replace].firstMatch.exists
            record["sheetStayed"] = sheetStayed
            record["draftKept"] = draftKept
            record["textKept"] = textKept
            record["questionWaited"] = waited
            var found = problems([
                (running, "the app did not survive the drop's answer"),
                (sheetStayed, "the entry sheet went away"),
                (draftKept, "the entry sheet lost its draft"),
                (textKept, "the unsaved text changed under the sheet"),
                (waited, "the question came while the entry sheet was up"),
            ])
            guard running, sheetStayed else { return found }

            app.buttons["dictionaryCancel"].click()
            guard heard.waitForNonExistence(timeout: 5) else {
                return found + ["the entry sheet stayed after Cancel"]
            }
            let asked = app.sheets.buttons[replace].firstMatch.waitForExistence(timeout: 5)
            record["askedAfterTheSheet"] = asked
            guard asked else { return found + ["the question about the unsaved text never came"] }
            try probe.answer(cancel)
            let keptAfterCancel = probe.shows(a) && probe.shows("transcript \(a)") && !probe.shows(b)
            record["keptAfterCancel"] = keptAfterCancel
            found += problems([(keptAfterCancel, "“Cancel” did not keep A, its text and its name")])

            // The next iteration starts without unsaved text.
            try probe.dropPending("\(id)-b2", b)
            try probe.release("\(id)-b2")
            if probe.waitAsked() { try probe.answer(replace) }
            return found
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

    /// Every panel of the tab goes on the window its button is in, and its
    /// answer is the tab's: Choose File… takes the file; "Save .md…" in the
    /// replace question goes on the window, not on the question on its way
    /// out, saves, then takes the new file; Save .md writes the text.
    func testEveryPanelOfTheTabGoesOnItsWindow() {
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
            let a = try probe.makeFile("owner-A.wav")
            let b = try probe.makeFile("owner-B.wav")
            try probe.offerChoice(a, as: 1)
            probe.app.buttons["fileChooseButton"].click()
            let window1 = try probe.panelWindow(1)
            XCTAssertTrue(window1.hasPrefix("main"), "Choose File… went elsewhere: \(window1)")
            XCTAssertTrue(probe.waitShows(a), "the chosen file was not taken")
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            XCTAssertTrue(probe.waitShows("transcript \(a)"), "run A showed no text")

            try probe.offerChoice(b, as: 2)
            probe.app.buttons["fileChooseButton"].click()
            let window2 = try probe.panelWindow(2)
            XCTAssertTrue(window2.hasPrefix("main"), "panel 2 went elsewhere: \(window2)")
            XCTAssertTrue(probe.waitAsked(), "B replaced the unsaved text of A without asking")
            let first = try probe.expectSave()
            try probe.answer(AppLanguage.text("Save .md…"))
            let window3 = try probe.panelWindow(3)
            XCTAssertTrue(window3.hasPrefix("main"), "Save .md… went elsewhere: \(window3)")
            XCTAssertEqual(try probe.savedText(first), "transcript \(a)")
            XCTAssertTrue(probe.waitShows(b) && !probe.shows("transcript \(a)"), "B was not taken after the save")

            try probe.start(b)
            try probe.waitRunStarted(b)
            try probe.releaseRun(b)
            XCTAssertTrue(probe.waitShows("transcript \(b)"), "run B showed no text")
            let second = try probe.clickSave(holding: false)
            let window4 = try probe.panelWindow(4)
            XCTAssertTrue(window4.hasPrefix("main"), "panel 4 went elsewhere: \(window4)")
            XCTAssertEqual(try probe.savedText(second), "transcript \(b)")
        } catch {
            XCTFail("PROBE: \(error)")
        }
    }

    /// A panel held between the click and its coming goes on the window it
    /// was asked from even with another window made key meanwhile; with its
    /// window closed meanwhile, it comes nowhere: nothing is written, and
    /// the text stays, unsaved.
    func testAHeldPanelGoesOnItsOwnWindowOrNowhere() {
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
            let a = try probe.makeFile("held-A.wav")
            try probe.dropApplied("held-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            XCTAssertTrue(probe.waitShows("transcript \(a)"), "run A showed no text")
            try probe.holdPanels()

            let first = try probe.clickSave(holding: false)
            try probe.waitPanelHeld(1)
            try probe.openSettings()
            try probe.releasePanel(1)
            let window1 = try probe.panelWindow(1)
            XCTAssertTrue(window1.hasPrefix("main"), "the panel went on the key window: \(window1)")
            XCTAssertEqual(try probe.savedText(first), "transcript \(a)")
            // Settings may cover the section: it goes before the section is used again.
            try probe.closeSettings()

            // Run again: a new result, unsaved, over the saved one.
            try probe.start(a)
            XCTAssertTrue(probe.app.staticTexts["fileUnsavedNote"].waitForExistence(timeout: 10), "the new result passed for saved")
            probe.app.buttons["fileSaveButton"].click()
            try probe.waitPanelHeld(2)
            try probe.closeWindow()
            try probe.releasePanel(2)
            XCTAssertEqual(try probe.panelWindow(2), "cancelled", "a panel came for a window that was gone")
            XCTAssertFalse(probe.exists("save-2.txt"), "the closed window's save went on")
            try probe.openWindow()
            XCTAssertTrue(probe.waitShows("transcript \(a)"), "the text went with the window")
            XCTAssertTrue(probe.app.staticTexts["fileUnsavedNote"].waitForExistence(timeout: 5), "a save that never came passed for saved")
        } catch {
            XCTFail("PROBE: \(error)")
        }
    }

    /// "Save .md…" from the replace question, its panel held and its window
    /// closed meanwhile: nothing is saved, the new file is not taken, and
    /// the text, unsaved, is there when the window comes back.
    func testAHeldSaveFromTheQuestionComesNowhereWithItsWindow() {
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
            let a = try probe.makeFile("question-A.wav")
            let b = try probe.makeFile("question-B.wav")
            try probe.dropApplied("question-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            XCTAssertTrue(probe.waitShows("transcript \(a)"), "run A showed no text")
            try probe.dropPending("question-b", b)
            try probe.release("question-b")
            XCTAssertTrue(probe.waitAsked(), "B replaced the unsaved text of A without asking")
            try probe.holdPanels()
            try probe.answer(AppLanguage.text("Save .md…"))
            try probe.waitPanelHeld(1)
            try probe.closeWindow()
            try probe.releasePanel(1)
            XCTAssertEqual(try probe.panelWindow(1), "cancelled", "a panel came for a window that was gone")
            XCTAssertFalse(probe.exists("save-1.txt"), "the save went on without its window")
            try probe.openWindow()
            XCTAssertTrue(probe.waitShows("transcript \(a)"), "the text went with the window")
            XCTAssertTrue(probe.shows(a) && !probe.shows(b), "the new file was taken without the save")
            XCTAssertTrue(probe.app.staticTexts["fileUnsavedNote"].waitForExistence(timeout: 5), "a save that never came passed for saved")
            XCTAssertTrue(probe.app.buttons["fileSaveButton"].isEnabled, "Save .md stayed off")
        } catch {
            XCTFail("PROBE: \(error)")
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

    /// Text in Files not saved yet, the window now the main one's: Quit
    /// from the app menu only warns, and the text stays; quitting again
    /// quits.
    func testQuitWithUnsavedFilesTextWarnsFirstThenQuits() {
        let warning = AppLanguage.text("Files has unsaved text — save it as .md, or quit again to discard it")
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
            let a = try probe.makeFile("unsaved-A.wav")
            try probe.dropApplied("unsaved-a", a)
            try probe.start(a)
            try probe.waitRunStarted(a)
            try probe.releaseRun(a)
            guard probe.waitShows("transcript \(a)") else { return XCTFail("PROBE: run A showed no text") }
            try probe.quitFromMainMenu()
            guard probe.waitShows(warning) else {
                return XCTFail("REGRESSION: the first Quit did not warn about the unsaved text")
            }
            XCTAssertTrue(probe.shows("transcript \(a)"), "REGRESSION: the warning dropped the text")
            try probe.quitFromMainMenu()
            XCTAssertTrue(probe.app.wait(for: .notRunning, timeout: 10), "REGRESSION: the second Quit did not quit")
        } catch {
            XCTFail("PROBE: \(error)")
        }
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
        _ body: (FileProbeSession, String, inout [String: Any]) throws -> [String]
    ) {
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["FILE_PROBE_ITERATIONS"] ?? "") ?? 1)
        let probe: FileProbeSession
        do {
            probe = try FileProbeSession()
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
