import AppKit
import Foundation
import KeyboardShortcuts
import XCTest
@testable import Murmurly

/// `dictation.autoPaste` off: `deliver` only saves the dictation, never
/// pastes or touches the clipboard. ⌃⌘V stays independent of the setting.
/// Uses the same real coordinator/store fixture as the history tests.
@MainActor
final class AutoPasteTests: XCTestCase {
    /// A plain mutable flag for DEBUG seams: strict concurrency forbids a
    /// captured `var`, so every seam closure in this file writes into one of
    /// these instead.
    private final class Flag {
        var raised = false
    }

    private static let historyNotSaved = IndicatorState.dictationFailure(
        message: String(localized: "History not saved — the text is in the “M” menu")
    )

    private func makeFixture(
        text: String,
        maxRecordingSeconds: TimeInterval = 300
    ) throws -> DictationPipelineFixture {
        let fixture = try DictationPipelineFixture(text: text, maxRecordingSeconds: maxRecordingSeconds)
        fixture.coordinator.modifierFlagsForTesting = { [] }
        return fixture
    }

    /// KeyboardShortcuts reads only `UserDefaults.standard`, which for the
    /// test host is the app's own, live domain, possibly carrying a real
    /// ⌃⌘V. The value goes into this process's argument domain instead,
    /// read first and restored in `defer`; never written to disk.
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

    /// Breaks the archive before its first write: a file where the fixture's
    /// `root` folder would be. `recent`/`page` then read "no history" rather
    /// than throwing (`history.jsonl` does not exist), so ⌃⌘V still finds the
    /// text in the unsaved list without repairing anything.
    private func breakArchive(_ fixture: DictationPipelineFixture) throws {
        try Data("not a directory".utf8).write(to: fixture.root)
    }

    /// Turns auto-paste off and wires both the clipboard fallback and the
    /// delivery hook to raised flags, so a test can prove neither ran.
    private func noAutoPaste(_ fixture: DictationPipelineFixture) -> (hook: Flag, clipboard: Flag) {
        fixture.settings.autoPaste = false
        let hook = Flag()
        let clipboard = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            clipboard.raised = true
            return true
        }
        fixture.deliveryHook.action = { _ in hook.raised = true }
        return (hook, clipboard)
    }

    private func press(_ fixture: DictationPipelineFixture) -> Task<Void, Never>? {
        fixture.coordinator.pasteLastKeyDownForTesting()
        return fixture.coordinator.pasteLastKeyUpForTesting()
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

    func testAutoPasteOffSavesWithoutPasting() async throws {
        try await withPasteShortcut(false) {
            // (a) A healthy archive: the dictation is saved and nothing is
            // pasted, touched on the clipboard or played.
            let fixture = try self.makeFixture(text: "some words")
            defer {
                fixture.coordinator.cancelPasteLastForTesting()
                fixture.cleanup()
            }
            let flags = self.noAutoPaste(fixture)

            try await fixture.dictate()

            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, [])
            XCTAssertFalse(flags.hook.raised)
            XCTAssertFalse(flags.clipboard.raised)
            XCTAssertEqual(fixture.coordinator.deliveryFeedbackCountForTesting, 0)
            let entries = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(entries.map(\.text), ["some words"])
            XCTAssertTrue(fixture.coordinator.unsavedDictations.isEmpty)
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .notice(message: "Saved to Dictations")
            )

            // (b) A broken archive: the history write fails, so the flash is
            // the existing "not saved" one, not "Saved…" — and the text and
            // its source audio stay reachable from the unsaved list.
            let fixture2 = try self.makeFixture(text: "kept words")
            defer {
                fixture2.coordinator.cancelPasteLastForTesting()
                fixture2.cleanup()
            }
            try self.breakArchive(fixture2)
            let flags2 = self.noAutoPaste(fixture2)

            try await fixture2.dictate()

            let source = await fixture2.mic.lastSource
            let unwrappedSource = try XCTUnwrap(source)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unwrappedSource.path))
            XCTAssertEqual(fixture2.coordinator.unsavedDictations.map(\.text), ["kept words"])
            let delivered2 = await fixture2.probe.deliveredTexts
            XCTAssertEqual(delivered2, [])
            XCTAssertFalse(flags2.hook.raised)
            XCTAssertFalse(flags2.clipboard.raised)
            XCTAssertEqual(fixture2.coordinator.deliveryFeedbackCountForTesting, 0)
            XCTAssertEqual(fixture2.indicator.presentedState, Self.historyNotSaved)
        }
    }

    func testAutoPasteOffMessageNamesTheShortcut() async throws {
        let fixture = try makeFixture(text: "named shortcut words")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        fixture.settings.autoPaste = false
        let custom = KeyboardShortcuts.Shortcut(.p, modifiers: [.control, .option])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))

        try await withPasteShortcut(stored) {
            XCTAssertEqual(fixture.settings.pasteLastDictationShortcutDescription, custom.description)
            try await fixture.dictate()
        }

        XCTAssertEqual(
            fixture.indicator.presentedState,
            .notice(message: "Saved — \(custom.description) pastes it")
        )

        try await withPasteShortcut(false) {
            XCTAssertNil(fixture.settings.pasteLastDictationShortcutDescription)
            try await fixture.dictate()
        }
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .notice(message: "Saved to Dictations")
        )
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.count, 2)
    }

    func testAutoPasteOffAtTheLimitSaysSavedAndNamesTheLimit() async throws {
        // Run 1: no shortcut set, indicator overlay off — the failure flash
        // must still be visible, and reports the limit's own "Saved…" text.
        let fixture = try makeFixture(text: "long held words", maxRecordingSeconds: 0.3)
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        fixture.settings.overlayEnabled = false
        let flags = noAutoPaste(fixture)

        try await withPasteShortcut(false) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            try await waitForDictation(timeout: .seconds(10)) { fixture.coordinator.state == .idle }
        }

        var delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        XCTAssertFalse(flags.clipboard.raised)
        XCTAssertEqual(fixture.coordinator.deliveryFeedbackCountForTesting, 0)
        XCTAssertTrue(fixture.coordinator.lastDictationHitLimit)
        XCTAssertEqual(
            fixture.indicator.visibleState,
            .dictationFailure(message: "Saved to Dictations — stopped at the 5-minute limit")
        )
        var entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.count, 1)

        // Run 2: same fixture, this time with a shortcut set — the message
        // names it, and the history grows to two lines.
        let custom = KeyboardShortcuts.Shortcut(.p, modifiers: [.control, .option])
        let stored = try XCTUnwrap(String(data: JSONEncoder().encode(custom), encoding: .utf8))
        try await withPasteShortcut(stored) {
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            try await waitForDictation(timeout: .seconds(10)) { fixture.coordinator.state == .idle }
        }

        delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        XCTAssertFalse(flags.clipboard.raised)
        XCTAssertEqual(fixture.coordinator.deliveryFeedbackCountForTesting, 0)
        XCTAssertTrue(fixture.coordinator.lastDictationHitLimit)
        XCTAssertEqual(
            fixture.indicator.visibleState,
            .dictationFailure(message: "Saved, not pasted — stopped at the 5-minute limit; \(custom.description) pastes it")
        )
        entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.count, 2)

        // Run 3: a fresh fixture with a broken archive — the limit's failure
        // flash is the existing "not saved" one, and the text is unsaved.
        let fixture2 = try makeFixture(text: "long held words again", maxRecordingSeconds: 0.3)
        defer {
            fixture2.coordinator.cancelPasteLastForTesting()
            fixture2.cleanup()
        }
        fixture2.settings.overlayEnabled = false
        try breakArchive(fixture2)
        let flags2 = noAutoPaste(fixture2)

        try await withPasteShortcut(false) {
            fixture2.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture2.coordinator.state == .recording }
            try await waitForDictation(timeout: .seconds(10)) { fixture2.coordinator.state == .idle }
        }

        let delivered2 = await fixture2.probe.deliveredTexts
        XCTAssertEqual(delivered2, [])
        XCTAssertFalse(flags2.clipboard.raised)
        XCTAssertEqual(fixture2.coordinator.deliveryFeedbackCountForTesting, 0)
        XCTAssertTrue(fixture2.coordinator.lastDictationHitLimit)
        XCTAssertEqual(fixture2.indicator.visibleState, Self.historyNotSaved)
        XCTAssertEqual(fixture2.coordinator.unsavedDictations.count, 1)
    }

    func testAutoPasteSettingIsKeptAndOnByDefault() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.AutoPaste.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.autoPaste)
        XCTAssertTrue(settings.snapshot.autoPaste)
        XCTAssertNil(defaults.object(forKey: "dictation.autoPaste"))

        settings.autoPaste = false
        XCTAssertEqual(defaults.object(forKey: "dictation.autoPaste") as? Bool, false)
        XCTAssertFalse(SettingsStore(defaults: defaults).autoPaste)
        XCTAssertFalse(SettingsStore(defaults: defaults).snapshot.autoPaste)

        XCTAssertTrue(SettingsSnapshot(dictationLanguage: "auto").autoPaste)
    }

    func testAutoPasteIsTakenWhenTheDictationStarts() async throws {
        try await withPasteShortcut(false) {
            let fixture = try self.makeFixture(text: "alpha words")
            defer {
                fixture.coordinator.cancelPasteLastForTesting()
                fixture.cleanup()
            }

            // On at the start, turned off mid-recording: the dictation
            // already under way still pastes.
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            fixture.settings.autoPaste = false
            fixture.coordinator.toggle()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, ["alpha words"])
            XCTAssertEqual(fixture.indicator.presentedState, .inserted(characterCount: "alpha words".count))
            XCTAssertEqual(fixture.coordinator.deliveryFeedbackCountForTesting, 1)

            // Off at the start, turned on mid-recording: this dictation
            // still does not paste; the change applies to the next one.
            await fixture.engine.setText("beta words")
            fixture.coordinator.beginCaptureForTesting()
            try await waitForDictation { fixture.coordinator.state == .recording }
            fixture.settings.autoPaste = true
            fixture.coordinator.toggle()
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            let afterSecond = await fixture.probe.deliveredTexts
            XCTAssertEqual(afterSecond, ["alpha words"], "autoPaste changed mid-recording must not affect this dictation")
            XCTAssertEqual(fixture.indicator.presentedState, .notice(message: "Saved to Dictations"))
            XCTAssertEqual(fixture.coordinator.deliveryFeedbackCountForTesting, 1)
            let entries = try await fixture.store.recent(limit: 10)
            XCTAssertEqual(entries.first?.text, "beta words")
        }
    }

    func testPasteLastStillPastesWithAutoPasteOff() async throws {
        try await withPasteShortcut(false) {
            // (a) A healthy archive: the dictation is saved, not pasted, then
            // ⌃⌘V delivers it.
            let fixture = try self.makeFixture(text: "manual paste words")
            defer {
                fixture.coordinator.cancelPasteLastForTesting()
                fixture.cleanup()
            }
            _ = self.noAutoPaste(fixture)

            try await fixture.dictate()
            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, [], "the dictation itself must not be pasted")

            try await self.finish(self.press(fixture))
            let afterPress = await fixture.probe.deliveredTexts
            XCTAssertEqual(afterPress, ["manual paste words"])
            XCTAssertEqual(
                fixture.indicator.presentedState,
                .inserted(characterCount: "manual paste words".count)
            )

            // (b) A broken archive: the dictation lands in the unsaved list;
            // ⌃⌘V still finds and delivers it from there, with no repair.
            let fixture2 = try self.makeFixture(text: "unsaved paste words")
            defer {
                fixture2.coordinator.cancelPasteLastForTesting()
                fixture2.cleanup()
            }
            try self.breakArchive(fixture2)
            _ = self.noAutoPaste(fixture2)

            try await fixture2.dictate()
            let delivered2 = await fixture2.probe.deliveredTexts
            XCTAssertEqual(delivered2, [])
            XCTAssertEqual(fixture2.coordinator.unsavedDictations.map(\.text), ["unsaved paste words"])
            XCTAssertEqual(fixture2.indicator.presentedState, Self.historyNotSaved)

            try await self.finish(self.press(fixture2))
            let afterPress2 = await fixture2.probe.deliveredTexts
            XCTAssertEqual(afterPress2, ["unsaved paste words"])
        }
    }
}
