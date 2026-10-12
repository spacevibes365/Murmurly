import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import Murmurly

private func makeHistoryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Dictations", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return root
}

private func makeEntry(
    index: Int,
    text: String? = nil,
    date: Date? = nil,
    audioPath: String? = nil,
    engine: String? = nil
) -> DictationHistoryEntry {
    DictationHistoryEntry(
        id: UUID(),
        at: date ?? Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        duration: Double(index) + 0.25,
        selectedLanguage: "auto",
        actualLanguage: index.isMultiple(of: 2) ? "ru" : "en",
        engine: engine,
        targetBundleID: "com.example.editor",
        targetApplicationName: "Editor",
        audioPath: audioPath ?? "2023/11/\(index).m4a",
        text: text ?? "entry-\(index)"
    )
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
}

@MainActor
final class DictationHistoryStoreTests: XCTestCase {
    func testHistoryEngineFieldIsAdditiveWithinSchemaVersionOne() throws {
        for engine in [nil, "parakeet", "future-engine"] as [String?] {
            let original = makeEntry(index: 1, engine: engine)
            let data = try JSONEncoder().encode(original)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["schema_version"] as? Int, 1)
            if engine == nil { XCTAssertNil(json["engine"]) }
            let decoded = try JSONDecoder().decode(DictationHistoryEntry.self, from: data)
            XCTAssertEqual(decoded.engine, engine)
            XCTAssertEqual(decoded.schemaVersion, 1)
        }
    }
    func testHistorySummaryTable() async throws {
        let cases: [(name: String, entries: [DictationHistoryEntry], malformedMiddle: Bool, removeFinalNewline: Bool)] = [
            ("empty", [], false, false),
            ("one", [makeEntry(index: 1)], false, false),
            ("several", [makeEntry(index: 1), makeEntry(index: 2), makeEntry(index: 3)], false, false),
            ("malformed-middle", [makeEntry(index: 1), makeEntry(index: 2)], true, false),
            ("no-final-newline", [makeEntry(index: 4)], false, true),
        ]

        for testCase in cases {
            let root = try makeHistoryRoot()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let store = DictationHistoryStore(root: root)
            for (index, entry) in testCase.entries.enumerated() {
                try await store.append(entry)
                if testCase.malformedMiddle, index == 0 {
                    try appendRaw(Data("not-json\n".utf8), to: root)
                }
            }
            if testCase.removeFinalNewline { try removeFinalNewline(in: root) }

            let summary = try await store.historySummary()
            XCTAssertEqual(summary.count, testCase.entries.count, testCase.name)
            XCTAssertEqual(summary.oldest, testCase.entries.map(\.at).min(), testCase.name)
        }
    }

    func testHistoryCountMatchesTextAcrossWholeFile() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        try await store.append(makeEntry(index: 1, text: "Альфа и бета"))
        try await store.append(makeEntry(index: 2, text: "Только бета"))
        try await store.append(makeEntry(index: 3, text: "Гамма"))

        let total = try await store.count(matching: nil)
        let beta = try await store.count(matching: " БЕТА ")
        let missing = try await store.count(matching: "дельта")
        XCTAssertEqual(total, 3)
        XCTAssertEqual(beta, 2)
        XCTAssertEqual(missing, 0)
    }

    func testValidFinalLineWithoutNewlineIsVisible() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let entry = makeEntry(index: 1)
        try await store.append(entry)
        try removeFinalNewline(in: root)

        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [entry.id])
    }

    func testMalformedFinalLineWithoutNewlineIsSkipped() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let entry = makeEntry(index: 1)
        try await store.append(entry)
        try appendRaw(Data("{\"schema_version\":".utf8), to: root)

        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [entry.id])
    }

    func testAppendAndBackwardTailHandleLineLargerThanBlock() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        var expected: [DictationHistoryEntry] = []

        for index in 0..<12 {
            let text = index == 11 ? String(repeating: "длинная строка ", count: 8_000) : nil
            let entry = makeEntry(index: index, text: text)
            expected.append(entry)
            try await store.append(entry)
        }

        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), expected.suffix(10).reversed().map(\.id))
        XCTAssertEqual(recent.first?.text, expected.last?.text)

        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let firstLine = try XCTUnwrap(
            String(contentsOf: historyURL, encoding: .utf8).split(separator: "\n").first
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
        let timestamp = try XCTUnwrap(json["at"] as? String)
        XCTAssertTrue(timestamp.hasSuffix("Z"))
        XCTAssertTrue(timestamp.contains("."))
        XCTAssertEqual(json["schema_version"] as? Int, DictationHistoryEntry.currentSchemaVersion)
    }

    func testMalformedMiddleAndIncompleteTailAreSkippedAndIsolated() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let first = makeEntry(index: 1)
        let second = makeEntry(index: 2)
        let third = makeEntry(index: 3)
        try await store.append(first)

        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let handle = try FileHandle(forWritingTo: historyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        try await store.append(second)

        let partial = try FileHandle(forWritingTo: historyURL)
        try partial.seekToEnd()
        try partial.write(contentsOf: Data("{\"schema_version\":".utf8))
        try partial.close()

        let beforeRepair = try await store.recent(limit: 10)
        XCTAssertEqual(beforeRepair.map(\.id), [second.id, first.id])

        try await store.append(third)
        let afterRepair = try await store.recent(limit: 10)
        XCTAssertEqual(afterRepair.map(\.id), [third.id, second.id, first.id])
    }

    func testStoreCreatesPrivateDirectoryAndJSONLFile() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        try await store.append(makeEntry(index: 1))

        XCTAssertEqual(try permissions(of: root) & 0o777, 0o700)
        XCTAssertEqual(
            try permissions(of: root.appendingPathComponent(DictationHistoryStore.historyFileName)) & 0o777,
            0o600
        )
    }

    /// Clear All removes only what the archive made. A meeting
    /// moved into the archive's folder under an earlier setting survives it,
    /// as does any other document there; the dictations' audio (empty files
    /// too) and the index's temporary files go.
    func testClearAllKeepsAMeetingMovedIntoTheArchiveFolder() async throws {
        let dictations = try makeHistoryRoot()
        let parent = dictations.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = DictationHistoryStore(root: dictations)
        try await store.append(makeEntry(index: 0))
        let month = dictations.appendingPathComponent("2026/10", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let audio = month.appendingPathComponent(UUID().uuidString.lowercased() + ".m4a")
        let empty = month.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        try Data(repeating: 1, count: 16).write(to: audio)
        try Data().write(to: empty)
        let temporary = dictations.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        try Data("{}".utf8).write(to: temporary)
        let note = dictations.appendingPathComponent("notes.md")
        try Data("mine".utf8).write(to: note)
        let local = parent.appendingPathComponent("Meetings", isDirectory: true)
        _ = try await SavingMeetingCapture(root: local).stop()
        let target = dictations.appendingPathComponent("Moved meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let moved = try MeetingStorage.move(SavingMeetingCapture.folder(1, in: local), into: target, localRoot: local)

        try await store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "dictation audio left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "an empty dictation file left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path), "the index's temporary file left")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dictations.appendingPathComponent("2026").path),
            "empty year and month folders left"
        )
        let entries = try await store.recent(limit: 10)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("metadata.json").path),
                      "Clear All deleted a meeting")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("system.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "Clear All deleted a document")
    }

    /// The same boundary decides whether there is anything to clear: other
    /// files in the folder do not keep Clear All on for ever, an empty
    /// dictation file does turn it on.
    func testOnlyTheArchivesOwnFilesCountAsSomethingToClear() throws {
        let dictations = try makeHistoryRoot()
        let parent = dictations.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let meetings = parent.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let foreign = dictations.appendingPathComponent("2026-10-10 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: foreign.appendingPathComponent("system.m4a"))

        let foreignOnly = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )
        XCTAssertFalse(foreignOnly.hasDictationFiles, "a meeting in the folder keeps Clear All on")

        let month = dictations.appendingPathComponent("2026/10", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data().write(to: month.appendingPathComponent(UUID().uuidString.lowercased() + ".caf"))
        let leftover = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )
        XCTAssertTrue(leftover.hasDictationFiles, "an empty dictation file left by a failed clear is not seen")
    }

    /// A month folder whose names can't be read is not
    /// an empty one: Clear All fails, and the archive still has something to
    /// clear. Once the folder can be read again, the repeat removes the
    /// dictation's audio and keeps the document beside it.
    func testUnreadableMonthFailsClearAllUntilItCanBeRead() async throws {
        let dictations = try makeHistoryRoot()
        let parent = dictations.deletingLastPathComponent()
        let month = dictations.appendingPathComponent("2026/09", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: month.path)
            try? FileManager.default.removeItem(at: parent)
        }
        let meetings = parent.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let audio = month.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        let note = month.appendingPathComponent("notes.md")
        try Data(repeating: 1, count: 16).write(to: audio)
        try Data("mine".utf8).write(to: note)
        // Search and write, but no reading of the names inside.
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: month.path)
        let store = DictationHistoryStore(root: dictations)

        var failed = false
        do { try await store.clearAll() } catch { failed = true }
        XCTAssertTrue(failed, "Clear All succeeded with a month it could not read")
        let unreadable = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )
        XCTAssertTrue(unreadable.hasDictationFiles, "a month that can't be read was taken for an empty one")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: month.path)
        try await store.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "the repeat left the dictation's audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path), "the repeat deleted a document")
        let cleared = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )
        XCTAssertFalse(cleared.hasDictationFiles)
    }

    /// A month is two ASCII digits, 01 to 12, and a
    /// year four: `+1` reads as the number 1 but is no folder the archive
    /// makes, so what is in it stays.
    func testClearAllKeepsFoldersThatOnlyReadAsAMonthOrYear() async throws {
        let dictations = try makeHistoryRoot()
        let parent = dictations.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let meetings = parent.appendingPathComponent("Meetings", isDirectory: true)
        let kept = ["2026/+1", "+026/01"].map {
            dictations.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        }
        for file in kept {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 1, count: 16).write(to: file)
        }
        let store = DictationHistoryStore(root: dictations)

        let snapshot = ArchiveSnapshot.local(
            historyCount: 0, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )
        try await store.clearAll()

        XCTAssertFalse(snapshot.hasDictationFiles, "a file outside the archive's months is something to clear")
        for file in kept {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Clear All deleted \(file.path)")
        }
    }

    /// The dictations' size is the index and the
    /// archive's own audio: a meeting or a document in its folder is not a
    /// dictation, and stays there after Clear All.
    func testDictationBytesAreTheIndexAndTheArchivesOwnAudio() async throws {
        let dictations = try makeHistoryRoot()
        let parent = dictations.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let meetings = parent.appendingPathComponent("Meetings", isDirectory: true)
        let store = DictationHistoryStore(root: dictations)
        try await store.append(makeEntry(index: 0))
        let month = dictations.appendingPathComponent("2026/10", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: month.appendingPathComponent(UUID().uuidString.lowercased() + ".m4a"))
        let foreign = dictations.appendingPathComponent("2026-10-10 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: foreign.appendingPathComponent("system.m4a"))
        try Data(repeating: 1, count: 8).write(to: month.appendingPathComponent("notes.md"))
        let index = dictations.appendingPathComponent(DictationHistoryStore.historyFileName)
        let indexBytes = try XCTUnwrap(index.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let snapshot = ArchiveSnapshot.local(
            historyCount: 1, historyOldest: nil, dictationsRoot: dictations, meetingsRoot: meetings
        )

        XCTAssertEqual(snapshot.dictationBytes, Int64(indexBytes + 16), "files that are not dictations were counted")
    }

    private func appendRaw(_ data: Data, to root: URL) throws {
        let url = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func removeFinalNewline(in root: URL) throws {
        let url = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        XCTAssertGreaterThan(size, 0)
        try handle.truncate(atOffset: size - 1)
    }
}

@MainActor
final class DictationHistoryPlaybackTests: XCTestCase {
    func testPlaybackTogglesSwitchesAndStopsWithObservableState() async throws {
        let fixture = try makePlaybackFixture()
        defer { fixture.cleanup() }
        let first = makeEntry(index: 1, audioPath: "first.caf")
        let second = makeEntry(index: 2, audioPath: "second.caf")
        try makeSilentCAF(at: fixture.root.appendingPathComponent(first.audioPath), duration: 0.5)
        try makeSilentCAF(at: fixture.root.appendingPathComponent(second.audioPath), duration: 0.5)

        await fixture.model.play(first)
        XCTAssertEqual(fixture.model.playingEntryID, first.id)
        await fixture.model.play(first)
        XCTAssertNil(fixture.model.playingEntryID)

        await fixture.model.play(first)
        await fixture.model.play(second)
        XCTAssertEqual(fixture.model.playingEntryID, second.id)
        fixture.model.stopAudio()
        XCTAssertNil(fixture.model.playingEntryID)
    }

    func testNaturalPlaybackCompletionResetsObservableState() async throws {
        let fixture = try makePlaybackFixture()
        defer { fixture.cleanup() }
        let entry = makeEntry(index: 1, audioPath: "short.caf")
        try makeSilentCAF(at: fixture.root.appendingPathComponent(entry.audioPath), duration: 0.1)

        await fixture.model.play(entry)
        XCTAssertEqual(fixture.model.playingEntryID, entry.id)
        try await waitUntil { fixture.model.playingEntryID == nil }
    }

    func testDeletingPlayingEntryStopsPlaybackAndResetsState() async throws {
        let fixture = try makePlaybackFixture()
        defer { fixture.cleanup() }
        let entry = makeEntry(index: 1, audioPath: "delete.caf")
        try makeSilentCAF(at: fixture.root.appendingPathComponent(entry.audioPath), duration: 0.5)
        try await fixture.store.append(entry)

        await fixture.model.play(entry)
        XCTAssertEqual(fixture.model.playingEntryID, entry.id)
        let deleted = await fixture.model.delete(entry)
        XCTAssertTrue(deleted)
        XCTAssertNil(fixture.model.playingEntryID)
    }

    private func makePlaybackFixture() throws -> (
        root: URL,
        store: DictationHistoryStore,
        model: DictationHistoryViewModel,
        cleanup: () -> Void
    ) {
        let root = try makeHistoryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DictationHistoryStore(root: root)
        return (
            root,
            store,
            DictationHistoryViewModel(store: store),
            { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        )
    }

    private func makeSilentCAF(at url: URL, duration: TimeInterval) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for playback completion")
    }
}

@MainActor
final class DictationAudioArchiveTests: XCTestCase {
    func testPCMCAFIsArchivedAsPlayablePrivateMono24BitALAC() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = root.deletingLastPathComponent().appendingPathComponent("source.caf")
        try makePCMCAF(at: source, duration: 3)
        let store = DictationHistoryStore(root: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let archived = try await store.archiveAudio(from: source, id: UUID(), at: date)
        let audioURL = root.appendingPathComponent(archived.relativePath)
        let format = try audioFileDataFormat(at: audioURL)
        let player = try AVAudioPlayer(contentsOf: audioURL)
        player.volume = 0

        XCTAssertEqual(audioURL.pathExtension, "m4a")
        XCTAssertEqual(format.mFormatID, DictationHistoryStore.dictationArchiveFormatID)
        XCTAssertEqual(format.mFormatFlags, kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(format.mChannelsPerFrame, 1)
        XCTAssertEqual(format.mSampleRate, 48_000, accuracy: 0.01)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertTrue(player.play())
        player.stop()
        XCTAssertEqual(archived.duration, 3, accuracy: 0.01)
        XCTAssertGreaterThan(archived.fileSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try permissions(of: audioURL) & 0o777, 0o600)
        XCTAssertEqual(try permissions(of: audioURL.deletingLastPathComponent()) & 0o777, 0o700)
        XCTAssertEqual(
            try permissions(of: audioURL.deletingLastPathComponent().deletingLastPathComponent()) & 0o777,
            0o700
        )
    }

    func testInvalidAudioFallsBackToByteIdenticalPrivateCAF() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = root.deletingLastPathComponent().appendingPathComponent("broken.caf")
        let bytes = Data("not an audio file".utf8)
        try bytes.write(to: source)
        let store = DictationHistoryStore(root: root)

        let archived = try await store.archiveAudio(
            from: source,
            id: UUID(),
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let audioURL = root.appendingPathComponent(archived.relativePath)

        XCTAssertEqual(audioURL.pathExtension, "caf")
        XCTAssertEqual(try Data(contentsOf: audioURL), bytes)
        XCTAssertEqual(try permissions(of: audioURL) & 0o777, 0o600)
        XCTAssertEqual(archived.duration, 0)
    }

    func testArchiveSizeCountsAudioAndHistory() async throws {
        let root = try makeHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = root.deletingLastPathComponent().appendingPathComponent("source.caf")
        try makePCMCAF(at: source, duration: 0.05)
        let store = DictationHistoryStore(root: root)
        _ = try await store.archiveAudio(from: source, id: UUID(), at: Date())
        try await store.append(makeEntry(index: 1))

        let size = DictationHistoryStore.contentToClear(in: root).bytes
        XCTAssertGreaterThan(size, 0)
    }

    private func makePCMCAF(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var randomState: UInt32 = 0x1234_5678
        for frame in 0..<Int(frameCount) {
            randomState = 1_664_525 &* randomState &+ 1_013_904_223
            channel[frame] = (Float(randomState) / Float(UInt32.max) - 0.5) * 0.4
        }
        try file.write(from: buffer)
    }

    private func audioFileDataFormat(at url: URL) throws -> AudioStreamBasicDescription {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(
            url as CFURL,
            .readPermission,
            0,
            &audioFile
        )
        guard openStatus == noErr, let audioFile else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(openStatus))
        }
        defer { AudioFileClose(audioFile) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let readStatus = AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyDataFormat,
            &size,
            &format
        )
        guard readStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(readStatus))
        }
        return format
    }
}

/// Hands out a fresh copy of the template on every stop, like the real capture:
/// the coordinator deletes the source after a successful save.
actor HistoryPipelineMic: MicCapturing {
    let template: URL
    private(set) var lastSource: URL?

    init(template: URL) { self.template = template }

    func start() async throws {}

    func stop() async throws -> URL? {
        let source = template.deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).caf")
        try FileManager.default.copyItem(at: template, to: source)
        lastSource = source
        return source
    }
}

actor HistoryPipelineEngine: WhisperEngine {
    private var text: String
    private let language: String
    private var holdsDecodes = false
    private var failsNextDecode = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var requests: [WhisperDecodeRequest] = []

    init(text: String, language: String) {
        self.text = text
        self.language = language
    }

    func setText(_ text: String) { self.text = text }
    func holdDecodes() { holdsDecodes = true }
    func isHoldingDecode() -> Bool { held != nil }
    func releaseHeldDecode() { holdsDecodes = false; held?.resume(); held = nil }
    func failNextDecode() { failsNextDecode = true }

    func transcribe(
        audioPath: String,
        request: WhisperDecodeRequest
    ) async throws -> (segments: [WhisperSegmentDTO], language: String) {
        requests.append(request)
        if holdsDecodes { await withCheckedContinuation { held = $0 } }
        if failsNextDecode {
            failsNextDecode = false
            throw PipelineDecodeFailure()
        }
        let segments = text.isEmpty
            ? []
            : [WhisperSegmentDTO(text: text, start: 0)]
        return (segments, language)
    }
}

struct PipelineDecodeFailure: Error {}

private struct HistoryPipelineFactory: WhisperEngineFactory {
    let engine: HistoryPipelineEngine
    var failsLoad = false
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        if failsLoad { throw PipelineModelLoadFailure() }
        return engine
    }
}

struct PipelineModelLoadFailure: LocalizedError {
    var errorDescription: String? { "the model could not be loaded" }
}

actor DeliveryHistoryProbe {
    private(set) var entriesAtDelivery: [DictationHistoryEntry] = []
    private(set) var deliveredTexts: [String] = []
    private(set) var deliveredTargetPIDs: [pid_t?] = []

    func record(_ text: String, targetPID: pid_t?, entries: [DictationHistoryEntry]) {
        deliveredTexts.append(text)
        deliveredTargetPIDs.append(targetPID)
        entriesAtDelivery = entries
    }
}

/// Lets a test look at coordinator state at the exact moment of delivery, and
/// optionally hold the delivery open.
@MainActor
final class DeliveryHook {
    var action: (@MainActor (String) -> Void)?
    var gate: (@MainActor () async -> Void)?
}

/// Real coordinator, store and cache; only the microphone, the engine and the
/// final delivery are replaced. Uses only API that predates the save fixes, so the
/// regression tests below also compile against the unfixed code.
@MainActor
final class DictationPipelineFixture {
    let parent: URL
    let root: URL
    let store: DictationHistoryStore
    let engine: HistoryPipelineEngine
    let mic: HistoryPipelineMic
    /// The microphone the coordinator actually uses: `mic` unless `makeMic`
    /// supplied another one from the template clip.
    let activeMic: any MicCapturing
    let probe: DeliveryHistoryProbe
    let deliveryHook: DeliveryHook
    let indicator: RecordingIndicator
    let coordinator: DictationCoordinator
    /// Another running process posing as the frontmost app, so delivery has a
    /// real non-nil paste target instead of a forced clipboard fallback.
    let targetPID: pid_t
    let settings: SettingsStore
    private let defaultsName: String

    init(
        text: String,
        actualLanguage: String = "ru",
        sourceSeconds: Int = 0,
        templateSamples: [Float]? = nil,
        beforeHistoryReplace: @escaping @Sendable (URL) throws -> Void = { _ in },
        failsModelLoad: Bool = false,
        maxRecordingSeconds: TimeInterval = 300,
        makeMic: ((_ template: URL) -> any MicCapturing)? = nil
    ) throws {
        let root = try makeHistoryRoot()
        let parent = root.deletingLastPathComponent()
        let template = parent.appendingPathComponent("template.caf")
        try writePipelineCAF(at: template, seconds: sourceSeconds, samples: templateSamples)
        let defaultsName = "io.github.spacevibes365.MurmurlyTests.History.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let settings = SettingsStore(defaults: defaults)
        // These archive regression fixtures explicitly opt into audio storage.
        settings.saveDictationAudio = true
        // The fixture's engine stands in for Whisper.
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "auto"

        let store = DictationHistoryStore(
            root: root,
            beforeHistoryReplace: { try beforeHistoryReplace(root) }
        )
        let engine = HistoryPipelineEngine(text: text, language: actualLanguage)
        let probe = DeliveryHistoryProbe()
        let hook = DeliveryHook()
        // Follows the settings, so a test can turn the indicator off.
        let indicator = RecordingIndicator(
            settings: settings,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )
        let mic = HistoryPipelineMic(template: template)
        let activeMic: any MicCapturing = makeMic?(template) ?? mic
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The Dock is always running in a GUI session; any other app will do.
        let targetPID = try XCTUnwrap(
            (NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
                ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ownPID })?
                .processIdentifier
        )
        let coordinator = DictationCoordinator(
            mic: activeMic,
            indicator: indicator,
            startTimeout: 1,
            maxRecordingSeconds: maxRecordingSeconds,
            whisperCache: WhisperKitCache(
                factory: HistoryPipelineFactory(engine: engine, failsLoad: failsModelLoad)
            ),
            historyStore: store,
            deliveryOverride: { text, target in
                hook.action?(text)
                await hook.gate?()
                let deliveredPID = target?.processIdentifier
                let entries = (try? await store.recent(limit: 10)) ?? []
                await probe.record(text, targetPID: deliveredPID, entries: entries)
            },
            frontmostApplication: { NSRunningApplication(processIdentifier: targetPID) },
            feedbackPlayer: { _ in },
            beepPlayer: {}
        )
        coordinator.configureForTesting(settings: settings)

        self.parent = parent
        self.root = root
        self.store = store
        self.engine = engine
        self.mic = mic
        self.activeMic = activeMic
        self.probe = probe
        self.deliveryHook = hook
        self.indicator = indicator
        self.coordinator = coordinator
        self.targetPID = targetPID
        self.settings = settings
        self.defaultsName = defaultsName
    }

    func dictate() async throws {
        coordinator.beginCaptureForTesting()
        try await waitForDictation { self.coordinator.state == .recording }
        coordinator.toggle()
        try await waitForDictation(timeout: .seconds(30)) { self.coordinator.state == .idle }
    }

    func cleanup() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: parent)
    }
}

/// `seconds == 0` keeps the original 50 ms silent clip. Longer clips repeat one
/// second of noise so ALAC archiving takes a measurable time.
private func writePipelineCAF(at url: URL, seconds: Int, samples: [Float]? = nil) throws {
    let format = try XCTUnwrap(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    )
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    if let samples {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        try file.write(from: buffer)
        return
    }
    guard seconds > 0 else {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        try file.write(from: buffer)
        return
    }
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    var randomState: UInt32 = 0x1234_5678
    for frame in 0..<48_000 {
        randomState = 1_664_525 &* randomState &+ 1_013_904_223
        channel[frame] = (Float(randomState) / Float(UInt32.max) - 0.5) * 0.2
    }
    for _ in 0..<seconds {
        try file.write(from: buffer)
    }
}

@MainActor
func waitForDictation(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for dictation pipeline")
}

private func pipelineAudioFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }
        .filter { ["m4a", "caf"].contains($0.pathExtension.lowercased()) }
}

private func pipelineIndexLineCount(in root: URL) -> Int {
    let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
    guard let data = try? Data(contentsOf: historyURL) else { return 0 }
    return data.split(separator: DictationHistoryStore.newline).count
}

/// What `clearAll()` found on disk while it ran, recorded from inside the
/// store actor by the `beforeHistoryReplace` hook.
private final class ClearObservation: @unchecked Sendable {
    struct Snapshot: Equatable { let audioFiles: Int; let indexLines: Int }

    private let lock = NSLock()
    private var storage: [Snapshot] = []

    func record(root: URL) {
        let snapshot = Snapshot(
            audioFiles: pipelineAudioFiles(under: root).count,
            indexLines: pipelineIndexLineCount(in: root)
        )
        lock.withLock { storage.append(snapshot) }
    }

    var snapshots: [Snapshot] { lock.withLock { storage } }
}

@MainActor
final class DictationHistoryPipelineTests: XCTestCase {
    private static let historyNotSavedWarning = IndicatorState.dictationFailure(
        message: "History not saved — the text is in the “M” menu"
    )

    func testAudioOffPersistsTextBeforeDeliveryWithoutArchivingAudio() async throws {
        let fixture = try DictationPipelineFixture(text: "text without audio", sourceSeconds: 1)
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        try await fixture.dictate()
        let deliveredEntries = await fixture.probe.entriesAtDelivery
        XCTAssertEqual(deliveredEntries.first?.text, "text without audio")
        XCTAssertEqual(deliveredEntries.first?.audioPath, "")
        XCTAssertEqual(deliveredEntries.first?.duration ?? 0, 1, accuracy: 0.01)
        XCTAssertTrue(pipelineAudioFiles(under: fixture.root).isEmpty)
        let source = await fixture.mic.lastSource
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(source).path))
        let reopened = DictationHistoryStore(root: fixture.root)
        let entries = try await reopened.recent()
        XCTAssertEqual(entries, deliveredEntries)
        let audioIDs = await reopened.existingAudioIDs(for: entries)
        XCTAssertTrue(audioIDs.isEmpty)
        let deleted = try await reopened.delete(id: XCTUnwrap(entries.first).id)
        XCTAssertTrue(deleted)
        let remaining = try await reopened.recent()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAudioOffKeepsSourceAndTextWhenIndexCannotBeWritten() async throws {
        let fixture = try DictationPipelineFixture(text: "do not lose this")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(DictationHistoryStore.historyFileName),
            withIntermediateDirectories: true
        )
        try await fixture.dictate()
        let source = await fixture.mic.lastSource
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(source).path))
        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["do not lose this"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["do not lose this"])
    }

    func testAudioOffStillArchivesRecognitionFailure() async throws {
        let fixture = try DictationPipelineFixture(text: "not decoded")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        await fixture.engine.failNextDecode()
        try await fixture.dictate()
        XCTAssertEqual(pipelineAudioFiles(under: fixture.root).count, 1)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    /// №3. A dictation the engine could not recognize gets a history line
    /// with its audio, so it can be found and tried again; nothing is pasted.
    func testUnrecognizedDictationIsInHistoryWithItsAudio() async throws {
        let fixture = try DictationPipelineFixture(text: "never recognized")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.count, 1, "the unrecognized dictation is missing from the history")
        XCTAssertEqual(entries.first?.recognitionFailed, true)
        XCTAssertEqual(entries.first?.text, "")
        let audioPath = try XCTUnwrap(entries.first?.audioPath)
        XCTAssertFalse(audioPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(audioPath).path))
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    /// Dictation → model that never loads → what the app says: the dictation
    /// is in the history, the pill says where, and Settings names the model
    /// as the reason instead of calling it ready.
    func testDictationWhoseModelNeverLoadsIsKeptAndBlamesTheModel() async throws {
        let fixture = try DictationPipelineFixture(text: "unused", failsModelLoad: true)
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.map(\.recognitionFailed), [true])
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "Not recognized — the audio is in History; try it in Files")
        )
        XCTAssertEqual(fixture.coordinator.modelFailure, "the model could not be loaded")
        XCTAssertEqual(
            DictationCoordinator.readiness(
                modelDownloaded: true,
                microphoneGranted: true,
                modelState: fixture.coordinator.modelState,
                modelFailure: fixture.coordinator.modelFailure
            ),
            .modelFailed
        )
    }

    /// A decode error of a model that did load is not a model failure.
    func testDecodeErrorOfALoadedModelDoesNotBlameTheModel() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        XCTAssertNil(fixture.coordinator.modelFailure)
        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.map(\.recognitionFailed), [true])
    }

    /// №7. A dictation stopped by the length limit is recognized and
    /// delivered as usual, and the person is told why it ended — also with
    /// the indicator turned off, which still shows failure-style notices.
    func testDictationStoppedAtTheLimitIsDeliveredAndSaysWhy() async throws {
        let fixture = try DictationPipelineFixture(text: "long thought", maxRecordingSeconds: 0.3)
        defer { fixture.cleanup() }
        fixture.settings.overlayEnabled = false

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        // No toggle: the limit ends it.
        try await waitForDictation(timeout: .seconds(10)) { fixture.coordinator.state == .idle }

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["long thought"])
        XCTAssertEqual(
            fixture.indicator.visibleState,
            .dictationFailure(
                message: "Pasted · 12 — stopped at the 5-minute limit; dictate again to continue"
            )
        )
    }

    /// The menu keeps the reason until the next dictation ends.
    func testLimitIsNamedInTheMenuUntilTheNextDictation() async throws {
        let fixture = try DictationPipelineFixture(text: "words", maxRecordingSeconds: 1)
        defer { fixture.cleanup() }
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        try await waitForDictation(timeout: .seconds(10)) { fixture.coordinator.state == .idle }
        XCTAssertTrue(fixture.coordinator.lastDictationHitLimit)

        try await fixture.dictate()

        XCTAssertFalse(fixture.coordinator.lastDictationHitLimit)
        XCTAssertEqual(fixture.indicator.presentedState, .inserted(characterCount: 5))
    }

    /// A dictation refused because a meeting is being recorded
    /// says why even with the indicator turned off: otherwise the shortcut
    /// looks dead.
    func testDictationRefusedDuringAMeetingSaysWhyWithTheIndicatorOff() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        fixture.settings.overlayEnabled = false
        let meeting = MeetingRecorder(
            capture: SavingMeetingCapture(root: fixture.parent),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        meeting.toggle()
        try await waitForDictation { meeting.state == .recording }
        fixture.coordinator.meetingPeer = meeting

        fixture.coordinator.toggle()

        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertEqual(fixture.indicator.visibleState, .busyWithMeeting)
        meeting.toggle()
        try await waitForDictation { meeting.state == .idle }
    }

    /// Empty text on real speech is a recognition failure to the person (quiet
    /// mic, a filtered hallucination), so the audio is the only thing left to
    /// replay; an entry with neither text nor audio would be pure noise.
    func testAudioOffStillArchivesEmptyRecognition() async throws {
        let fixture = try DictationPipelineFixture(text: "")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        try await fixture.dictate()
        XCTAssertEqual(pipelineAudioFiles(under: fixture.root).count, 1)
        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.count, 1)
        let audioPath = try XCTUnwrap(entries.first?.audioPath)
        XCTAssertFalse(audioPath.isEmpty)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
    }

    func testHistoryIsDurableBeforeTextDeliveryAndKeepsActualLanguage() async throws {
        let fixture = try DictationPipelineFixture(text: "archive before paste", actualLanguage: "en")
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let deliveredEntries = await fixture.probe.entriesAtDelivery
        let storedEntries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(deliveredEntries.map(\.id), storedEntries.map(\.id))
        XCTAssertEqual(storedEntries.first?.text, "archive before paste")
        XCTAssertEqual(storedEntries.first?.selectedLanguage, "auto")
        XCTAssertEqual(storedEntries.first?.actualLanguage, "en")
        let audioPath = try XCTUnwrap(storedEntries.first?.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(audioPath).path))
    }

    /// Setting → coordinator → engine: the chosen language is what the engine
    /// is asked in, and "auto" asks in none.
    func testDictationAsksTheEngineInTheChosenLanguage() async throws {
        let fixture = try DictationPipelineFixture(text: "guten Tag", actualLanguage: "de")
        defer { fixture.cleanup() }

        fixture.settings.dictationLanguage = "de"
        try await fixture.dictate()
        fixture.settings.dictationLanguage = "auto"
        try await fixture.dictate()

        let requests = await fixture.engine.requests
        XCTAssertEqual(requests, [WhisperDecodeRequest(language: "de"), WhisperDecodeRequest(language: nil)])
        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(Set(entries.map(\.selectedLanguage)), ["de", "auto"])
    }

    func testEmptyRecognitionStillArchivesAudioAndDoesNotDeliver() async throws {
        let fixture = try DictationPipelineFixture(text: "", actualLanguage: "ru")
        defer { fixture.cleanup() }

        try await fixture.dictate()

        let storedEntries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(storedEntries.count, 1)
        XCTAssertEqual(storedEntries.first?.text, "")
        let deliveredCount = await fixture.probe.entriesAtDelivery.count
        XCTAssertEqual(deliveredCount, 0)
        let audioPath = try XCTUnwrap(storedEntries.first?.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(audioPath).path))
    }

    /// A clear queued while the dictation is being archived may run before
    /// or after the save, but must never leave an entry whose audio it deleted.
    func testClearAllDuringSaveNeverLeavesEntryWithoutAudio() async throws {
        let observation = ClearObservation()
        let fixture = try DictationPipelineFixture(
            text: "clear during save",
            sourceSeconds: 120,
            beforeHistoryReplace: { observation.record(root: $0) }
        )
        defer { fixture.cleanup() }

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        // The audio file appears when archiving starts. The clear below is then
        // queued on the store actor behind the archiving that is still running.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while pipelineAudioFiles(under: fixture.root).isEmpty,
              fixture.coordinator.state != .idle,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let audioBeforeClear = pipelineAudioFiles(under: fixture.root).count
        let linesBeforeClear = pipelineIndexLineCount(in: fixture.root)
        let windowCaught = audioBeforeClear == 1 && linesBeforeClear == 0
        if windowCaught {
            try await fixture.store.clearAll()
        }
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }

        let atClear = observation.snapshots
        print("Clear window: before-clear audio=\(audioBeforeClear) lines=\(linesBeforeClear); clear saw \(atClear)")
        guard windowCaught, atClear.count == 1, atClear[0].audioFiles == 1 else {
            throw XCTSkip("The save window was not caught — the check proves nothing")
        }

        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertLessThanOrEqual(entries.count, 1)
        for entry in entries {
            let audio = await fixture.store.audioURL(for: entry)
            XCTAssertNotNil(audio, "History entry points at audio deleted by clearAll")
        }
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["clear during save"])
    }

    /// Recognized text is delivered even when the archive is unusable.
    func testUnavailableArchiveStillDeliversTextHonestly() async throws {
        let fixture = try DictationPipelineFixture(text: "keep this text")
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["keep this text"])
        let targets = await fixture.probe.deliveredTargetPIDs
        XCTAssertEqual(targets, [fixture.targetPID], "paste target kept, not forced to clipboard")
        XCTAssertEqual(fixture.indicator.presentedState, Self.historyNotSavedWarning)
        let lastSource = await fixture.mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// A failed index write keeps both the source and the archived copy:
    /// the line may be partially written, so the audio must not disappear.
    func testFailedIndexAppendKeepsBothAudioCopies() async throws {
        let fixture = try DictationPipelineFixture(text: "index is broken")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(
                DictationHistoryStore.historyFileName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["index is broken"])
        let targets = await fixture.probe.deliveredTargetPIDs
        XCTAssertEqual(targets, [fixture.targetPID], "paste target kept, not forced to clipboard")
        XCTAssertEqual(fixture.indicator.presentedState, Self.historyNotSavedWarning)
        let lastSource = await fixture.mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source CAF deleted")
        XCTAssertEqual(pipelineAudioFiles(under: fixture.root).count, 1, "archived copy deleted")
    }

    /// A design decision, not a red test: clearing while the engine is still
    /// recognizing must not remove the dictation that is about to be saved.
    func testClearDuringRecognitionKeepsCurrentDictation() async throws {
        let fixture = try DictationPipelineFixture(text: "survives clear")
        defer { fixture.cleanup() }
        await fixture.engine.holdDecodes()

        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { await fixture.engine.isHoldingDecode() }
        try await fixture.store.clearAll()
        await fixture.engine.releaseHeldDecode()
        try await waitForDictation { fixture.coordinator.state == .idle }

        let entries = try await fixture.store.recent(limit: 10)
        XCTAssertEqual(entries.map(\.text), ["survives clear"])
        if let entry = entries.first {
            let audio = await fixture.store.audioURL(for: entry)
            XCTAssertNotNil(audio)
        }
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["survives clear"])
    }
}
