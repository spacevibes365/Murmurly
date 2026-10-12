import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Holds the store actor inside the first `beforeHistoryReplace` call until
/// released, so a later actor call (an audio lookup) waits behind it. Later
/// calls pass. Waits are bounded; `release` is safe to call more than once.
private final class StoreHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var isEntered = false
    private var isReleased = false

    var entered: Bool { lock.withLock { isEntered } }

    func hook() {
        let first = lock.withLock { () -> Bool in
            calls += 1
            if calls == 1 { isEntered = true }
            return calls == 1
        }
        guard first else { return }
        _ = gate.wait(timeout: .now() + 10)
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            defer { isReleased = true }
            return !isReleased
        }
        if shouldSignal { gate.signal() }
    }
}

/// Resumes a continuation once; later answers are ignored.
private final class OnceFinished: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func give(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// True when the task finished within the timeout; never joins a stuck task.
@MainActor
private func finished(_ task: Task<Void, Never>, within timeout: Duration = .seconds(10)) async -> Bool {
    await withCheckedContinuation { continuation in
        let answer = OnceFinished(continuation)
        Task {
            await task.value
            answer.give(true)
        }
        Task {
            try? await Task.sleep(for: timeout)
            answer.give(false)
        }
    }
}

@MainActor
private final class LookupCounter {
    var count = 0
}

/// History consistency regressions. Besides the DEBUG hook `willLookUpAudioForTesting`,
/// which the red check adds unchanged to the tree before the fix, they use
/// only API that exists there.
@MainActor
final class HistoryConsistencyTests: XCTestCase {
    // MARK: Final JSONL line without LF

    func testDeletesOnlyEntryWhoseLineHasNoNewline() async throws {
        let archive = try makeArchive()
        defer { archive.cleanup() }
        let entry = try await archive.appendWithAudio(text: "only")
        try archive.stripFinalNewline()

        let deleted = try await archive.store.delete(id: entry.id)

        XCTAssertTrue(deleted, "a complete final record must be deletable")
        let remaining = try await archive.store.recent(limit: 10)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(archive.audioExists(for: entry))
    }

    func testDeletesLastOfSeveralWithoutNewline() async throws {
        let archive = try makeArchive()
        defer { archive.cleanup() }
        let first = try await archive.appendWithAudio(text: "first")
        let second = try await archive.appendWithAudio(text: "second")
        let last = try await archive.appendWithAudio(text: "last")
        try archive.stripFinalNewline()

        let deleted = try await archive.store.delete(id: last.id)

        XCTAssertTrue(deleted)
        let remaining = try await archive.store.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [second.id, first.id])
        XCTAssertFalse(archive.audioExists(for: last))
        XCTAssertTrue(archive.audioExists(for: first))
        XCTAssertTrue(archive.audioExists(for: second))
    }

    func testDeletesFinalLineLongerThanReadBlock() async throws {
        let archive = try makeArchive()
        defer { archive.cleanup() }
        let first = try await archive.appendWithAudio(text: "first")
        let long = try await archive.appendWithAudio(text: String(repeating: "x", count: 70_000))
        try archive.stripFinalNewline()

        let deleted = try await archive.store.delete(id: long.id)

        XCTAssertTrue(deleted, "a final record spanning read blocks must be deletable")
        let remaining = try await archive.store.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [first.id])
    }

    func testForeignFinalLineIsKeptByteForByte() async throws {
        let archive = try makeArchive()
        defer { archive.cleanup() }
        let first = try await archive.appendWithAudio(text: "first")
        let kept = try await archive.appendWithAudio(text: "kept")
        try archive.stripFinalNewline()
        let keptLine = try XCTUnwrap(archive.historyBytes().split(separator: DictationHistoryStore.newline).last)

        _ = try await archive.store.delete(id: first.id)

        XCTAssertEqual(archive.historyBytes(), Data(keptLine))
        let remaining = try await archive.store.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [kept.id])
    }

    func testCorruptFinalBytesAreKept() async throws {
        let archive = try makeArchive()
        defer { archive.cleanup() }
        let first = try await archive.appendWithAudio(text: "first")
        let corrupt = Data(#"{"id":"broken"#.utf8)
        try archive.appendRaw(corrupt)

        _ = try await archive.store.delete(id: first.id)

        XCTAssertEqual(archive.historyBytes(), corrupt)
    }

    func testFailedReplaceLeavesFinalLineAndAudio() async throws {
        let archive = try makeArchive(beforeHistoryReplace: { throw CocoaError(.fileWriteUnknown) })
        defer { archive.cleanup() }
        let entry = try await archive.appendWithAudio(text: "stays")
        try archive.stripFinalNewline()
        let before = archive.historyBytes()

        do {
            _ = try await archive.store.delete(id: entry.id)
            XCTFail("the injected replace failure must surface")
        } catch {}

        XCTAssertEqual(archive.historyBytes(), before)
        XCTAssertTrue(archive.audioExists(for: entry))
    }

    // MARK: Stale playback requests

    func testStopWhileLookupPendingDoesNotStartPlayback() async throws {
        let held = try await makeHeldPlayback()
        defer { held.cleanup() }
        let entry = try await held.archive.appendWithAudio(text: "audio", playable: true)
        try await held.engageHold()

        let pending = try await held.beginPlay(entry)
        held.model.stopAudio()
        held.hold.release()

        let done = await finished(pending)
        XCTAssertTrue(done, "play did not finish after the lookup was released")
        XCTAssertNil(held.model.playingEntryID, "a stopped request must not start playing later")
    }

    func testStaleLookupOfMissingAudioShowsNoError() async throws {
        let held = try await makeHeldPlayback()
        defer { held.cleanup() }
        let entry = try await held.archive.append(text: "no audio")
        try await held.engageHold()

        let pending = try await held.beginPlay(entry)
        held.model.stopAudio()
        held.hold.release()

        let done = await finished(pending)
        XCTAssertTrue(done)
        XCTAssertNil(held.model.errorMessage, "a stale request must not report its error")
    }

    func testNewerPlayWinsWhateverOrderLookupsReturn() async throws {
        let held = try await makeHeldPlayback()
        defer { held.cleanup() }
        let missing = try await held.archive.append(text: "no audio")
        let playable = try await held.archive.appendWithAudio(text: "audio", playable: true)
        try await held.engageHold()

        let first = try await held.beginPlay(missing)
        let second = try await held.beginPlay(playable, expectedLookups: 2)
        held.hold.release()

        let firstDone = await finished(first)
        let secondDone = await finished(second)
        XCTAssertTrue(firstDone && secondDone)
        XCTAssertEqual(held.model.playingEntryID, playable.id, "the older request must not stop the newer one")
        XCTAssertNil(held.model.errorMessage, "the older request must not report its error")
        held.model.stopAudio()
    }

    func testClearWhilePlayPendingStaysSilent() async throws {
        let held = try await makeHeldPlayback()
        defer { held.cleanup() }
        let entry = try await held.archive.appendWithAudio(text: "audio", playable: true)
        try await held.engageHold()

        let pending = try await held.beginPlay(entry)
        let clearing = Task { _ = await held.model.clearAll() }
        // `isMutating` is set before clear stops playback and awaits the
        // store, so seeing it proves the pending request is already stale.
        try await waitForDictation { held.model.isMutating }
        held.hold.release()

        let playDone = await finished(pending)
        let clearDone = await finished(clearing)
        XCTAssertTrue(playDone && clearDone)
        XCTAssertNil(held.model.playingEntryID, "a cleared entry must not start playing")
        XCTAssertNil(held.model.errorMessage, "a request made stale by clear must not report an error")
    }

    // MARK: The recent menu follows the store

    func testRecentMenuFollowsAppendMadeOutsideTheCoordinator() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let entry = DictationHistoryEntry(
            id: UUID(),
            at: Date(),
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "ru",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: "2026/10/outside.caf",
            text: "saved outside"
        )

        try await fixture.store.append(entry)

        try await waitForDictation { fixture.coordinator.recentDictations.map(\.id) == [entry.id] }
    }

    func testRecentMenuEmptiesAfterClear() async throws {
        let fixture = try DictationPipelineFixture(text: "to be cleared")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        try await waitForDictation { fixture.coordinator.recentDictations.count == 1 }

        try await fixture.store.clearAll()

        try await waitForDictation { fixture.coordinator.recentDictations.isEmpty }
    }

    func testDeleteThatFailsOnAudioStillRefreshesMenu() async throws {
        let fixture = try DictationPipelineFixture(text: "audio stays locked")
        defer { fixture.cleanup() }
        try await fixture.dictate()
        try await waitForDictation { fixture.coordinator.recentDictations.count == 1 }
        let stored = try await fixture.store.recent(limit: 1)
        let entry = try XCTUnwrap(stored.first)
        let audioDirectory = fixture.root.appendingPathComponent(entry.audioPath).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: audioDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDirectory.path)
        }

        do {
            _ = try await fixture.store.delete(id: entry.id)
            XCTFail("removing audio from a read-only folder must fail")
        } catch {}

        // The index was already replaced: the menu must follow it.
        try await waitForDictation { fixture.coordinator.recentDictations.isEmpty }
    }

    // MARK: Helpers

    private struct Archive {
        let parent: URL
        let root: URL
        let store: DictationHistoryStore

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
        }

        var historyURL: URL { root.appendingPathComponent(DictationHistoryStore.historyFileName) }

        func historyBytes() -> Data { (try? Data(contentsOf: historyURL)) ?? Data() }

        func append(text: String) async throws -> DictationHistoryEntry {
            let id = UUID()
            let entry = DictationHistoryEntry(
                id: id,
                at: Date(),
                duration: 1,
                selectedLanguage: "auto",
                actualLanguage: "ru",
                targetBundleID: nil,
                targetApplicationName: nil,
                audioPath: "2026/10/\(id.uuidString).caf",
                text: text
            )
            try await store.append(entry)
            return entry
        }

        func appendWithAudio(text: String, playable: Bool = false) async throws -> DictationHistoryEntry {
            let entry = try await append(text: text)
            let url = root.appendingPathComponent(entry.audioPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if playable {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
                buffer.frameLength = 24_000
                try file.write(from: buffer)
            } else {
                try Data("audio".utf8).write(to: url)
            }
            return entry
        }

        func audioExists(for entry: DictationHistoryEntry) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.audioPath).path)
        }

        func stripFinalNewline() throws {
            var bytes = historyBytes()
            XCTAssertEqual(bytes.last, DictationHistoryStore.newline)
            bytes.removeLast()
            try bytes.write(to: historyURL)
        }

        func appendRaw(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: historyURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    private func makeArchive(
        beforeHistoryReplace: @escaping @Sendable () throws -> Void = {}
    ) throws -> Archive {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("Dictations", isDirectory: true)
        return Archive(
            parent: parent,
            root: root,
            store: DictationHistoryStore(root: root, beforeHistoryReplace: beforeHistoryReplace)
        )
    }

    private struct HeldPlayback {
        let archive: Archive
        let hold: StoreHold
        let model: DictationHistoryViewModel
        let lookups: LookupCounter

        @MainActor
        func cleanup() {
            hold.release()
            model.stopAudio()
            archive.cleanup()
        }

        /// Makes the store busy with an unrelated delete held inside its
        /// replace hook. Entries must be appended before this.
        @MainActor
        func engageHold() async throws {
            let store = archive.store
            Task.detached { _ = try? await store.delete(id: UUID()) }
            try await waitForDictation { hold.entered }
            XCTAssertTrue(hold.entered, "the store was not held")
        }

        /// Starts `play` and returns once its lookup is waiting behind the
        /// held actor, proven by the model's own hook rather than by timing.
        @MainActor
        func beginPlay(
            _ entry: DictationHistoryEntry,
            expectedLookups: Int = 1
        ) async throws -> Task<Void, Never> {
            let model = self.model
            let task = Task { await model.play(entry) }
            try await waitForDictation { lookups.count >= expectedLookups }
            XCTAssertEqual(lookups.count, expectedLookups, "play did not reach its audio lookup")
            return task
        }
    }

    /// A model whose store can be held busy (`engageHold`), so every audio
    /// lookup then waits until `hold.release()`.
    private func makeHeldPlayback() async throws -> HeldPlayback {
        let hold = StoreHold()
        let archive = try makeArchive(beforeHistoryReplace: { hold.hook() })
        let lookups = LookupCounter()
        let model = DictationHistoryViewModel(store: archive.store)
        model.willLookUpAudioForTesting = { lookups.count += 1 }
        return HeldPlayback(archive: archive, hold: hold, model: model, lookups: lookups)
    }
}
