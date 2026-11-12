import AppKit
import ApplicationServices
import CoreGraphics
import XCTest

/// `-NotepadProbe` fakes a recording with a few made-up lines, so the
/// notepad window shows without a capture or an engine. A separate probe
/// from `-LiveTranscriptProbe` (`LiveTranscriptPanelUITests`), so the two
/// never collide.
@MainActor
final class NotepadWindowUITests: XCTestCase {
    private func launch(_ extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-NotepadProbe"] + extraArguments
            + AppLanguage.launchArguments
        app.launch()
        return app
    }

    /// `XCUIApplication` has no `processIdentifier` on macOS; the running
    /// copy's own pid is read by diffing `NSWorkspace`'s list of processes
    /// with this bundle ID across the launch, so an already-running install
    /// on the same Mac is never mistaken for the one just launched.
    private func launchTrackingPID(_ extraArguments: [String]) -> (app: XCUIApplication, pid: pid_t)? {
        let bundleID = "io.github.spacevibes365.Murmurly"
        let before = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleID }
                .map(\.processIdentifier)
        )
        let app = launch(extraArguments)
        guard let pid = waitUntilNotNil(timeout: 5, {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID && !before.contains($0.processIdentifier) }?
                .processIdentifier
        }) else { return nil }
        return (app, pid)
    }

    private func waitUntil(seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// `CGEvent.post(tap: .cghidEventTap)` only delivers if this process is
    /// trusted to post HID events; a test runner rebuilt for every run never
    /// is (`CGPreflightPostEventAccess()` is false there). Skip rather than
    /// let the click silently no-op,
    /// which would make a passing test indistinguishable from a broken fix.
    private func skipIfNotTrustedToPostEvents() throws {
        try XCTSkipUnless(
            CGPreflightPostEventAccess(),
            "this runner is not trusted to post HID events (CGPreflightPostEventAccess is false): "
                + "a raw click never arrives, so the test proves nothing here; check it by hand"
        )
    }

    /// A real HID click at the element's own screen position, not
    /// `XCUIElement.click()`: XCTest's own synthesis activates the target
    /// app regardless of where the click lands — a raw HID click proves the
    /// system's own activation behavior, not XCTest's.
    private func rawClick(on element: XCUIElement) {
        let point = CGPoint(x: element.frame.midX, y: element.frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func waitUntilNotNil<T>(timeout: TimeInterval = 5, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = value() { return result }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return value()
    }

    /// Front-to-back on-screen window numbers, as `CGWindowListCopyWindowInfo`
    /// reports them (same coordinate and ordering space `rawClick`'s own
    /// `CGEvent` posting already relies on).
    private func frontToBackWindowNumbers() -> [Int] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])?
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue } ?? []
    }

    /// Launches Calculator and waits for it to become the front app, then
    /// registers its termination in a teardown block so nothing is left on
    /// screen once the test ends. Calculator, not Finder: XCUITest launches
    /// and terminates it itself, so no window is left behind for the next
    /// test to collide with, and Finder's own windows can't be closed
    /// without Accessibility or Automation — a hidden one returns on
    /// Finder's next activation and covers the notepad in a later test.
    private func bringCalculatorToFront() -> (app: XCUIApplication, pid: pid_t)? {
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.launch()
        addTeardownBlock { calculator.terminate() }
        guard let calculatorPID = waitUntilNotNil(timeout: 10, {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.calculator" }?
                .processIdentifier
        }) else {
            XCTFail("Calculator never launched")
            return nil
        }
        guard waitUntil(seconds: 10, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.calculator" }) else {
            XCTFail("Calculator never became the front app")
            return nil
        }
        return (calculator, calculatorPID)
    }

    /// The on-screen window numbers a process owns, through `kCGWindowOwnerPID`
    /// (public, no permission needed, unlike `kCGWindowName`). Reading a
    /// foreign window's own bounds or moving it needs Accessibility, which a
    /// UI test runner rebuilt for every run does not have (its binary's
    /// CDHash, and so any grant, differs every run); the tests below prove the defect's fix by window *order* alone,
    /// never by reading or moving another process's window.
    private func windowNumbers(ownedBy pid: pid_t) -> [Int] {
        let entries = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) == pid else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
        }
    }

    /// The front-most (lowest) index among `numbers` in `order`, or nil if
    /// none of them are currently on screen.
    private func frontmostIndex(of numbers: [Int], in order: [Int]) -> Int? {
        numbers.compactMap { order.firstIndex(of: $0) }.min()
    }

    /// The notepad appearing by itself — a recording starting, with no click
    /// from the user — must not take the front app: `render()` always shows
    /// it with `orderFrontRegardless()`, never `makeKey`/`activate`.
    /// `-UITesting` itself runs `.regular` (so this does not also prove there
    /// is no Dock icon — `LiveTranscriptPanelTests.testWindowIsAnActivatingPanelThatBecomesKeyOnClick`
    /// does that).
    func testShowingTheNotepadKeepsTheFrontApp() throws {
        // The probe's clock runs from the process's own launch, and Calculator
        // must already be in front when the notepad appears; 15 s leaves room
        // for a slow Calculator launch, as in the typing test below.
        let app = launch(["-NotepadProbeStartAfter", "15"])
        defer { app.terminate() }

        guard bringCalculatorToFront() != nil else { return }
        let stateLabel = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertFalse(stateLabel.exists, "the probe's notepad appeared before its own delay")

        XCTAssertTrue(stateLabel.waitForExistence(timeout: 30), "the notepad never appeared")
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.calculator",
            "showing the notepad took the front app"
        )
        XCTAssertTrue(app.buttons["notepadStopButton"].waitForExistence(timeout: 5))
        // A `Toggle(…).toggleStyle(.button)`, not a plain `Button`: found
        // like `meetingPlayerTrack.*` in `MeetingsWindowTests`, not through
        // `app.buttons`.
        XCTAssertTrue(app.descendants(matching: .any)["notepadPinButton"].exists)
    }

    /// The defect: a click on the notepad raised it only through our own
    /// `sendEvent` override, never activating Murmurly, and the raise did
    /// not hold once the front app reasserted its own windows. Now a click
    /// behaves as a click on any app's window: it activates Murmurly, by pid
    /// rather than bundle ID (an installed copy on the same Mac may share
    /// this bundle ID), and the notepad stays on top. Calculator's own
    /// window — launched and terminated by XCUITest itself through
    /// `bringCalculatorToFront()`, so nothing is left on screen afterward —
    /// is never moved or read for its own bounds (that needs Accessibility,
    /// unavailable to a test runner rebuilt for every run; see
    /// `windowNumbers(ownedBy:)`). `frontToBackWindowNumbers` reads
    /// `.optionOnScreenOnly`, so the notepad appearing in it at all also
    /// proves `hidesOnDeactivate` is off. Whether the raise holds over every
    /// other app is not provable by a headless test; it is checked by hand.
    func testAClickOnTheNotepadBringsItAndMurmurlyForward() throws {
        try skipIfNotTrustedToPostEvents()
        guard let (app, pid) = launchTrackingPID(["-NotepadProbeStartAfter", "0"]) else {
            return XCTFail("could not find the newly launched copy's process id")
        }
        defer { app.terminate() }

        let stateLabel = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 15), "the notepad never appeared")

        guard let (calculator, calculatorPID) = bringCalculatorToFront() else { return }

        func indices() -> (notepad: Int, calculator: Int)? {
            let order = frontToBackWindowNumbers()
            guard let notepadIndex = frontmostIndex(of: windowNumbers(ownedBy: pid), in: order),
                  let calculatorIndex = frontmostIndex(of: windowNumbers(ownedBy: calculatorPID), in: order)
            else { return nil }
            return (notepadIndex, calculatorIndex)
        }

        XCTAssertTrue(
            waitUntil { indices().map { $0.calculator < $0.notepad } ?? false },
            "the notepad never fell behind Calculator's window — the test's own setup failed, not the fix"
        )

        rawClick(on: stateLabel)

        XCTAssertTrue(
            waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
            "the click on the notepad did not bring Murmurly forward"
        )
        XCTAssertTrue(
            waitUntil { indices().map { $0.notepad < $0.calculator } ?? false },
            "the click did not raise the notepad over Calculator's window"
        )
        // The defect was that this did not hold: the front app took its
        // windows, and with them the order, back.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(
            waitUntil { indices().map { $0.notepad < $0.calculator } ?? false },
            "the notepad fell back behind Calculator's window within 2 s of the click"
        )

        calculator.activate()
        XCTAssertTrue(
            waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == calculatorPID },
            "Calculator never became the front app again"
        )
        XCTAssertTrue(
            waitUntil { indices().map { $0.calculator < $0.notepad } ?? false },
            "the notepad never fell behind Calculator's window again"
        )

        let markMomentButton = app.buttons["markMomentButton"]
        XCTAssertTrue(markMomentButton.exists)
        rawClick(on: markMomentButton)

        XCTAssertTrue(
            waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
            "a click on ★ did not bring Murmurly forward"
        )
        XCTAssertTrue(
            waitUntil { indices().map { $0.notepad < $0.calculator } ?? false },
            "a click on ★ did not raise the notepad over Calculator's window"
        )
    }

    /// "Show Live Transcript" is the explicit, reliable way back: unlike a
    /// click or an activation, driving it is an ordinary XCUITest element
    /// click (menu items work through the accessibility tree, not raw HID),
    /// so it needs no `CGPreflightPostEventAccess` trust and runs on an
    /// untrusted test runner. The notepad is already visible here, merely
    /// covered by another app's window: the item now does something even
    /// while shown, not only after the ✕. Since `show()` now calls
    /// `NSApp.activate()` (the menu item itself does not activate the app),
    /// Murmurly becomes the front process too, by pid rather than bundle ID
    /// (an installed copy on the same Mac may share it).
    ///
    /// The other app is Calculator, launched and terminated by XCUITest
    /// itself through `bringCalculatorToFront()`, so nothing is left on
    /// screen. A window of the test runner's own process never appeared in
    /// the on-screen `CGWindowList` of a headless run, and Finder can't be used:
    /// its windows can't be closed without Accessibility or Automation, and
    /// hidden ones come back on its next activation, covering the notepad in
    /// later tests.
    func testShowLiveTranscriptRaisesTheNotepadOverAnotherAppsWindow() throws {
        guard let (app, pid) = launchTrackingPID(["-NotepadProbeStartAfter", "0"]) else {
            return XCTFail("could not find the newly launched copy's process id")
        }
        defer { app.terminate() }

        let stateLabel = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 15), "the notepad never appeared")

        guard let (_, calculatorPID) = bringCalculatorToFront() else { return }

        func indices() -> (notepad: Int, calculator: Int)? {
            let order = frontToBackWindowNumbers()
            guard let notepadIndex = frontmostIndex(of: windowNumbers(ownedBy: pid), in: order),
                  let calculatorIndex = frontmostIndex(of: windowNumbers(ownedBy: calculatorPID), in: order)
            else { return nil }
            return (notepadIndex, calculatorIndex)
        }

        XCTAssertTrue(
            waitUntil { indices().map { $0.calculator < $0.notepad } ?? false },
            "the notepad never fell behind Calculator's window — the test's own setup failed, not the fix"
        )

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no Murmurly item in the menu bar")
        statusItem.click()
        let showItem = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Show Live Transcript")]
        XCTAssertTrue(showItem.waitForExistence(timeout: 5), "the menu has no Show Live Transcript while the notepad is shown")
        showItem.click()

        XCTAssertTrue(
            waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
            "Show Live Transcript did not bring Murmurly forward"
        )
        XCTAssertTrue(
            waitUntil { indices().map { $0.notepad < $0.calculator } ?? false },
            "the menu item did not raise the notepad over Calculator's window"
        )
        // The activation a menu click can cause must not let WindowServer
        // hand the front position, and with it the order, back to Calculator.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(
            waitUntil { indices().map { $0.notepad < $0.calculator } ?? false },
            "the notepad fell back behind Calculator's window within 2 s of the menu click"
        )
    }

    /// The fed-in lines are not checked on screen here; the lines surviving
    /// the stop are proven at the model level, in
    /// `NotepadWindowTests.testStopKeepsTheModelsLinesAndTheSameMeeting`.
    /// This checks only what is drawn here: the window stays,
    /// "Meeting saved", Stop is gone, Open in Murmurly and ✕ are there, and
    /// the menu brings it back after the ✕.
    func testWindowStaysAfterTheStopAndTheMenuBringsItBack() {
        let app = launch(["-NotepadProbeStopAfter", "3"])
        defer { app.terminate() }

        let stateLabel = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 10), "the notepad never appeared")

        let saved = AppLanguage.text("Meeting saved")
        let savedPredicate = NSPredicate(format: "label == %@ OR value == %@", saved, saved)
        XCTAssertTrue(
            waitUntil(seconds: 10) { stateLabel.exists && savedPredicate.evaluate(with: stateLabel) },
            "the notepad never showed \"Meeting saved\""
        )
        XCTAssertFalse(app.buttons["notepadStopButton"].exists, "Stop is still offered after the meeting stopped")
        XCTAssertTrue(app.buttons["notepadOpenButton"].exists, "no Open in Murmurly after the stop")

        let closeButton = app.buttons["liveTranscriptCloseButton"]
        XCTAssertTrue(closeButton.exists)
        closeButton.click()
        XCTAssertTrue(stateLabel.waitForNonExistence(timeout: 5), "the ✕ did not close the notepad")

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no Murmurly item in the menu bar")
        statusItem.click()
        let showItem = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Show Live Transcript")]
        XCTAssertTrue(showItem.waitForExistence(timeout: 5), "the menu has no Show Live Transcript")
        showItem.click()

        XCTAssertTrue(
            waitUntil(seconds: 5) { stateLabel.exists && savedPredicate.evaluate(with: stateLabel) },
            "the menu item did not bring back the stopped meeting"
        )
    }

    /// What the key at this physical place types in the active layout, as
    /// `NotepadSearchUITests.physicalCharacter(of:)`.
    private func physicalCharacter(of virtualKey: CGKeyCode) -> String? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) else { return nil }
        var count = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: count)
    }

    /// A click in the note field activates Murmurly and makes the notepad
    /// key, as any window; typing goes there.
    func testTypingIntoTheNoteFieldWorksWithAnotherAppInFront() throws {
        // The probe's clock runs from the process's own launch, and some of
        // its 15 s delay is already spent bringing Calculator to the front
        // before the notepad appears; the wait below covers that with margin.
        let app = launch(["-NotepadProbeStartAfter", "15"])
        defer { app.terminate() }

        guard bringCalculatorToFront() != nil else { return }
        let stateLabel = app.staticTexts["liveTranscriptStateLabel"]
        XCTAssertTrue(stateLabel.waitForExistence(timeout: 30), "the notepad never appeared")

        let field = app.textFields["notepadNoteField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("Check the agenda")
        XCTAssertEqual(field.value as? String, "Check the agenda")

        if let a = physicalCharacter(of: 0), a == "a" {
            app.typeKey("a", modifierFlags: .command)
            field.typeText("x")
            XCTAssertEqual(field.value as? String, "x", "⌘A then typing must select all and replace it")
        }

        // ⌘W closes the panel even while it only records a fake meeting.
        if let w = physicalCharacter(of: 13), w == "w" {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(stateLabel.waitForNonExistence(timeout: 5), "⌘W did not close the notepad")
        }
    }
}
