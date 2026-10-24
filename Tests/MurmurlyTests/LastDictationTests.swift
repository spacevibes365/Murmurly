import AppKit
import Foundation
import XCTest
@testable import Murmurly

/// ⌃⌘V / ⌃⌘C read the last dictation fresh at the press — the newest of a
/// fresh history read and the unsaved list — rather than from the memory
/// menu. Uses the same real coordinator/store fixture as the history tests.
@MainActor
final class LastDictationTests: XCTestCase {
    /// A plain mutable flag for DEBUG seams: strict concurrency forbids a
    /// captured `var`, so every seam closure in this file writes into one of
    /// these instead.
    private final class Flag {
        var raised = false
    }

    private func makeFixture(text: String, failsModelLoad: Bool = false) throws -> DictationPipelineFixture {
        let fixture = try DictationPipelineFixture(text: text, failsModelLoad: failsModelLoad)
        fixture.coordinator.modifierFlagsForTesting = { [] }
        return fixture
    }

    private func breakArchive(_ fixture: DictationPipelineFixture) throws {
        try Data("not a directory".utf8).write(to: fixture.root)
    }

    private func press(_ fixture: DictationPipelineFixture) -> Task<Void, Never>? {
        fixture.coordinator.pasteLastKeyDownForTesting()
        return fixture.coordinator.pasteLastKeyUpForTesting()
    }

    /// Waits for `task` to finish within its own timeout, separate from any
    /// limit the paste logic enforces internally; on timeout the task is
    /// cancelled and `.value` is never awaited again (an already-failed
    /// `waitForDictation` has recorded the failure).
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

    private func entry(
        _ text: String,
        at: Date,
        interrupted: Bool? = nil,
        recognitionFailed: Bool? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(),
            at: at,
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "en",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: "",
            text: text,
            interrupted: interrupted,
            recognitionFailed: recognitionFailed
        )
    }

    private func tail(_ fixture: DictationPipelineFixture, after before: [String]) async -> [String] {
        Array(await fixture.probe.deliveredTexts.dropFirst(before.count))
    }

    func testPasteLastPastesTheNewestDictation() async throws {
        let fixture = try makeFixture(text: "first words")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.dictate()
        await fixture.engine.setText("second words")
        try await fixture.dictate()

        let before = await fixture.probe.deliveredTexts
        fixture.coordinator.pasteLastKeyDownForTesting()
        // The front app changes between the press and the release: the
        // target stays the one captured at key-down.
        fixture.coordinator.frontmostApplicationForTesting = { NSRunningApplication.current }
        try await finish(fixture.coordinator.pasteLastKeyUpForTesting())
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, ["second words"])
        let lastPID = await fixture.probe.deliveredTargetPIDs.last
        XCTAssertEqual(lastPID ?? nil, fixture.targetPID)
        XCTAssertEqual(fixture.indicator.presentedState, .inserted(characterCount: 12))

        // Owner's decision (2026-10-21): an interrupted dictation with text is
        // pasted by this explicit act, though automatic delivery never pastes it.
        fixture.coordinator.frontmostApplicationForTesting = nil
        try await fixture.store.append(
            entry("cut short words", at: Date().addingTimeInterval(60), interrupted: true)
        )
        let before2 = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added2 = await tail(fixture, after: before2)
        XCTAssertEqual(added2, ["cut short words"])
    }

    func testPasteLastReadsTheHistoryNotMemory() async throws {
        let fixture = try makeFixture(text: "spoken words")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.dictate()
        // The coordinator's own memory must have caught up with this
        // dictation before a second store instance writes to the same file:
        // otherwise a late background refresh could read the new line anyway,
        // even though its notification is filtered out, making the next
        // assertion pass by accident.
        try await waitForDictation {
            fixture.coordinator.recentDictations.map(\.text) == ["spoken words"]
        }
        guard fixture.coordinator.recentDictations.map(\.text) == ["spoken words"] else { return }

        // A second store instance on the same file: its own notification
        // carries `object: writer`, which the coordinator's subscription
        // (filtered to its own store) never sees.
        let writer = DictationHistoryStore(root: fixture.root)
        let written = entry("written directly", at: Date().addingTimeInterval(60))
        try await writer.append(written)
        XCTAssertFalse(fixture.coordinator.recentDictations.map(\.text).contains("written directly"))

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, ["written directly"])

        _ = try await writer.delete(id: written.id)
        XCTAssertFalse(fixture.coordinator.recentDictations.map(\.text).contains("written directly"))
        let before2 = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added2 = await tail(fixture, after: before2)
        XCTAssertEqual(added2, ["spoken words"])
    }

    func testNewerUnsavedDictationWins() async throws {
        let fixture = try makeFixture(text: "newer words")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try breakArchive(fixture)
        try await fixture.dictate()
        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["newer words"])

        try FileManager.default.removeItem(at: fixture.root)
        try await fixture.store.append(
            entry("older words", at: Date(timeIntervalSince1970: 1_700_000_000))
        )

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, ["newer words"])
    }

    func testUnrecognizedNewestPastesNothing() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(
            entry("older words", at: Date(timeIntervalSince1970: 1_700_000_000))
        )
        try await fixture.store.append(entry("", at: Date(), recognitionFailed: true))
        let placedLocally = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            placedLocally.raised = true
            return true
        }

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, [])
        XCTAssertFalse(placedLocally.raised)
        XCTAssertEqual(fixture.indicator.visibleState, DictationCoordinator.lastNotRecognizedFlash)

        let fixture2 = try makeFixture(text: "unused", failsModelLoad: true)
        defer {
            fixture2.coordinator.cancelPasteLastForTesting()
            fixture2.cleanup()
        }
        try breakArchive(fixture2)
        try await fixture2.dictate()
        XCTAssertEqual(fixture2.coordinator.unsavedDictations.first?.text, "")

        let before2 = await fixture2.probe.deliveredTexts
        try await finish(press(fixture2))
        let added2 = await tail(fixture2, after: before2)
        XCTAssertEqual(added2, [])
        XCTAssertEqual(fixture2.indicator.visibleState, DictationCoordinator.lastUnsavedNotRecognizedFlash)
    }

    func testNothingToPasteSaysSo() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        fixture.settings.overlayEnabled = false
        let placedLocally = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            placedLocally.raised = true
            return true
        }

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, [])
        XCTAssertFalse(placedLocally.raised)
        XCTAssertEqual(fixture.indicator.visibleState, DictationCoordinator.nothingToPasteFlash)

        try await fixture.store.append(entry("unreadable words", at: Date()))
        let historyURL = fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: historyURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }

        let before2 = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added2 = await tail(fixture, after: before2)
        XCTAssertEqual(added2, [])
        XCTAssertFalse(placedLocally.raised)
        XCTAssertEqual(fixture.indicator.visibleState, DictationCoordinator.historyUnreadableFlash)
    }

    func testPasteLastIsRefusedWhileDictating() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(entry("older words", at: Date()))

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        fixture.coordinator.pasteLastKeyDownForTesting()
        XCTAssertEqual(fixture.indicator.visibleState, .busyWithDictation)
        XCTAssertNil(fixture.coordinator.pasteLastKeyUpForTesting())

        var copyPlaced = false
        await fixture.coordinator.copyLastDictation(place: { _ in
            copyPlaced = true
            return true
        })
        XCTAssertFalse(copyPlaced)
        XCTAssertEqual(fixture.indicator.visibleState, .busyWithDictation)

        fixture.coordinator.toggle()
        try await waitForDictation { fixture.coordinator.state == .idle }

        // The stuck-at-a-seam case: the wait for the keys to be released is
        // still polling when a dictation starts.
        let pollCount = Flag2()
        fixture.coordinator.modifierFlagsForTesting = {
            pollCount.count += 1
            return [.control, .command]
        }
        let task = press(fixture)
        try await waitForDictation { pollCount.count >= 2 }

        let before = await fixture.probe.deliveredTexts
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.modifierFlagsForTesting = { [] }
        try await finish(task)
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, [])
        XCTAssertEqual(fixture.indicator.visibleState, .busyWithDictation)

        fixture.coordinator.toggle()
        try await waitForDictation { fixture.coordinator.state == .idle }

        // The keys stay down past the 1.5 s wait while a dictation is under
        // way: the deadline must defer to the busy flash, not the silent
        // give-up (the give-up is for cancellation/quit only).
        let heldPollCount = Flag2()
        fixture.coordinator.modifierFlagsForTesting = {
            heldPollCount.count += 1
            return [.control, .command]
        }
        let heldTask = press(fixture)
        try await waitForDictation { heldPollCount.count >= 2 }

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        let beforeHeld = await fixture.probe.deliveredTexts
        try await finish(heldTask)
        let addedHeld = await tail(fixture, after: beforeHeld)
        XCTAssertEqual(addedHeld, [])
        XCTAssertEqual(fixture.indicator.visibleState, .busyWithDictation)

        fixture.coordinator.toggle()
        try await waitForDictation { fixture.coordinator.state == .idle }
    }

    /// A plain `Int` counter, as a class so DEBUG seam closures can mutate it
    /// without capturing a `var` under strict concurrency.
    private final class Flag2 {
        var count = 0
    }

    func testPasteLastWaitsForTheKeysToBeReleased() async throws {
        let fixture = try makeFixture(text: "release then paste")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(entry("release then paste", at: Date()))

        let pollCount = Flag2()
        fixture.coordinator.modifierFlagsForTesting = {
            pollCount.count += 1
            return [.control, .option, .shift, .command]
        }
        let task = press(fixture)
        try await waitForDictation { pollCount.count >= 3 }
        let deliveredSoFar = await fixture.probe.deliveredTexts
        XCTAssertEqual(deliveredSoFar, [])

        let secondPollCount = Flag2()
        fixture.coordinator.modifierFlagsForTesting = {
            secondPollCount.count += 1
            return [.shift]
        }
        try await waitForDictation { secondPollCount.count >= 3 }
        let deliveredAfterPartialRelease = await fixture.probe.deliveredTexts
        XCTAssertEqual(deliveredAfterPartialRelease, [])

        // A new press while the first is still waiting changes neither its
        // target nor its outcome; it is returned the same task.
        fixture.coordinator.frontmostApplicationForTesting = { NSRunningApplication.current }
        fixture.coordinator.pasteLastKeyDownForTesting()
        XCTAssertEqual(fixture.coordinator.pasteLastKeyUpForTesting(), task)

        // Caps Lock does not count as a key held for the chord.
        fixture.coordinator.modifierFlagsForTesting = { [.capsLock] }
        let before = await fixture.probe.deliveredTexts
        try await finish(task)
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, ["release then paste"])
        let lastPID = await fixture.probe.deliveredTargetPIDs.last
        XCTAssertEqual(lastPID ?? nil, fixture.targetPID)
    }

    func testPasteLastGivesUpWhenKeysStayDown() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(entry("stuck words", at: Date()))
        fixture.coordinator.modifierFlagsForTesting = { [.control] }
        let placedLocally = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            placedLocally.raised = true
            return true
        }

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture), within: .seconds(5))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, [])
        XCTAssertFalse(placedLocally.raised)
        XCTAssertEqual(fixture.indicator.visibleState, DictationCoordinator.releaseKeysFlash)
    }

    func testPasteLastIntoPasswordFieldIsRefused() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(entry("secret words", at: Date()))
        fixture.coordinator.secureFieldCheckForTesting = { true }
        let placedLocally = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            placedLocally.raised = true
            return true
        }

        let before = await fixture.probe.deliveredTexts
        try await finish(press(fixture))
        let added = await tail(fixture, after: before)
        XCTAssertEqual(added, [])
        XCTAssertFalse(placedLocally.raised)
        XCTAssertEqual(fixture.indicator.visibleState, DictationCoordinator.passwordFieldPastedFlash)
    }

    func testCopyLastUsesOrdinaryClipboard() async throws {
        let fixture = try makeFixture(text: "unused")
        defer {
            fixture.coordinator.cancelPasteLastForTesting()
            fixture.cleanup()
        }
        try await fixture.store.append(entry("copy these words", at: Date()))
        let placedLocally = Flag()
        fixture.coordinator.placeLocallyForTesting = { _ in
            placedLocally.raised = true
            return true
        }

        final class Placed {
            var texts: [String] = []
        }
        let placed = Placed()
        try await finish(Task {
            await fixture.coordinator.copyLastDictation(place: { text in
                placed.texts.append(text)
                return true
            })
        })
        XCTAssertEqual(placed.texts, ["copy these words"])
        XCTAssertFalse(placedLocally.raised)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        let expectedState = IndicatorState.notice(message: "Copied · 16")
        XCTAssertEqual(fixture.indicator.presentedState, expectedState)
        XCTAssertEqual(expectedState.visualKind, .notice)
        XCTAssertEqual(expectedState.autoHide, 3)

        fixture.settings.overlayEnabled = false
        try await finish(Task {
            await fixture.coordinator.copyLastDictation(place: { text in
                placed.texts.append(text)
                return true
            })
        })
        XCTAssertNil(fixture.indicator.visibleState)
    }
}
