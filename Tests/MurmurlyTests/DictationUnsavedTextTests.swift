import Foundation
import XCTest
@testable import Murmurly

/// The in-memory unsaved list is new API. These tests live apart from the
/// regression tests in DictationHistoryTests.swift, which must also compile
/// against the code before the fix.
@MainActor
final class DictationUnsavedTextTests: XCTestCase {
    func testUnsavedTextIsListedBeforeDeliveryAndStaysAfterIt() async throws {
        let fixture = try DictationPipelineFixture(text: "first words")
        defer { fixture.cleanup() }
        try breakArchive(of: fixture)
        let coordinator = fixture.coordinator
        var listedAtDelivery: [[String]] = []
        fixture.deliveryHook.action = { _ in
            listedAtDelivery.append(coordinator.unsavedDictations.map(\.text))
        }

        try await fixture.dictate()

        XCTAssertEqual(listedAtDelivery, [["first words"]])
        XCTAssertEqual(coordinator.unsavedDictations.map(\.text), ["first words"])
        XCTAssertTrue(coordinator.recentDictations.isEmpty, "no fake history entry")
        let item = try XCTUnwrap(coordinator.unsavedDictations.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path))
    }

    func testUnsavedTextsSurviveNextDictationAndClearAll() async throws {
        let fixture = try DictationPipelineFixture(text: "first")
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        try breakArchive(of: fixture)
        try await fixture.dictate()
        await fixture.engine.setText("second")
        try await fixture.dictate()
        XCTAssertEqual(coordinator.unsavedDictations.map(\.text), ["second", "first"])

        try FileManager.default.removeItem(at: fixture.root)
        await fixture.engine.setText("third")
        try await fixture.dictate()
        let savedSource = await fixture.mic.lastSource
        let thirdSource = try XCTUnwrap(savedSource)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: thirdSource.path),
            "a fully saved dictation removes its source"
        )
        // The recent menu follows the store's change signal asynchronously.
        try await waitForDictation { coordinator.recentDictations.map(\.text) == ["third"] }
        XCTAssertEqual(coordinator.unsavedDictations.map(\.text), ["second", "first"])

        try await fixture.store.clearAll()
        try await waitForDictation { coordinator.recentDictations.isEmpty }

        XCTAssertEqual(coordinator.unsavedDictations.map(\.text), ["second", "first"])
        for item in coordinator.unsavedDictations {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path))
        }
    }

    func testRemoveDropsOnlySelectedItemAndKeepsItsAudio() async throws {
        let fixture = try DictationPipelineFixture(text: "keep")
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        try breakArchive(of: fixture)
        try await fixture.dictate()
        await fixture.engine.setText("drop")
        try await fixture.dictate()
        let dropped = try XCTUnwrap(coordinator.unsavedDictations.first)
        XCTAssertEqual(dropped.text, "drop")

        coordinator.removeUnsavedDictation(id: dropped.id)

        XCTAssertEqual(coordinator.unsavedDictations.map(\.text), ["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dropped.sourceAudio.path))
    }

    func testCopyNeverRemovesUnsavedText() async throws {
        let fixture = try DictationPipelineFixture(text: "copy me")
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        try breakArchive(of: fixture)
        try await fixture.dictate()
        let item = try XCTUnwrap(coordinator.unsavedDictations.first)

        XCTAssertFalse(coordinator.copyUnsavedDictation(item, place: { _ in false }))
        XCTAssertEqual(coordinator.unsavedDictations, [item])
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "Couldn’t copy — the text stays in the “M” menu")
        )

        var placed: [String] = []
        XCTAssertTrue(coordinator.copyUnsavedDictation(item, place: { placed.append($0); return true }))
        XCTAssertEqual(placed, ["copy me"])
        XCTAssertEqual(coordinator.unsavedDictations, [item])
    }

    /// An unrecognized dictation whose save failed keeps its source audio
    /// and is listed, without text, so it is not lost silently.
    func testUnrecognizedDictationWithoutHistoryIsListedWithItsAudio() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        try breakArchive(of: fixture)
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        let item = try XCTUnwrap(fixture.coordinator.unsavedDictations.first)
        XCTAssertEqual(fixture.coordinator.unsavedDictations.count, 1)
        XCTAssertEqual(item.text, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path))
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "Not recognized; the audio is kept in the “M” menu until you quit")
        )
    }

    /// A regular file where the archive directory should be makes every save fail.
    private func breakArchive(of fixture: DictationPipelineFixture) throws {
        try Data("not a directory".utf8).write(to: fixture.root)
    }
}
