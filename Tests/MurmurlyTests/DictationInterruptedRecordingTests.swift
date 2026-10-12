import Foundation
import XCTest
@testable import Murmurly

/// New API around interrupted dictations. Kept apart from MicCaptureStopTests,
/// which must also compile against the pre-fix tree for the red check.
@MainActor
final class DictationInterruptedRecordingTests: XCTestCase {
    func testSavedFragmentIsMarkedInRecentHistory() async throws {
        let fixture = try DictationPipelineFixture(
            text: "first half",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false

        try await fixture.dictate()

        try await waitForDictation { !fixture.coordinator.recentDictations.isEmpty }
        let recent = try XCTUnwrap(fixture.coordinator.recentDictations.first)
        XCTAssertEqual(recent.text, "first half")
        XCTAssertEqual(recent.interrupted, true)
        XCTAssertNil(recent.recognitionFailed)
        XCTAssertFalse(recent.audioPath.isEmpty)
        let audio = await fixture.store.audioURL(for: recent)
        XCTAssertNotNil(audio)
        XCTAssertTrue(fixture.coordinator.unsavedDictations.isEmpty)
    }

    func testBrokenHistoryListsFragmentWithText() async throws {
        let fixture = try DictationPipelineFixture(
            text: "half",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)

        try await fixture.dictate()

        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["half"])
        let item = try XCTUnwrap(fixture.coordinator.unsavedDictations.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path))
        XCTAssertTrue(fixture.coordinator.recentDictations.isEmpty)
    }

    func testBrokenHistoryListsUnrecognizedFragmentWithoutText() async throws {
        let fixture = try DictationPipelineFixture(
            text: "never decoded",
            makeMic: { AdoptedFailingMic(template: $0) }
        )
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), [""])
        let item = try XCTUnwrap(fixture.coordinator.unsavedDictations.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path))
    }

    func testInterruptionFieldsAreWrittenOnlyWhenSet() throws {
        let plain = makeEntry()
        let plainJSON = try jsonObject(plain)
        XCTAssertNil(plainJSON["interrupted"])
        XCTAssertNil(plainJSON["recognition_failed"])

        let cut = makeEntry(interrupted: true, recognitionFailed: true)
        let cutJSON = try jsonObject(cut)
        XCTAssertEqual(cutJSON["interrupted"] as? Bool, true)
        XCTAssertEqual(cutJSON["recognition_failed"] as? Bool, true)

        let decoded = try JSONDecoder().decode(
            DictationHistoryEntry.self,
            from: JSONEncoder().encode(cut)
        )
        XCTAssertEqual(decoded, cut)
    }

    private func makeEntry(
        interrupted: Bool? = nil,
        recognitionFailed: Bool? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(),
            at: Date(timeIntervalSince1970: 1_760_000_000),
            duration: 1.5,
            selectedLanguage: "auto",
            actualLanguage: "ru",
            targetBundleID: nil,
            targetApplicationName: nil,
            audioPath: "2025/10/fragment.caf",
            text: "",
            interrupted: interrupted,
            recognitionFailed: recognitionFailed
        )
    }

    private func jsonObject(_ entry: DictationHistoryEntry) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
    }
}
