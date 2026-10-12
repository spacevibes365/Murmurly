import Foundation
import XCTest
@testable import Murmurly

private enum RewriteInterruption: Error {
    case simulated
}

private func makeManagementRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent.appendingPathComponent("Dictations", isDirectory: true)
}

private func makeManagementEntry(
    index: Int,
    text: String? = nil,
    audioPath: String? = nil
) -> DictationHistoryEntry {
    DictationHistoryEntry(
        id: UUID(),
        at: Date(timeIntervalSince1970: 1_750_000_000 + Double(index)),
        duration: Double(index) + 0.5,
        selectedLanguage: "auto",
        actualLanguage: index.isMultiple(of: 2) ? "ru" : "en",
        targetBundleID: "com.example.editor",
        targetApplicationName: "Editor",
        audioPath: audioPath ?? "2025/06/entry-\(index).m4a",
        text: text ?? "entry-\(index)"
    )
}

private func managementPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
}

@MainActor
final class DictationHistoryManagementTests: XCTestCase {
    func testPagesUseStableCursorAndHandleLineLargerThanReadBlock() async throws {
        let root = try makeManagementRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        var expected: [DictationHistoryEntry] = []

        for index in 0..<17 {
            let text = index == 8 ? String(repeating: "очень длинная строка ", count: 5_000) : nil
            let entry = makeManagementEntry(index: index, text: text)
            expected.append(entry)
            try await store.append(entry)
        }

        var cursor: UInt64?
        var collected: [DictationHistoryEntry] = []
        repeat {
            let page = try await store.page(before: cursor, limit: 4)
            collected.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(collected.map(\.id), expected.reversed().map(\.id))
        let recent = try await store.recent(limit: 3)
        XCTAssertEqual(recent.map(\.id), expected.suffix(3).reversed().map(\.id))
    }

    func testSearchIsCaseInsensitivePaginatedAndReturnsNoMissingMatch() async throws {
        let root = try makeManagementRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let first = makeManagementEntry(index: 1, text: "ПрИвЕт, мир")
        let middle = makeManagementEntry(index: 2, text: "ничего общего")
        let last = makeManagementEntry(index: 3, text: "снова ПРИВЕТ")
        for entry in [first, middle, last] { try await store.append(entry) }

        let newest = try await store.page(limit: 1, matching: "привет")
        XCTAssertEqual(newest.entries.map(\.id), [last.id])
        let older = try await store.page(
            before: try XCTUnwrap(newest.nextCursor),
            limit: 1,
            matching: "ПРИВЕТ"
        )
        XCTAssertEqual(older.entries.map(\.id), [first.id])
        XCTAssertNil(older.nextCursor)

        let missing = try await store.page(limit: 20, matching: "отсутствует")
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertNil(missing.nextCursor)
    }

    func testDeleteKeepsNeighborsRemovesAudioAndRewritesWithPrivateMode() async throws {
        let root = try makeManagementRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let first = try await entryWithAudio(index: 1, store: store)
        let deleted = try await entryWithAudio(index: 2, store: store)
        let last = try await entryWithAudio(index: 3, store: store)
        for entry in [first, deleted, last] { try await store.append(entry) }

        let didDelete = try await store.delete(id: deleted.id)
        XCTAssertTrue(didDelete)

        let remaining = try await store.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [last.id, first.id])
        let firstAudio = await store.audioURL(for: first)
        let deletedAudio = await store.audioURL(for: deleted)
        let lastAudio = await store.audioURL(for: last)
        XCTAssertNotNil(firstAudio)
        XCTAssertNil(deletedAudio)
        XCTAssertNotNil(lastAudio)
        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        XCTAssertEqual(try managementPermissions(of: historyURL) & 0o777, 0o600)
    }

    func testClearAllRemovesIndexedAndOrphanedAudio() async throws {
        let root = try makeManagementRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        let entry = try await entryWithAudio(index: 1, store: store)
        try await store.append(entry)
        let audioDirectory = try await store.ensurePrivateAudioDirectory(for: entry.at)
        // Named as the archive names its audio: only such files are its own.
        let orphan = audioDirectory.directory.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        try await store.createPrivateEmptyFile(at: orphan)
        try writeBytes(Data("orphan".utf8), to: orphan)

        try await store.clearAll()

        let recent = try await store.recent(limit: 10)
        XCTAssertTrue(recent.isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), [DictationHistoryStore.historyFileName])
        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        XCTAssertEqual(try Data(contentsOf: historyURL), Data())
        XCTAssertEqual(try managementPermissions(of: historyURL) & 0o777, 0o600)
        XCTAssertEqual(try managementPermissions(of: root) & 0o777, 0o700)
    }

    func testInterruptedRewriteLeavesOriginalArchiveAndAudioUntouched() async throws {
        let root = try makeManagementRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(
            root: root,
            beforeHistoryReplace: { throw RewriteInterruption.simulated }
        )
        let entry = try await entryWithAudio(index: 1, store: store)
        try await store.append(entry)
        let historyURL = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        let original = try Data(contentsOf: historyURL)

        do {
            try await store.delete(id: entry.id)
            XCTFail("Expected the injected interruption")
        } catch RewriteInterruption.simulated {
            // Expected: the hook runs after the private temporary file is synced.
        }

        XCTAssertEqual(try Data(contentsOf: historyURL), original)
        let audioURL = await store.audioURL(for: entry)
        XCTAssertNotNil(audioURL)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".history-") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    private func entryWithAudio(
        index: Int,
        store: DictationHistoryStore
    ) async throws -> DictationHistoryEntry {
        let date = Date(timeIntervalSince1970: 1_750_000_000 + Double(index))
        let directory = try await store.ensurePrivateAudioDirectory(for: date)
        let id = UUID()
        let fileName = "\(id.uuidString).m4a"
        let audioURL = directory.directory.appendingPathComponent(fileName)
        try await store.createPrivateEmptyFile(at: audioURL)
        try writeBytes(Data("audio-\(index)".utf8), to: audioURL)
        return DictationHistoryEntry(
            id: id,
            at: date,
            duration: Double(index),
            selectedLanguage: "auto",
            actualLanguage: "ru",
            targetBundleID: "com.example.editor",
            targetApplicationName: "Editor",
            audioPath: "\(directory.relativePath)/\(fileName)",
            text: "entry-\(index)"
        )
    }

    private func writeBytes(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
