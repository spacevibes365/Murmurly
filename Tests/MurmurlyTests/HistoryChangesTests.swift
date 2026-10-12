import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Holds the first `beforeHistoryReplace` call until released (bounded).
private final class FirstReplaceHold: @unchecked Sendable {
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

/// New API around the store's change signal and the delete side of stale playback.
@MainActor
final class HistoryChangesTests: XCTestCase {
    func testEveryCompletedIndexChangeBumpsTheRevision() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let changes = DictationHistoryChanges(store: store)

        let appended = HistoryChangesTests.makeEntry(audioPath: "2026/10/a.caf")
        try await store.append(appended)
        try await waitForRevision(changes, 1)

        let source = root.deletingLastPathComponent().appendingPathComponent("source.caf")
        try writeCAF(at: source)
        let saved = try await store.saveDictation(from: source, id: UUID(), at: Date()) { path, duration in
            HistoryChangesTests.makeEntry(audioPath: path, duration: duration)
        }
        try await waitForRevision(changes, 2)

        let retried = HistoryChangesTests.makeEntry(audioPath: "2026/10/retried.caf")
        try writeAudio(at: root.appendingPathComponent(retried.audioPath))
        try await store.indexArchivedDictation(retried)
        try await waitForRevision(changes, 3)

        _ = try await store.delete(id: saved.id)
        try await waitForRevision(changes, 4)

        try await store.clearAll()
        try await waitForRevision(changes, 5)
        XCTAssertEqual(changes.revision, 5)
    }

    func testFailureBeforeReplaceDoesNotPretendToBeAChange() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Dictations", isDirectory: true)
        let failing = DictationHistoryStore(root: root, beforeHistoryReplace: {
            throw CocoaError(.fileWriteUnknown)
        })
        let changes = DictationHistoryChanges(store: failing)
        let entry = HistoryChangesTests.makeEntry(audioPath: "2026/10/a.caf")
        try await failing.append(entry)
        try await waitForRevision(changes, 1)

        do {
            _ = try await failing.delete(id: entry.id)
            XCTFail("the injected replace failure must surface")
        } catch {}
        // Notifications arrive in order: had the failed delete announced a
        // change, the revision would already be 3 once this append is seen.
        try await failing.append(HistoryChangesTests.makeEntry(audioPath: "2026/10/b.caf"))
        try await waitForRevision(changes, 2)
        XCTAssertEqual(changes.revision, 2)
    }

    func testAudioRemovalFailureAfterReplaceStillAnnouncesTheChange() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let changes = DictationHistoryChanges(store: store)
        let entry = HistoryChangesTests.makeEntry(audioPath: "2026/10/locked.caf")
        let audio = root.appendingPathComponent(entry.audioPath)
        try writeAudio(at: audio)
        try await store.append(entry)
        try await waitForRevision(changes, 1)
        let folder = audio.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        do {
            _ = try await store.delete(id: entry.id)
            XCTFail("removing audio from a read-only folder must fail")
        } catch {}

        try await waitForRevision(changes, 2)
        let remaining = try await store.recent(limit: 10)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRefreshAfterFailedDeleteKeepsTheMutationError() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let changes = DictationHistoryChanges(store: store)
        let model = DictationHistoryViewModel(store: store)
        let entry = HistoryChangesTests.makeEntry(audioPath: "2026/10/locked.caf")
        let audio = root.appendingPathComponent(entry.audioPath)
        try writeAudio(at: audio)
        try await store.append(entry)
        try await waitForRevision(changes, 1)
        await model.reload()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        let folder = audio.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        let deleted = await model.delete(entry)
        // The index did change, so the history view refreshes on the signal.
        try await waitForRevision(changes, 2)
        await model.reload()

        XCTAssertFalse(deleted)
        XCTAssertTrue(model.entries.isEmpty, "the list follows the index that did change")
        XCTAssertNotNil(model.errorMessage, "the refresh must not hide the delete error")
    }

    /// A read error is the tab's own state, not an alert, and the next
    /// successful read clears it.
    func testSuccessfulReadClearsOnlyAReadError() async throws {
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await store.append(HistoryChangesTests.makeEntry(audioPath: "2026/10/a.caf"))
        let index = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let model = DictationHistoryViewModel(store: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }

        await model.reload()
        XCTAssertNotNil(model.readFailure, "an unreadable index must report a read error")
        XCTAssertNil(model.errorMessage, "a read error is not an action's alert")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        await model.reload()
        XCTAssertNil(model.readFailure, "a successful read clears its own earlier read error")
        XCTAssertEqual(model.entries.count, 1)
    }

    func testAnotherStoreDoesNotBumpTheRevision() async throws {
        let (rootA, storeA) = try makeStore()
        let (rootB, storeB) = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
        }
        let changes = DictationHistoryChanges(store: storeA)

        try await storeB.append(HistoryChangesTests.makeEntry(audioPath: "2026/10/b.caf"))
        try await storeA.append(HistoryChangesTests.makeEntry(audioPath: "2026/10/a.caf"))

        try await waitForRevision(changes, 1)
        XCTAssertEqual(changes.revision, 1, "a change of another store was counted")
    }

    func testDeletingAnEntryWaitingForPlaybackStaysSilent() async throws {
        let hold = FirstReplaceHold()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            hold.release()
            try? FileManager.default.removeItem(at: parent)
        }
        let root = parent.appendingPathComponent("Dictations", isDirectory: true)
        let store = DictationHistoryStore(root: root, beforeHistoryReplace: { hold.hook() })
        let entry = HistoryChangesTests.makeEntry(audioPath: "2026/10/play.caf")
        try writeCAF(at: root.appendingPathComponent(entry.audioPath))
        try await store.append(entry)
        let model = DictationHistoryViewModel(store: store)
        var lookups = 0
        model.willLookUpAudioForTesting = { lookups += 1 }
        Task.detached { _ = try? await store.delete(id: UUID()) }
        try await waitForDictation { hold.entered }

        let playing = Task { await model.play(entry) }
        try await waitForDictation { lookups == 1 }
        let deleting = Task { _ = await model.delete(entry) }
        // Set before delete stops playback and awaits the store.
        try await waitForDictation { model.isMutating }
        hold.release()

        try await waitForDictation { !model.isMutating }
        await playing.value
        await deleting.value
        XCTAssertNil(model.playingEntryID, "a deleted entry must not start playing")
        XCTAssertNil(model.errorMessage, "a request made stale by delete must not report an error")
    }

    // MARK: Helpers

    private func makeStore() throws -> (root: URL, store: DictationHistoryStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("Dictations", isDirectory: true)
        return (root, DictationHistoryStore(root: root))
    }

    private nonisolated static func makeEntry(audioPath: String, duration: TimeInterval = 1) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(),
            at: Date(),
            duration: duration,
            selectedLanguage: "auto",
            actualLanguage: "ru",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: audioPath,
            text: "entry"
        )
    }

    private func writeAudio(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
    }

    private func writeCAF(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        try file.write(from: buffer)
    }

    private func waitForRevision(_ changes: DictationHistoryChanges, _ expected: UInt64) async throws {
        try await waitForDictation { changes.revision >= expected }
    }
}
