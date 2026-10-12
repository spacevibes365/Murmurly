import Foundation
import XCTest
@testable import Murmurly

/// Kept from the deleted MeetingAudioWriterTests: these assertions cover
/// RecordingsStore, which is on the shipping path, not the dead writer that was
/// removed with that file.
final class RecordingsStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // RecordingsStore is @MainActor; setUp/tearDown stay nonisolated, so the
    // isolation sits on the test itself — same shape this test had before.
    @MainActor
    func testAtomicMetadataAndUniqueFolders() throws {
        let store = RecordingsStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let one = try store.createSession(date: date, root: root)
        let two = try store.createSession(date: date, root: root)
        XCTAssertNotEqual(one, two)

        let metadata = MeetingMetadata(
            startedAt: "2026-01-01T00:00:00Z",
            endedAt: "2026-01-01T01:00:00Z",
            sampleRate: 48_000,
            state: "done",
            segments: []
        )
        try store.writeMetadata(metadata, to: one)
        let decoded = try JSONDecoder().decode(
            MeetingMetadata.self,
            from: Data(contentsOf: one.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(decoded, metadata)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: one.path)
            .contains { $0.contains("tmp") })
    }

    func testMetadataWithoutTriggerStillDecodes() throws {
        let data = Data("""
        {
            "startedAt":"2026-01-01T00:00:00Z",
            "endedAt":"2026-01-01T01:00:00Z",
            "sampleRate":48000,
            "state":"done",
            "segments":[]
        }
        """.utf8)

        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: data)

        XCTAssertNil(metadata.trigger)
    }
}
