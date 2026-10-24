import AppKit
import Foundation
import KeyboardShortcuts
import XCTest
@testable import Murmurly

/// Stands in for the real microphone at the seams Esc exercises: a start that
/// can be held before recording begins (racing Esc against the watchdog or a
/// late success), and a stop that can be held open (racing Esc against quit).
private actor EscapeMic: MicCapturing {
    enum StartMode {
        case immediate
        case heldBeforeRecording
    }

    private let template: URL
    private let mode: StartMode
    private let holdsStop: Bool
    private var startGate: CheckedContinuation<Void, Never>?
    private var stopGate: CheckedContinuation<Void, Never>?
    private var recording = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var sources: [URL] = []

    init(template: URL, mode: StartMode, holdsStop: Bool = false) {
        self.template = template
        self.mode = mode
        self.holdsStop = holdsStop
    }

    func start() async throws {
        starts += 1
        switch mode {
        case .immediate:
            recording = true
        case .heldBeforeRecording:
            await withCheckedContinuation { startGate = $0 }
            recording = true
        }
    }

    func isHoldingStart() -> Bool { startGate != nil }
    func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    func isHoldingStop() -> Bool { stopGate != nil }
    func releaseStop() {
        stopGate?.resume()
        stopGate = nil
    }

    func isRecording() -> Bool { recording }

    func stop() async throws -> URL? {
        stops += 1
        guard recording else { return nil }
        recording = false
        if holdsStop {
            await withCheckedContinuation { stopGate = $0 }
        }
        let url = template.deletingLastPathComponent()
            .appendingPathComponent("escape-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: template, to: url)
        sources.append(url)
        return url
    }
}

/// Lets a test hold a delivery open after it has started, through the
/// existing `DeliveryHook` the fixture already wires into `deliver`.
@MainActor
private final class DeliveryGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markStarted() { started = true }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// A clock a hold is measured against, as in `HoldToTalkTests`.
@MainActor
private final class EscapeHoldClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
final class EscapeCancelTests: XCTestCase {
    private static let historyNotSavedWarning = IndicatorState.dictationFailure(
        message: "History not saved — the text is in the “M” menu"
    )

    private func makeFixture(
        text: String,
        mode: EscapeMic.StartMode = .immediate,
        holdsStop: Bool = false
    ) throws -> (fixture: DictationPipelineFixture, mic: EscapeMic) {
        let fixture = try DictationPipelineFixture(
            text: text,
            makeMic: { EscapeMic(template: $0, mode: mode, holdsStop: holdsStop) }
        )
        let mic = try XCTUnwrap(fixture.activeMic as? EscapeMic)
        fixture.coordinator.modifierFlagsForTesting = { [] }
        return (fixture, mic)
    }

    /// Confirms the event actually reached `escapePressed`, not merely that it
    /// was queued on the listener's stream.
    private func pressEscapeAndWait(
        _ fixture: DictationPipelineFixture,
        timeout: Duration = .seconds(5)
    ) async throws {
        let before = fixture.coordinator.escapeEventsHandledForTesting
        XCTAssertTrue(fixture.coordinator.pressEscapeForTesting())
        try await waitForDictation(timeout: timeout) {
            fixture.coordinator.escapeEventsHandledForTesting == before + 1
        }
    }

    /// KeyboardShortcuts reads only `UserDefaults.standard`; the value goes
    /// into this process's volatile argument domain, read first and restored
    /// in `defer`, for the whole body including every wait inside it.
    private func withPasteShortcut(
        _ value: Any,
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overridden = original
        overridden["KeyboardShortcuts_pasteLastDictation"] = value
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        try await body()
    }

    private func breakArchive(_ fixture: DictationPipelineFixture) throws {
        try Data("not a directory".utf8).write(to: fixture.root)
    }

    private func press(_ fixture: DictationPipelineFixture) -> Task<Void, Never>? {
        fixture.coordinator.pasteLastKeyDownForTesting()
        return fixture.coordinator.pasteLastKeyUpForTesting()
    }

    /// A plain mutable flag for the `finish` helper below: strict concurrency
    /// forbids a captured `var`, as in `AutoPasteTests`.
    @MainActor
    private final class Flag {
        var raised = false
    }

    private func finish(_ task: Task<Void, Never>?, within timeout: Duration = .seconds(5)) async throws {
        let task = try XCTUnwrap(task)
        let done = Flag()
        Task { @MainActor in
            await task.value
            done.raised = true
        }
        try await waitForDictation(timeout: timeout) { done.raised }
        if !done.raised { task.cancel() }
    }

    /// Same shape as `finish` above, but for `beginTermination`'s
    /// `Task<Bool, Never>`: bounds the wait instead of an unlimited
    /// `await task.value`, so a regression that never finishes termination
    /// fails at this assertion instead of hanging past it.
    @MainActor
    private final class TerminationOutcome {
        var finished = false
        var succeeded = false
    }

    private func finishTermination(
        _ task: Task<Bool, Never>,
        within timeout: Duration = .seconds(5)
    ) async throws {
        let outcome = TerminationOutcome()
        Task { @MainActor in
            outcome.succeeded = await task.value
            outcome.finished = true
        }
        try await waitForDictation(timeout: timeout) { outcome.finished }
        if !outcome.finished {
            task.cancel()
            XCTFail("beginTermination did not finish within \(timeout)")
            return
        }
        XCTAssertTrue(outcome.succeeded)
    }

    /// Releases a gate (the mic's held start/stop, the engine's held decode,
    /// a held delivery) whether the body succeeds or throws, so a failing
    /// assertion never leaves a fixture's `cleanup()` deleting files a
    /// suspended continuation still points at.
    private func runReleasingGate(
        releasing: @escaping @MainActor () async -> Void,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            await releasing()
            throw error
        }
        await releasing()
    }

    /// Ends a test that holds gates the same way whether the body succeeds or
    /// throws: release every gate, wait (bounded) until the coordinator is
    /// idle and no Esc is registered, and only then let the caller's own
    /// `defer { fixture.cleanup() }` delete files and settings.
    private func runSettling(
        _ fixture: DictationPipelineFixture,
        releasing: @escaping @MainActor () async -> Void,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            await settle(fixture, releasing)
            throw error
        }
        await settle(fixture, releasing)
    }

    private func settle(
        _ fixture: DictationPipelineFixture,
        _ releasing: @MainActor () async -> Void
    ) async {
        await releasing()
        try? await waitForDictation(timeout: .seconds(30)) {
            fixture.coordinator.state == .idle && !fixture.coordinator.isEscapeListenerOpenForTesting
        }
    }

    // MARK: - 1–2: saved but not pasted

    func testEscapeWhileRecordingSavesButDoesNotPaste() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "some words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let custom = KeyboardShortcuts.Shortcut(.v, modifiers: [.control, .command])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))

        try await withPasteShortcut(stored) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            try await self.pressEscapeAndWait(fixture)
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(recent.map(\.text), ["some words"])
            XCTAssertNotEqual(recent.first?.audioPath, "")
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .notice(message: "Cancelled — not pasted. \(custom.description) pastes it")
            )
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        }
    }

    func testEscapeWhileRecognizingSavesButDoesNotPaste() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "recognizing words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        fixture.settings.saveDictationAudio = false
        await fixture.engine.holdDecodes()

        try await withPasteShortcut(false) {
            try await self.runReleasingGate(releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.beginCaptureForTesting()
                try await waitForDictation { fixture.coordinator.state == .recording }
                fixture.coordinator.toggle()
                try await waitForDictation { await fixture.engine.isHoldingDecode() }
                XCTAssertFalse(fixture.coordinator.skipsDeliveryForTesting)

                try await self.pressEscapeAndWait(fixture)
                // Confirmed marked while the decode is still held: the
                // cancellation happened during recognition, not later.
                XCTAssertTrue(fixture.coordinator.skipsDeliveryForTesting)
                let stillHeld = await fixture.engine.isHoldingDecode()
                XCTAssertTrue(stillHeld)

                await fixture.engine.releaseHeldDecode()
                try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
                XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)

                let recent = try await fixture.store.recent(limit: 10)
                XCTAssertEqual(recent.map(\.text), ["recognizing words"])
                XCTAssertEqual(recent.first?.audioPath, "")
                let source = await mic.sources.first
                if let source {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
                }
                let delivered = await fixture.probe.deliveredTexts
                XCTAssertTrue(delivered.isEmpty)
                XCTAssertEqual(
                    fixture.indicator.presentedState,
                    .notice(message: "Cancelled — the text is in Dictations")
                )
            }
        }
    }

    // MARK: - 3: cancelled before recording started

    func testEscapeWhileStartingCancelsTheAttempt() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused", mode: .heldBeforeRecording)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        try await runReleasingGate(releasing: { await mic.releaseStart() }) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { await mic.isHoldingStart() }
            XCTAssertEqual(fixture.coordinator.state, .starting)

            try await self.pressEscapeAndWait(fixture)
            try await waitForDictation {
                fixture.coordinator.state == .transcribing
                    && fixture.indicator.presentedState == .notice(message: "Cancelled")
            }

            await mic.releaseStart()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let starts = await mic.starts
            XCTAssertEqual(starts, 1)
            let stops = await mic.stops
            XCTAssertEqual(stops, 2)
            let sources = await mic.sources
            for source in sources {
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            }
            let requests = await fixture.engine.requests
            XCTAssertTrue(requests.isEmpty)
            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertTrue(recent.isEmpty)
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        }
    }

    // MARK: - 4: ⌃⌘V brings the cancelled dictation back

    func testPasteLastBringsBackTheCancelledDictation() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        // (a) A healthy archive: the cancelled dictation never pastes, but
        // ⌃⌘V still finds and pastes it afterward.
        let (fixture, _) = try makeFixture(text: "older words")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        try await fixture.dictate()
        let deliveredAfterFirst = await fixture.probe.deliveredTexts
        XCTAssertEqual(deliveredAfterFirst, ["older words"])

        await fixture.engine.setText("newer words")
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        try await pressEscapeAndWait(fixture)
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
        XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        let deliveredAfterEscape = await fixture.probe.deliveredTexts
        XCTAssertEqual(deliveredAfterEscape, ["older words"])

        let task = press(fixture)
        try await finish(task)
        let deliveredAfterPaste = await fixture.probe.deliveredTexts
        XCTAssertEqual(deliveredAfterPaste, ["older words", "newer words"])

        // (b) A broken archive: the cancelled dictation is never pasted and
        // never touches the clipboard, stays honestly in the unsaved list
        // (not "in Dictations"), and ⌃⌘V still brings it back.
        let (fixture2, mic2) = try makeFixture(text: "unsaved words")
        defer {
            fixture2.coordinator.cancelPasteLastForTesting()
            fixture2.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        try breakArchive(fixture2)
        let changeCount = NSPasteboard.general.changeCount

        fixture2.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture2.coordinator.state == .recording }
        try await pressEscapeAndWait(fixture2)
        try await waitForDictation(timeout: .seconds(30)) { fixture2.coordinator.state == .idle }
        XCTAssertFalse(fixture2.coordinator.isEscapeListenerOpenForTesting)

        let delivered2 = await fixture2.probe.deliveredTexts
        XCTAssertTrue(delivered2.isEmpty)
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
        XCTAssertEqual(fixture2.indicator.presentedState, Self.historyNotSavedWarning)
        XCTAssertEqual(fixture2.coordinator.unsavedDictations.map(\.text), ["unsaved words"])
        let sources2 = await mic2.sources
        let source2 = try XCTUnwrap(sources2.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source2.path))

        let task2 = press(fixture2)
        try await finish(task2)
        let deliveredAfterPaste2 = await fixture2.probe.deliveredTexts
        XCTAssertEqual(deliveredAfterPaste2, ["unsaved words"])
    }

    // MARK: - 5: idle changes nothing

    func testEscapeWhenIdleChangesNothing() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        XCTAssertFalse(fixture.coordinator.pressEscapeForTesting())

        fixture.coordinator.escapePressedForTesting()
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertNil(fixture.indicator.presentedState)
        let starts = await mic.starts
        XCTAssertEqual(starts, 0)
        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }

    // MARK: - 6: a hold's release after Esc does nothing

    func testReleaseAfterEscapeDoesNothing() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "escape hold words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let clock = EscapeHoldClock()
        fixture.coordinator.startSkipsDeviceGatesForTesting = true
        fixture.coordinator.holdClockForTesting = { clock.now }

        try await withPasteShortcut(false) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { fixture.coordinator.state == .recording }
            clock.advance(.milliseconds(100)) // shorter than the 500 ms hold threshold
            try await self.pressEscapeAndWait(fixture)
            try await waitForDictation { fixture.coordinator.state != .recording }

            fixture.coordinator.holdEnded() // release after Esc: no second stop, no "Hold…" refusal
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)

            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(recent.map(\.text), ["escape hold words"])
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertTrue(delivered.isEmpty)
            let stops = await mic.stops
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .notice(message: "Cancelled — the text is in Dictations")
            )
        }
    }

    // MARK: - 7: the listener's open/closed life

    func testEscapeListenerIsOpenWhileRecording() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "listener words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        XCTAssertTrue(fixture.coordinator.isEscapeListenerOpenForTesting)
        XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)

        fixture.coordinator.toggle()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
        XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
    }

    func testEscapeListenerIsClosedAfterDelivery() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "delivered words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let gate = DeliveryGate()
        fixture.deliveryHook.action = { _ in gate.markStarted() }
        fixture.deliveryHook.gate = { await gate.wait() }

        try await runReleasingGate(releasing: { gate.release() }) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            fixture.coordinator.toggle()
            try await waitForDictation { gate.started }

            try await self.pressEscapeAndWait(fixture)
            XCTAssertFalse(fixture.coordinator.skipsDeliveryForTesting)

            gate.release()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, ["delivered words"])
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .inserted(characterCount: "delivered words".count)
            )
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        }
    }

    func testEscapeListenerIsClosedAfterARecognitionError() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "unused")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        await fixture.engine.failNextDecode()

        try await fixture.dictate()
        XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
    }

    func testEscapeListenerIsClosedAfterEmptyText() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        try await fixture.dictate()
        XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        XCTAssertEqual(fixture.indicator.presentedState, .noSpeech)
    }

    func testEscapeListenerIsClosedAfterTheStartWatchdog() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused", mode: .heldBeforeRecording)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        try await runReleasingGate(releasing: { await mic.releaseStart() }) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .starting }
            XCTAssertTrue(fixture.coordinator.isEscapeListenerOpenForTesting)

            try await waitForDictation(timeout: .seconds(10)) { fixture.coordinator.state == .idle }
            XCTAssertEqual(fixture.indicator.presentedState, .microphoneTimedOut)
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)
        }
    }

    func testEscapeListenerIsClosedAfterQuit() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "quitting words", holdsStop: true)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        try await runReleasingGate(releasing: { await mic.releaseStop() }) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            XCTAssertTrue(fixture.coordinator.isEscapeListenerOpenForTesting)

            let task = fixture.coordinator.beginTermination()
            // Closed the instant termination begins, before the state change
            // that follows (`beginStop` → `.transcribing`) could reopen it.
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)

            try await waitForDictation {
                await mic.isHoldingStop() && fixture.coordinator.state == .transcribing
            }
            // Without `|| isTerminating` in the switch, this would be true:
            // `beginStop`'s own `.transcribing` is not `.idle`.
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)

            await mic.releaseStop()
            try await finishTermination(task, within: .seconds(30))
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            XCTAssertFalse(fixture.coordinator.isEscapeListenerOpenForTesting)

            let recent = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(recent.count, 1)
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertTrue(delivered.isEmpty)
        }
    }

    // MARK: - 13–17: Esc frees other apps at once, even though the coordinator stays busy

    func testEscapeWhileRecognizingFreesEscapeAtOnce() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "escape freed words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        await fixture.engine.holdDecodes()

        try await withPasteShortcut(false) {
            try await self.runSettling(fixture, releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.beginCaptureForTesting()
                try await waitForDictation { fixture.coordinator.state == .recording }
                fixture.coordinator.toggle()
                try await waitForDictation { await fixture.engine.isHoldingDecode() }

                try await self.pressEscapeAndWait(fixture)
                try await waitForDictation(timeout: .seconds(2)) {
                    !fixture.coordinator.isEscapeListenerOpenForTesting
                }
                XCTAssertEqual(fixture.coordinator.state, .transcribing)
                let stillHeld = await fixture.engine.isHoldingDecode()
                XCTAssertTrue(stillHeld)
            }
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["escape freed words"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .notice(message: "Cancelled — the text is in Dictations")
        )
    }

    func testEscapeWhileTheMicrophoneHangsFreesEscape() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused", mode: .heldBeforeRecording)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }

        try await runSettling(fixture, releasing: { await mic.releaseStart() }) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { await mic.isHoldingStart() }
            XCTAssertEqual(fixture.coordinator.state, .starting)

            try await self.pressEscapeAndWait(fixture)
            try await waitForDictation(timeout: .seconds(2)) {
                !fixture.coordinator.isEscapeListenerOpenForTesting
            }
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
            XCTAssertTrue(fixture.coordinator.isBusy)
            let stillHolding = await mic.isHoldingStart()
            XCTAssertTrue(stillHolding)
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }

    func testReleaseBeforeRecordingFreesEscapeWhileTheMicrophoneHangs() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused", mode: .heldBeforeRecording)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        fixture.coordinator.startSkipsDeviceGatesForTesting = true

        try await runSettling(fixture, releasing: { await mic.releaseStart() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { await mic.isHoldingStart() }
            XCTAssertEqual(fixture.coordinator.state, .starting)

            fixture.coordinator.holdEnded()
            try await waitForDictation(timeout: .seconds(2)) {
                !fixture.coordinator.isEscapeListenerOpenForTesting
            }
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
            let stillHolding = await mic.isHoldingStart()
            XCTAssertTrue(stillHolding)
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
    }

    func testShortHoldFreesEscapeWhileTheMicrophoneStops() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, mic) = try makeFixture(text: "unused", holdsStop: true)
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        let clock = EscapeHoldClock()
        fixture.coordinator.startSkipsDeviceGatesForTesting = true
        fixture.coordinator.holdClockForTesting = { clock.now }

        try await runSettling(fixture, releasing: { await mic.releaseStop() }) {
            fixture.coordinator.holdBegan()
            try await waitForDictation { fixture.coordinator.state == .recording }
            clock.advance(.milliseconds(100)) // shorter than the 500 ms hold threshold
            fixture.coordinator.holdEnded()
            try await waitForDictation { await mic.isHoldingStop() }
            try await waitForDictation(timeout: .seconds(2)) {
                !fixture.coordinator.isEscapeListenerOpenForTesting
            }
            XCTAssertEqual(fixture.coordinator.state, .transcribing)
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    func testAutoPasteOffFreesEscapeWhenRecordingStops() async throws {
        let before = HotkeyManager.systemRegistrationsForTesting
        let (fixture, _) = try makeFixture(text: "autopaste off words")
        defer {
            fixture.cleanup()
            XCTAssertEqual(HotkeyManager.systemRegistrationsForTesting, before)
        }
        fixture.settings.autoPaste = false
        await fixture.engine.holdDecodes()

        try await withPasteShortcut(false) {
            try await self.runSettling(fixture, releasing: { await fixture.engine.releaseHeldDecode() }) {
                fixture.coordinator.beginCaptureForTesting()
                try await waitForDictation { fixture.coordinator.state == .recording }
                XCTAssertTrue(fixture.coordinator.isEscapeListenerOpenForTesting)

                fixture.coordinator.toggle()
                try await waitForDictation { await fixture.engine.isHoldingDecode() }
                try await waitForDictation(timeout: .seconds(2)) {
                    !fixture.coordinator.isEscapeListenerOpenForTesting
                }
                XCTAssertEqual(fixture.coordinator.state, .transcribing)
            }
        }

        let recent = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.text), ["autopaste off words"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .notice(message: "Saved to Dictations")
        )
    }
}
