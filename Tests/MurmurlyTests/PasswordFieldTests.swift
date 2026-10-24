import AppKit
import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

private func makePasswordFieldHistoryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Dictations", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return root
}

private func writePasswordFieldTemplateCAF(at url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
    buffer.frameLength = 2_400
    try file.write(from: buffer)
}

private struct PasswordFieldEngineFactory: WhisperEngineFactory {
    let engine: HistoryPipelineEngine
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine { engine }
}

@MainActor
private final class PasswordFieldFeedbackProbe {
    var feedbackNames: [NSSound.Name] = []
    var beeps = 0

    func play(_ name: NSSound.Name) { feedbackNames.append(name) }
    func beep() { beeps += 1 }
}

/// Holds its own uniquely named pasteboard, so a test can see exactly what the
/// fallback path writes without touching the real clipboard.
@MainActor
private final class PasswordFieldPasteboardProbe {
    let pasteboard = NSPasteboard.withUniqueName()
    private(set) var writeCount = 0

    func placeLocally(_ text: String) -> Bool {
        writeCount += 1
        return TextInjector.placeLocally(
            text,
            pasteboard: pasteboard,
            prepare: { pasteboard, options in pasteboard.prepareForNewContents(with: options) },
            writeText: { pasteboard, text in pasteboard.writeObjects([text as NSString]) }
        )
    }

    func releaseGlobally() { pasteboard.releaseGlobally() }
}

/// A coordinator without `deliveryOverride`, so delivery really goes through
/// `deliver`'s accessibility-trust and fallback branches, with the real
/// clipboard replaced by `pasteboardProbe`'s own pasteboard.
@MainActor
private final class PasswordFieldFallbackFixture {
    let parent: URL
    let root: URL
    let store: DictationHistoryStore
    let engine: HistoryPipelineEngine
    let mic: HistoryPipelineMic
    let indicator: RecordingIndicator
    let coordinator: DictationCoordinator
    let feedback: PasswordFieldFeedbackProbe
    let pasteboardProbe: PasswordFieldPasteboardProbe
    let settings: SettingsStore
    private let defaultsName: String

    init(text: String) throws {
        let root = try makePasswordFieldHistoryRoot()
        let parent = root.deletingLastPathComponent()
        let template = parent.appendingPathComponent("template.caf")
        try writePasswordFieldTemplateCAF(at: template)
        let defaultsName = "io.github.spacevibes365.MurmurlyTests.PasswordField.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let settings = SettingsStore(defaults: defaults)
        settings.saveDictationAudio = true
        settings.dictationEngine = .whisper
        settings.dictationLanguage = "auto"
        // Isolated from the "recording started" sound to tell the fallback
        // beep apart from feedback-sound calls.
        settings.soundOnRecordingStart = false
        settings.soundOnInsert = true

        let store = DictationHistoryStore(root: root)
        let engine = HistoryPipelineEngine(text: text, language: "en")
        let indicator = RecordingIndicator(
            settings: settings,
            levelMeter: MicrophoneLevelMeter(),
            renderingEnabled: false
        )
        let mic = HistoryPipelineMic(template: template)
        let feedback = PasswordFieldFeedbackProbe()
        let pasteboardProbe = PasswordFieldPasteboardProbe()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetPID = try XCTUnwrap(
            (NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
                ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ownPID })?
                .processIdentifier
        )

        let coordinator = DictationCoordinator(
            mic: mic,
            indicator: indicator,
            startTimeout: 1,
            whisperCache: WhisperKitCache(factory: PasswordFieldEngineFactory(engine: engine)),
            historyStore: store,
            frontmostApplication: { NSRunningApplication(processIdentifier: targetPID) },
            feedbackPlayer: { feedback.play($0) },
            beepPlayer: { feedback.beep() }
        )
        coordinator.configureForTesting(settings: settings)
        // No Accessibility trust: delivery must take the clipboard fallback
        // whenever a password field does not block it first.
        coordinator.accessibilityTrustedForTesting = false
        coordinator.placeLocallyForTesting = { pasteboardProbe.placeLocally($0) }

        self.parent = parent
        self.root = root
        self.store = store
        self.engine = engine
        self.mic = mic
        self.indicator = indicator
        self.coordinator = coordinator
        self.feedback = feedback
        self.pasteboardProbe = pasteboardProbe
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
        pasteboardProbe.releaseGlobally()
        UserDefaults().removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: parent)
    }
}

@MainActor
final class PasswordFieldTests: XCTestCase {
    private static let passwordFieldPastedFlash = IndicatorState.dictationFailure(
        message: "Password field — not pasted; the text is in Dictations"
    )
    private static let passwordFieldHistoryNotSavedFlash = IndicatorState.dictationFailure(
        message: "Password field — not pasted; the text is in the “M” menu"
    )
    private static let historyNotSavedFlash = IndicatorState.dictationFailure(
        message: "History not saved — the text is in the “M” menu"
    )

    func testPasswordFieldGetsNoPasteAndTheTextStaysInHistory() async throws {
        let fixture = try DictationPipelineFixture(text: "secret field text")
        defer { fixture.cleanup() }
        fixture.coordinator.secureFieldCheckForTesting = { true }

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty, "the paste stand-in must not run for a password field")
        let entries = try await fixture.store.recent()
        XCTAssertEqual(entries.first?.text, "secret field text")
        XCTAssertEqual(fixture.indicator.presentedState, Self.passwordFieldPastedFlash)
    }

    func testPasswordFieldLeavesTheClipboardUntouchedOnTheFallbackPath() async throws {
        let fixture = try PasswordFieldFallbackFixture(text: "secret from the fallback path")
        defer { fixture.cleanup() }
        fixture.coordinator.secureFieldCheckForTesting = { true }
        let pasteboard = fixture.pasteboardProbe.pasteboard
        pasteboard.prepareForNewContents(with: [])
        pasteboard.writeObjects(["pre-existing clipboard text" as NSString])
        let changeCountBefore = pasteboard.changeCount
        let contentBefore = pasteboard.string(forType: .string)

        try await fixture.dictate()

        XCTAssertEqual(fixture.pasteboardProbe.writeCount, 0, "the fallback must not be reached")
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.string(forType: .string), contentBefore)
        XCTAssertEqual(fixture.indicator.presentedState, Self.passwordFieldPastedFlash)
        XCTAssertEqual(fixture.feedback.feedbackNames.count, 0)
        XCTAssertEqual(fixture.feedback.beeps, 0)
    }

    func testFallbackWritesTheClipboardForAnOrdinaryField() async throws {
        let fixture = try PasswordFieldFallbackFixture(text: "ordinary field text")
        defer { fixture.cleanup() }
        fixture.coordinator.secureFieldCheckForTesting = { false }

        try await fixture.dictate()

        XCTAssertEqual(fixture.pasteboardProbe.writeCount, 1)
        let text = fixture.pasteboardProbe.pasteboard.string(forType: .string)
        XCTAssertEqual(text, "ordinary field text")
        XCTAssertEqual(fixture.feedback.beeps, 1, "the clipboard-fallback beep must fire exactly once")
        XCTAssertEqual(fixture.feedback.feedbackNames.count, 0)
        XCTAssertEqual(fixture.indicator.presentedState, .clipboardFallback)
    }

    func testPasswordFlashSurvivesAFailedHistorySave() async throws {
        let fixture = try DictationPipelineFixture(text: "unsaved secret")
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)
        fixture.coordinator.secureFieldCheckForTesting = { true }

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(fixture.indicator.presentedState, Self.passwordFieldHistoryNotSavedFlash)
        XCTAssertNotEqual(fixture.indicator.presentedState, Self.historyNotSavedFlash)
        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["unsaved secret"])
    }

    func testOrdinaryFieldStillGetsThePaste() async throws {
        let fixture = try DictationPipelineFixture(text: "plain field text")
        defer { fixture.cleanup() }
        fixture.coordinator.secureFieldCheckForTesting = { false }

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["plain field text"])
        XCTAssertEqual(fixture.indicator.presentedState, .inserted(characterCount: "plain field text".count))
    }

    func testUnknownFieldStillGetsThePaste() async throws {
        let fixture = try DictationPipelineFixture(text: "unnamed field text")
        defer { fixture.cleanup() }
        fixture.coordinator.secureFieldCheckForTesting = { nil }

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["unnamed field text"])
        XCTAssertEqual(fixture.indicator.presentedState, .inserted(characterCount: "unnamed field text".count))
    }

    func testOnlyTheSecureSubroleCountsAsPassword() {
        XCTAssertTrue(AccessibilityAuthorization.isSecureTextField(subrole: "AXSecureTextField"))
        XCTAssertFalse(AccessibilityAuthorization.isSecureTextField(subrole: "AXSearchField"))
        XCTAssertFalse(AccessibilityAuthorization.isSecureTextField(subrole: "AXTextField"))
        XCTAssertFalse(AccessibilityAuthorization.isSecureTextField(subrole: nil))
    }
}
