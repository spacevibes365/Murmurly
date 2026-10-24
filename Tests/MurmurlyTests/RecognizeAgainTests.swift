import Foundation
import XCTest
@testable import Murmurly

private func makeRecognizeAgainRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Dictations", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return root
}

private func jsonlLines(of url: URL) throws -> [Data] {
    let data = try Data(contentsOf: url)
    var lines: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0x0A {
        if index > start { lines.append(Data(data[start..<index])) }
        start = data.index(after: index)
    }
    if start < data.endIndex { lines.append(Data(data[start...])) }
    return lines
}

private func mostRecent(_ fixture: DictationPipelineFixture) async throws -> DictationHistoryEntry {
    let entries = try await fixture.store.recent(limit: 1)
    return try XCTUnwrap(entries.first)
}

private func fileIdentity(of url: URL) throws -> (inode: UInt64, modified: Date) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    return (inode, modified)
}

private func temporaryHistoryFiles(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix(".history-") && $0.hasSuffix(".tmp") }
}

private struct RecognizeAgainTimeout: Error {}

/// A bounded poll for a condition that only becomes true from another task
/// or actor (the engine's own hold, a store-side hold): never a fixed sleep,
/// since the moment it flips is exactly what a regression would move.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Holds the store actor inside its first `beforeHistoryReplace` call until
/// released (bounded): any mutation that reaches `rewriteHistory` — delete,
/// clear, or a replacement — triggers it, so a decoy call on an id that
/// matches nothing is enough to occupy the actor without touching real data.
/// `entered` is a signal entirely separate from the coordinator's own
/// `recognizingAgainID`, which is exactly the point: the old code (K1) set
/// that flag only *after* its own `await` for the audio URL, so polling it
/// cannot tell whether the race window it is meant to guard is actually open.
private final class RecognizeAgainHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var isReleased = false

    var entered: Bool { lock.withLock { calls > 0 } }

    func hook() {
        let first = lock.withLock { () -> Bool in
            calls += 1
            return calls == 1
        }
        if first { _ = gate.wait(timeout: .now() + 10) }
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            defer { isReleased = true }
            return !isReleased
        }
        if shouldSignal { gate.signal() }
    }
}

@MainActor
private func waitForRevision(
    _ changes: DictationHistoryChanges, atLeast expected: UInt64, timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while changes.revision < expected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThanOrEqual(changes.revision, expected)
}

/// Not a one-off check: a bounded window during which the revision really
/// must stay put, so a notification posted a few milliseconds late is not
/// mistaken for one that was never posted.
@MainActor
private func assertRevisionUnchanged(
    _ changes: DictationHistoryChanges, since expected: UInt64, for duration: Duration = .milliseconds(300)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        XCTAssertEqual(changes.revision, expected)
        try await Task.sleep(for: .milliseconds(30))
    }
}

/// Runs `operation` and fails with `RecognizeAgainTimeout` if it does not
/// finish within `timeout`. A broken "only one at a time" guard would
/// otherwise leave `operation` suspended on the fixture's held decode (or a
/// held store call, via `onTimeout`) forever, and `withThrowingTaskGroup`
/// waits for every child task before returning: on an actual timeout the
/// hold is released first, so the still-running child can finish and the
/// group's implicit wait does not hang the whole test run.
@discardableResult
@MainActor
private func recognizeAgainWithin<T: Sendable>(
    _ fixture: DictationPipelineFixture,
    timeout: Duration = .seconds(5),
    onTimeout: @MainActor @escaping () async -> Void = {},
    _ operation: @MainActor @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RecognizeAgainTimeout()
        }
        do {
            let result = try await group.next()!
            group.cancelAll()
            return result
        } catch is RecognizeAgainTimeout {
            group.cancelAll()
            await fixture.engine.releaseHeldDecode()
            await onTimeout()
            throw RecognizeAgainTimeout()
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

@MainActor
final class RecognizeAgainTests: XCTestCase {
    func testRecognizeAgainReplacesTheTextOfTheSameEntry() async throws {
        let fixture = try DictationPipelineFixture(text: "original text")
        defer { fixture.cleanup() }
        // Created before the dictation, so its own append notification
        // cannot be missed.
        let changes = DictationHistoryChanges(store: fixture.store)
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)
        XCTAssertEqual(entry.text, "original text")
        try await waitForRevision(changes, atLeast: 1)

        // Nothing is pasted or copied by "Recognize Again": the delivery
        // path must never run for it.
        fixture.deliveryHook.action = { _ in XCTFail("recognizeAgain must not deliver text") }
        let deliveredBefore = await fixture.probe.deliveredTexts.count

        await fixture.engine.setText("second pass text")
        fixture.settings.dictationLanguage = "de"
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }

        // A successful replacement announces itself the same way a delete
        // or a clear does, so the list, the counter and the recent menu all
        // re-read on their own.
        try await waitForRevision(changes, atLeast: 2)

        let updated = try await mostRecent(fixture)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.text, "second pass text")
        XCTAssertNil(updated.rawText)
        XCTAssertEqual(updated.audioPath, entry.audioPath)
        XCTAssertEqual(updated.at, entry.at)
        XCTAssertEqual(updated.duration, entry.duration)
        XCTAssertEqual(updated.selectedLanguage, entry.selectedLanguage)
        XCTAssertEqual(updated.targetBundleID, entry.targetBundleID)
        XCTAssertEqual(updated.targetApplicationName, entry.targetApplicationName)

        // The current engine request actually used the language chosen
        // after the first dictation, not the one the entry was recognized
        // under originally.
        let requests = await fixture.engine.requests
        XCTAssertEqual(requests.last?.language, "de")

        let deliveredAfter = await fixture.probe.deliveredTexts.count
        XCTAssertEqual(deliveredAfter, deliveredBefore)
        XCTAssertNil(fixture.coordinator.recognizingAgainID)

        // Normalization matches the ordinary dictation pipeline: outer
        // whitespace and newlines are trimmed, inner ones are not.
        await fixture.engine.setText(" trimmed \n text ")
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }
        let trimmed = try await mostRecent(fixture)
        XCTAssertEqual(trimmed.text, "trimmed \n text")
        XCTAssertNil(trimmed.rawText)

        // `engine` and `actualLanguage` themselves change with a
        // replacement, checked directly through the store: this fixture's
        // simulated engine always decodes in one engine and reports one
        // fixed language, never a real switch between Whisper and Parakeet.
        let directChanged = try await fixture.store.replaceRecognition(
            id: entry.id, text: "direct replace", rawText: nil, actualLanguage: "fr", engine: "parakeet"
        )
        XCTAssertTrue(directChanged)
        let directlyUpdated = try await mostRecent(fixture)
        XCTAssertEqual(directlyUpdated.text, "direct replace")
        XCTAssertEqual(directlyUpdated.actualLanguage, "fr")
        XCTAssertEqual(directlyUpdated.engine, "parakeet")
        XCTAssertEqual(directlyUpdated.targetApplicationName, entry.targetApplicationName)
    }

    /// An entry a failed decode left empty, marked `recognition_failed`, gets
    /// text from a later successful "Recognize Again" and loses that mark. A
    /// line saved at quit time (`recognition_skipped`) loses that mark too,
    /// while `interrupted`, which the replacement never touches, stays.
    func testRecognizeAgainFillsAnUnrecognizedEntryAndClearsItsMark() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        await fixture.engine.failNextDecode()
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)
        XCTAssertTrue(entry.text.isEmpty)
        XCTAssertEqual(entry.recognitionFailed, true)

        await fixture.engine.setText("recovered text")
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }

        let updated = try await mostRecent(fixture)
        XCTAssertEqual(updated.text, "recovered text")
        XCTAssertNil(updated.recognitionFailed)
        XCTAssertNil(updated.recognitionSkipped)

        // A line a quit-time save left with `recognition_skipped` and
        // `interrupted` both set, sharing the same (copied) audio.
        let audioURLOptional = await fixture.store.audioURL(for: updated)
        let audioURL = try XCTUnwrap(audioURLOptional)
        let skippedID = UUID()
        let skippedAudioPath = "2026/01/\(skippedID.uuidString).caf"
        let skippedAudioURL = fixture.root.appendingPathComponent(skippedAudioPath)
        try FileManager.default.createDirectory(
            at: skippedAudioURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: audioURL, to: skippedAudioURL)
        let skippedEntry = DictationHistoryEntry(
            id: skippedID,
            at: Date(timeIntervalSince1970: 1_700_000_100),
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "en",
            engine: "whisper",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: skippedAudioPath,
            text: "",
            interrupted: true,
            recognitionSkipped: true
        )
        try await fixture.store.append(skippedEntry)

        await fixture.engine.setText("recovered again")
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(skippedEntry) }

        let recent = try await fixture.store.recent(limit: 5)
        let updatedSkipped = try XCTUnwrap(recent.first { $0.id == skippedID })
        XCTAssertEqual(updatedSkipped.text, "recovered again")
        XCTAssertNil(updatedSkipped.recognitionSkipped)
        XCTAssertEqual(updatedSkipped.interrupted, true)
    }

    /// A "Recognize Again" that fails leaves the index exactly as it was: a
    /// decode error, a write-hook error after a successful decode, and a
    /// model-load failure (which must also leave `modelState`/`modelFailure`,
    /// the indicator and `recognizingAgainID` untouched, since this path
    /// doesn't follow model progress at all) all leave the line and the
    /// file byte for byte.
    func testFailedRecognizeAgainLeavesTheLineByteForByte() async throws {
        // (a) the engine's own decode fails.
        let fixture = try DictationPipelineFixture(text: "stable text")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)
        let historyURL = fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let before = try Data(contentsOf: historyURL)

        await fixture.engine.failNextDecode()
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        do {
            try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }
            XCTFail("expected recognizeAgain to throw")
        } catch is PipelineDecodeFailure {
            // expected
        }

        let after = try Data(contentsOf: historyURL)
        XCTAssertEqual(before, after)

        // (b) the decode succeeds, but the store's write hook fails: the
        // error still reaches the caller, and the index, the audio and any
        // temporary file stay untouched.
        struct WriteHookFailure: Error {}
        final class FailOnce: @unchecked Sendable {
            var shouldFail = true
        }
        let failOnce = FailOnce()
        let writeFixture = try DictationPipelineFixture(text: "write-hook text") { _ in
            if failOnce.shouldFail {
                failOnce.shouldFail = false
                throw WriteHookFailure()
            }
        }
        defer { writeFixture.cleanup() }
        try await writeFixture.dictate()
        let writeEntry = try await mostRecent(writeFixture)
        let writeHistoryURL = writeFixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let writeBefore = try Data(contentsOf: writeHistoryURL)
        let audioURLBeforeOptional = await writeFixture.store.audioURL(for: writeEntry)
        let audioURLBefore = try XCTUnwrap(audioURLBeforeOptional)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURLBefore.path))

        await writeFixture.engine.setText("should not be saved")
        writeFixture.coordinator.recognizeAgainModelReadyForTesting = true
        do {
            try await recognizeAgainWithin(writeFixture) {
                try await writeFixture.coordinator.recognizeAgain(writeEntry)
            }
            XCTFail("expected recognizeAgain to throw from the write hook")
        } catch is WriteHookFailure {
            // expected
        }

        let writeAfter = try Data(contentsOf: writeHistoryURL)
        XCTAssertEqual(writeBefore, writeAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURLBefore.path))
        XCTAssertTrue(try temporaryHistoryFiles(in: writeFixture.root).isEmpty)

        // (c) the model fails to load: `modelState`, `modelFailure`, the
        // indicator and `recognizingAgainID` — which an ordinary dictation's
        // progress would update — stay exactly as they were, because
        // "Recognize Again" doesn't follow model progress at all.
        let modelFixture = try DictationPipelineFixture(text: "model text", failsModelLoad: true)
        defer { modelFixture.cleanup() }
        try await modelFixture.dictate()
        let modelEntry = try await mostRecent(modelFixture)
        XCTAssertTrue(modelEntry.text.isEmpty)

        let stateBefore = modelFixture.coordinator.modelState
        let failureBefore = modelFixture.coordinator.modelFailure
        let indicatorBefore = modelFixture.indicator.visibleState

        modelFixture.coordinator.recognizeAgainModelReadyForTesting = true
        do {
            try await recognizeAgainWithin(modelFixture) {
                try await modelFixture.coordinator.recognizeAgain(modelEntry)
            }
            XCTFail("expected recognizeAgain to throw from a failed model load")
        } catch is PipelineModelLoadFailure {
            // expected
        }

        XCTAssertNil(modelFixture.coordinator.recognizingAgainID)

        // A bounded observation window, not a one-off check: state this call
        // is forbidden from touching must still read unchanged a little
        // later, not only at the instant the call returned.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        while ContinuousClock.now < deadline {
            XCTAssertEqual(modelFixture.coordinator.modelState, stateBefore)
            XCTAssertEqual(modelFixture.coordinator.modelFailure, failureBefore)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(modelFixture.indicator.visibleState, indicatorBefore)
    }

    /// No speech the second time around is not silently accepted: the line
    /// keeps its earlier text, and the index file keeps its earlier bytes.
    func testEmptyResultLeavesTheEntryAsItWas() async throws {
        let fixture = try DictationPipelineFixture(text: "original text")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)
        let historyURL = fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let before = try Data(contentsOf: historyURL)

        await fixture.engine.setText("")
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        do {
            try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }
            XCTFail("expected .noSpeech")
        } catch DictationCoordinator.RecognizeAgainFailure.noSpeech {
            // expected
        }

        let after = try Data(contentsOf: historyURL)
        XCTAssertEqual(before, after)
        let unchanged = try await mostRecent(fixture)
        XCTAssertEqual(unchanged.text, "original text")
        XCTAssertNil(fixture.coordinator.recognizingAgainID)
    }

    /// Refused while an ordinary dictation is under way, and refused for a
    /// second concurrent call too — because the main-actor section through
    /// setting `recognizingAgainID` is entirely synchronous, not merely
    /// because the second call ends up serialized behind the first one by
    /// the engine's own FIFO.
    func testRecognizeAgainIsRefusedWhileDictating() async throws {
        let hold = RecognizeAgainHold()
        let fixture = try DictationPipelineFixture(text: "original", beforeHistoryReplace: { _ in hold.hook() })
        defer { fixture.cleanup() }
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        do {
            try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }
            XCTFail("expected recognizeAgain to be refused while dictating")
        } catch DictationCoordinator.RecognizeAgainFailure.busy {
            // expected
        }

        fixture.coordinator.toggle()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

        // Occupy the store actor with a decoy delete (on an id that matches
        // nothing) before either call starts. The old code (K1) set
        // `recognizingAgainID` only *after* its own `await` for the audio
        // URL — exactly the suspension a held store call forces here — so
        // waiting on that flag before starting the second call would miss
        // the very window this guards against.
        let occupy = Task { try? await fixture.store.delete(id: UUID()) }
        guard try await waitUntil({ hold.entered }) else {
            hold.release()
            occupy.cancel()
            XCTFail("the decoy delete never reached the store's hold")
            return
        }

        await fixture.engine.setText("first pass")

        // Created back to back with no `await` in between: on the main
        // actor's serial executor the first task runs to its own first
        // suspension point before the second task runs at all, so the
        // second call's guard sees whatever state the first call had
        // actually reached by then — not a state inferred afterward by
        // polling `recognizingAgainID`.
        let firstTask = Task { @MainActor in try await fixture.coordinator.recognizeAgain(entry) }
        let secondTask = Task { @MainActor in try await fixture.coordinator.recognizeAgain(entry) }

        do {
            do {
                try await recognizeAgainWithin(fixture, onTimeout: { hold.release() }) {
                    try await secondTask.value
                }
                XCTFail("expected the second concurrent recognizeAgain to be refused")
            } catch DictationCoordinator.RecognizeAgainFailure.busy {
                // expected
            }
        } catch {
            // Whatever went wrong with the second call, the first task and
            // the store's hold must not outlive this test.
            hold.release()
            occupy.cancel()
            firstTask.cancel()
            _ = try? await recognizeAgainWithin(fixture) { try await firstTask.value }
            throw error
        }

        // The refused second call must not have disturbed the first one.
        XCTAssertEqual(fixture.coordinator.recognizingAgainID, entry.id)

        hold.release()
        occupy.cancel()
        try await recognizeAgainWithin(fixture) { try await firstTask.value }
        XCTAssertNil(fixture.coordinator.recognizingAgainID)

        // Not `mostRecent`: the "while dictating" dictation above appended
        // its own, later entry, so `entry`'s replaced line must be found by
        // its own id.
        let recent = try await fixture.store.recent(limit: 10)
        let updated = try XCTUnwrap(recent.first { $0.id == entry.id })
        XCTAssertEqual(updated.text, "first pass")
    }

    /// Replacing one line never touches any other: every other line's bytes
    /// stay exactly what they were, including a line that never decodes and
    /// a final line without a trailing newline; the file's own permissions
    /// are unaffected too. A second, direct replacement with a different
    /// engine and language on another line changes only that line.
    func testReplaceKeepsOtherLinesByteForByte() async throws {
        let fixture = try DictationPipelineFixture(text: "first")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        await fixture.engine.setText("second")
        try await fixture.dictate()
        await fixture.engine.setText("third")
        try await fixture.dictate()

        let historyURL = fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName)
        var raw = try Data(contentsOf: historyURL)
        raw.append(Data("{not json".utf8))
        raw.append(DictationHistoryStore.newline)
        let tailEntry = DictationHistoryEntry(
            id: UUID(),
            at: Date(timeIntervalSince1970: 1_700_000_200),
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "en",
            engine: "whisper",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: "",
            text: "tail, no trailing newline"
        )
        let encoder = await fixture.store.makeEncoder()
        raw.append(try encoder.encode(tailEntry))
        try raw.write(to: historyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)

        let beforeLines = try jsonlLines(of: historyURL)
        XCTAssertEqual(beforeLines.count, 5)

        let decoder = await fixture.store.makeDecoder()
        let recent = try await fixture.store.recent(limit: 10)
        let target = try XCTUnwrap(recent.first { $0.text == "second" })
        let targetIndex = try XCTUnwrap(beforeLines.firstIndex { line in
            (try? decoder.decode(DictationHistoryEntry.self, from: line))?.id == target.id
        })

        await fixture.engine.setText("second, replaced")
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(target) }

        let afterLines = try jsonlLines(of: historyURL)
        XCTAssertEqual(afterLines.count, 5)
        for index in beforeLines.indices where index != targetIndex {
            XCTAssertEqual(afterLines[index], beforeLines[index], "line \(index) changed")
        }
        XCTAssertNotEqual(afterLines[targetIndex], beforeLines[targetIndex])
        let updatedTarget = try decoder.decode(DictationHistoryEntry.self, from: afterLines[targetIndex])
        XCTAssertEqual(updatedTarget.text, "second, replaced")

        let finalData = try Data(contentsOf: historyURL)
        XCTAssertNotEqual(finalData.last, DictationHistoryStore.newline, "the missing final newline must stay missing")
        let permissions = try FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        // A second, direct replacement — a different line, a different
        // engine and language — changes only that line; everything else,
        // including the line just replaced above, stays exactly as it was.
        let thirdEntry = try XCTUnwrap(recent.first { $0.text == "third" })
        let thirdIndex = try XCTUnwrap(afterLines.firstIndex { line in
            (try? decoder.decode(DictationHistoryEntry.self, from: line))?.id == thirdEntry.id
        })
        let thirdChanged = try await fixture.store.replaceRecognition(
            id: thirdEntry.id, text: "third, replaced", rawText: nil, actualLanguage: "de", engine: "parakeet"
        )
        XCTAssertTrue(thirdChanged)

        let finalLines = try jsonlLines(of: historyURL)
        XCTAssertEqual(finalLines.count, 5)
        for index in afterLines.indices where index != thirdIndex {
            XCTAssertEqual(finalLines[index], afterLines[index], "line \(index) changed")
        }
        let finalThird = try decoder.decode(DictationHistoryEntry.self, from: finalLines[thirdIndex])
        XCTAssertEqual(finalThird.text, "third, replaced")
        XCTAssertEqual(finalThird.actualLanguage, "de")
        XCTAssertEqual(finalThird.engine, "parakeet")
        XCTAssertEqual(finalThird.targetApplicationName, thirdEntry.targetApplicationName)
    }

    /// An id already gone from the index — never written at all, deleted, or
    /// cleared while its audio was being recognized again — changes nothing
    /// and answers `false`: not just the same bytes, but the same file
    /// (inode and modification time), no leftover temporary file, no
    /// notification, and nothing created on a store whose root never
    /// existed. Delete and Clear All are checked as two separate races,
    /// never both against the same entry, each confirmed by the *engine's*
    /// own `isHoldingDecode()` rather than `recognizingAgainID`, which only
    /// says the coordinator is busy, not that the engine has actually
    /// started decoding the very audio about to be deleted out from under it.
    func testReplaceOfADeletedEntryChangesNothing() async throws {
        // (a) a store whose root was never created: nothing before the call
        // becomes something after it.
        let freshRoot = try makeRecognizeAgainRoot()
        defer { try? FileManager.default.removeItem(at: freshRoot.deletingLastPathComponent()) }
        let freshStore = DictationHistoryStore(root: freshRoot)
        let freshChanged = try await freshStore.replaceRecognition(
            id: UUID(), text: "new", rawText: nil, actualLanguage: "en", engine: "whisper"
        )
        XCTAssertFalse(freshChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshRoot.path))

        // (b) an id written, then deleted: the index exists but no longer
        // has the line, and the replacement must neither resurrect it nor
        // announce a change that never happened.
        let root = try makeRecognizeAgainRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let changes = DictationHistoryChanges(store: store)
        let entry = DictationHistoryEntry(
            id: UUID(),
            at: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "en",
            engine: "whisper",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: "",
            text: "kept"
        )
        try await store.append(entry)
        try await waitForRevision(changes, atLeast: 1)
        _ = try await store.delete(id: entry.id)
        try await waitForRevision(changes, atLeast: 2)
        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let before = try Data(contentsOf: historyURL)
        let identityBefore = try fileIdentity(of: historyURL)

        let changed = try await store.replaceRecognition(
            id: entry.id, text: "new text", rawText: nil, actualLanguage: "en", engine: "whisper"
        )

        XCTAssertFalse(changed)
        let after = try Data(contentsOf: historyURL)
        XCTAssertEqual(before, after)
        let identityAfter = try fileIdentity(of: historyURL)
        XCTAssertEqual(identityAfter.inode, identityBefore.inode)
        XCTAssertEqual(identityAfter.modified, identityBefore.modified)
        XCTAssertTrue(try temporaryHistoryFiles(in: root).isEmpty)
        try await assertRevisionUnchanged(changes, since: 2)

        // (c) the same refusal reached through the coordinator, with the
        // entry actually deleted while its audio is being recognized again.
        let deleteFixture = try DictationPipelineFixture(text: "will be deleted")
        defer { deleteFixture.cleanup() }
        try await deleteFixture.dictate()
        let deletedEntry = try await mostRecent(deleteFixture)

        await deleteFixture.engine.setText("too late")
        await deleteFixture.engine.holdDecodes()
        deleteFixture.coordinator.recognizeAgainModelReadyForTesting = true
        let deleteTask = Task { @MainActor in try await deleteFixture.coordinator.recognizeAgain(deletedEntry) }

        do {
            guard try await waitUntil({ await deleteFixture.engine.isHoldingDecode() }) else {
                XCTFail("recognizeAgain never reached the engine's held decode")
                throw RecognizeAgainTimeout()
            }
            _ = try await deleteFixture.store.delete(id: deletedEntry.id)
        } catch {
            await deleteFixture.engine.releaseHeldDecode()
            deleteTask.cancel()
            _ = try? await recognizeAgainWithin(deleteFixture) { try await deleteTask.value }
            throw error
        }
        await deleteFixture.engine.releaseHeldDecode()
        try await recognizeAgainWithin(deleteFixture) { try await deleteTask.value }

        let afterDelete = try await deleteFixture.store.recent(limit: 10)
        XCTAssertTrue(afterDelete.allSatisfy { $0.id != deletedEntry.id })

        // (d) the same race, but Clear All this time — never combined with
        // the delete above against the same entry.
        let clearFixture = try DictationPipelineFixture(text: "will be cleared")
        defer { clearFixture.cleanup() }
        try await clearFixture.dictate()
        let clearedEntry = try await mostRecent(clearFixture)

        await clearFixture.engine.setText("too late")
        await clearFixture.engine.holdDecodes()
        clearFixture.coordinator.recognizeAgainModelReadyForTesting = true
        let clearTask = Task { @MainActor in try await clearFixture.coordinator.recognizeAgain(clearedEntry) }

        do {
            guard try await waitUntil({ await clearFixture.engine.isHoldingDecode() }) else {
                XCTFail("recognizeAgain never reached the engine's held decode")
                throw RecognizeAgainTimeout()
            }
            try await clearFixture.store.clearAll()
        } catch {
            await clearFixture.engine.releaseHeldDecode()
            clearTask.cancel()
            _ = try? await recognizeAgainWithin(clearFixture) { try await clearTask.value }
            throw error
        }
        await clearFixture.engine.releaseHeldDecode()
        try await recognizeAgainWithin(clearFixture) { try await clearTask.value }

        let afterClear = try await clearFixture.store.recent(limit: 10)
        XCTAssertTrue(afterClear.isEmpty)
    }

    /// The new text goes through the dictation's personal dictionary, same
    /// as an ordinary dictation: `raw_text` keeps the engine's own words.
    func testDictionaryAppliesToTheNewTextAndRawTextIsKept() async throws {
        let fixture = try DictationPipelineFixture(text: "original")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        let entry = try await mostRecent(fixture)

        fixture.settings.dictionaryInDictation = true
        try fixture.settings.saveDictionary([DictionaryEntry(heard: ["foo"], written: "Foo-Bar")])
        await fixture.engine.setText("say foo now")
        fixture.coordinator.recognizeAgainModelReadyForTesting = true
        try await recognizeAgainWithin(fixture) { try await fixture.coordinator.recognizeAgain(entry) }

        let updated = try await mostRecent(fixture)
        XCTAssertEqual(updated.text, "say Foo-Bar now")
        XCTAssertEqual(updated.rawText, "say foo now")
    }
}
