import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

/// Resumes a continuation once; later answers are ignored.
private final class OnceAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?

    init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

    func give(_ value: Bool?) {
        let pending: CheckedContinuation<Bool?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// The task's result, or nil at the timeout. Never joins the task: quit-time
/// work may legitimately be stuck, and a hung test proves nothing.
@MainActor
private func result(of task: Task<Bool, Never>, within timeout: Duration = .seconds(10)) async -> Bool? {
    await withCheckedContinuation { continuation in
        let answer = OnceAnswer(continuation)
        Task { answer.give(await task.value) }
        Task {
            try? await Task.sleep(for: timeout)
            answer.give(nil)
        }
    }
}

@MainActor
private final class TestGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var entered = false

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// Holds the first `start()` until opened, like Core Audio stalling.
private actor GatedStartMic: MicCapturing {
    private let template: URL
    private let returnsEmptyFile: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var starts = 0
    private(set) var lastSource: URL?

    init(template: URL, returnsEmptyFile: Bool = false) {
        self.template = template
        self.returnsEmptyFile = returnsEmptyFile
    }

    func start() async throws {
        starts += 1
        if starts == 1, !isOpen { await withCheckedContinuation { gate = $0 } }
    }

    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }

    func stop() async throws -> URL? {
        let source = template.deletingLastPathComponent()
            .appendingPathComponent("late-\(UUID().uuidString).caf")
        if returnsEmptyFile {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
            if let format {
                _ = try AVAudioFile(forWriting: source, settings: format.settings)
            }
        } else {
            try FileManager.default.copyItem(at: template, to: source)
        }
        lastSource = source
        return source
    }
}

private struct PlainStopFailure: LocalizedError {
    var errorDescription: String? { "recording did not finish" }
}

private actor FakeQuitMeetingCapture: MeetingCaptureBackend {
    enum StopBehavior: Sendable {
        case succeed, failWithMetadata, failWithIntermediateMetadata, failWithoutEvidence
    }

    let directory: URL
    let behavior: StopBehavior
    private(set) var stops = 0

    init(directory: URL, behavior: StopBehavior) {
        self.directory = directory
        self.behavior = behavior
    }

    func start(in _: URL) async throws -> Date {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Date()
    }

    func stop() async throws -> [URL] {
        stops += 1
        switch behavior {
        case .succeed:
            try writeMetadata(state: "done")
            return [directory.appendingPathComponent("system.caf")]
        case .failWithMetadata:
            try writeMetadata(state: "failed")
            throw SystemAudioCaptureError.captureFailed(message: "track failure", savedAt: directory)
        case .failWithIntermediateMetadata:
            try writeMetadata(state: "recording")
            throw SystemAudioCaptureError.captureFailed(message: "track failure", savedAt: directory)
        case .failWithoutEvidence:
            throw PlainStopFailure()
        }
    }

    private func writeMetadata(state: String) throws {
        let metadata = MeetingMetadata(
            startedAt: "2026-10-02T10:00:00Z",
            endedAt: "2026-10-02T10:01:00Z",
            sampleRate: 48_000,
            state: state,
            segments: []
        )
        try JSONEncoder().encode(metadata)
            .write(to: directory.appendingPathComponent("metadata.json"))
    }
}

private final class QuitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A value a test changes while the delegate reads it through a closure.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private struct NoQuitWhisperFactory: WhisperEngineFactory {
    func make(modelFolder: String, prewarm: Bool) async throws -> any WhisperEngine {
        throw TranscriptionError.engineUnavailable("not used")
    }
}

@MainActor
final class GracefulQuitTests: XCTestCase {
    // MARK: Dictation

    func testQuitDuringRecognitionSavesAudioWithoutWaitingForModel() async throws {
        let fixture = try DictationPipelineFixture(text: "never arrives")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        await fixture.engine.holdDecodes()
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { await fixture.engine.isHoldingDecode() }

        // The model stays held for the whole quit.
        let saved = await result(of: fixture.coordinator.beginTermination())

        XCTAssertEqual(saved, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["recognition_skipped"] as? Bool, true)
        XCTAssertEqual(lines.first?["text"] as? String, "")
        try assertAudioExists(for: lines.first, in: fixture.root, extension: "caf")
        let lastSource = await fixture.mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "source kept after a confirmed save")
        XCTAssertEqual(fixture.coordinator.state, .idle)

        // A late answer of the abandoned decode must not write, paste or delete anything.
        await fixture.engine.releaseHeldDecode()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try historyLines(in: fixture.root).count, 1)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        try assertAudioExists(for: lines.first, in: fixture.root, extension: "caf")
    }

    /// The pipeline's failure branch now saves too: a decode that fails after
    /// quit took the dictation over must not add a second entry.
    func testRecognitionFailingAfterQuitTookOverLeavesOneEntry() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        await fixture.engine.holdDecodes()
        await fixture.engine.failNextDecode()
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { await fixture.engine.isHoldingDecode() }

        let saved = await result(of: fixture.coordinator.beginTermination())
        await fixture.engine.releaseHeldDecode()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(saved, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["recognition_skipped"] as? Bool, true)
        XCTAssertNil(lines.first?["recognition_failed"])
        XCTAssertTrue(fixture.coordinator.unsavedDictations.isEmpty)
    }

    func testQuitDuringRecordingSavesAudioWithoutRecognition() async throws {
        let fixture = try DictationPipelineFixture(text: "not recognized")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        await fixture.engine.holdDecodes()
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        let saved = await result(of: fixture.coordinator.beginTermination())

        XCTAssertEqual(saved, true)
        let decodeStarted = await fixture.engine.isHoldingDecode()
        XCTAssertFalse(decodeStarted, "quit must not start recognition")
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["recognition_skipped"] as? Bool, true)
        try assertAudioExists(for: lines.first, in: fixture.root, extension: "caf")
    }

    func testQuitWhileSavingWaitsForThatSaveAndKeepsText() async throws {
        let fixture = try DictationPipelineFixture(text: "ready text", sourceSeconds: 120)
        defer { fixture.cleanup() }
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while audioFiles(under: fixture.root).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard audioFiles(under: fixture.root).count == 1,
              try historyLines(in: fixture.root).isEmpty else {
            try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
            throw XCTSkip("Saving was not caught in progress — the check proves nothing")
        }

        let saved = await result(of: fixture.coordinator.beginTermination(), within: .seconds(30))

        XCTAssertEqual(saved, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["text"] as? String, "ready text")
        XCTAssertNil(lines.first?["recognition_skipped"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [], "no paste once quit owns the dictation")
    }

    func testQuitDuringDeliveryAfterFailedAppendKeepsTextAndRetriesArchivedCopy() async throws {
        let fixture = try DictationPipelineFixture(text: "keep me")
        defer { fixture.cleanup() }
        let brokenIndex = fixture.root.appendingPathComponent(
            DictationHistoryStore.historyFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        let gate = TestGate()
        fixture.deliveryHook.gate = { await gate.wait() }
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { gate.entered }
        let archived = audioFiles(under: fixture.root)
        XCTAssertEqual(archived.count, 1, "the failed append must leave the archived copy")

        let first = await result(of: fixture.coordinator.beginTermination())

        XCTAssertEqual(first, false, "a failed save is not a reason to quit")
        XCTAssertEqual(fixture.coordinator.quitBlockingIDs.count, 1)
        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["keep me"])
        let lastSource = await fixture.mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        // Quit is refused first, then the held delivery wakes up: the old
        // pipeline stays invalidated and must not add late feedback.
        fixture.coordinator.cancelTermination()
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotEqual(
            fixture.indicator.presentedState,
            .dictationFailure(message: "History not saved — the text is in the “M” menu"),
            "a delivery that quit took over must not flash afterwards"
        )

        let second = await result(of: fixture.coordinator.beginTermination())
        XCTAssertEqual(second, false, "the second quit must not skip the unsaved dictation")
        fixture.coordinator.cancelTermination()

        try FileManager.default.removeItem(at: brokenIndex)
        let third = await result(of: fixture.coordinator.beginTermination())

        XCTAssertEqual(third, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["text"] as? String, "keep me")
        let audioPath = try XCTUnwrap(lines.first?["audio_path"] as? String)
        XCTAssertEqual(
            (audioPath as NSString).lastPathComponent,
            archived.first?.lastPathComponent,
            "the retry must index the copy archived before the append failed"
        )
        XCTAssertEqual(audioFiles(under: fixture.root).count, 1, "no second copy of the audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(fixture.coordinator.quitBlockingIDs.isEmpty)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["keep me"], "the paste begun before quit is not repeated")
    }

    /// The text and the recognized text worked out before a failed save are
    /// the ones the retry writes: a dictionary edited meanwhile is applied
    /// neither to the recognized text nor to the finished one, there is one
    /// line and one audio file, and no second paste.
    func testRetriedSaveKeepsTheReplacedTextAndTheRecognizedOne() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код готов")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        let brokenIndex = fixture.root.appendingPathComponent(
            DictationHistoryStore.historyFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        let gate = TestGate()
        fixture.deliveryHook.gate = { await gate.wait() }
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { gate.entered }

        let first = await result(of: fixture.coordinator.beginTermination())
        XCTAssertEqual(first, false)
        fixture.coordinator.cancelTermination()
        // Recomputing from the recognized text would give "Claude готов",
        // replacing the finished text again "Changed готов".
        try fixture.settings.saveDictionary([
            DictionaryEntry(heard: ["клод код"], written: "Claude"),
            DictionaryEntry(heard: ["Claude Code"], written: "Changed"),
        ])
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.removeItem(at: brokenIndex)
        let second = await result(of: fixture.coordinator.beginTermination())

        XCTAssertEqual(second, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["text"] as? String, "Claude Code готов")
        XCTAssertEqual(lines.first?["raw_text"] as? String, "клод код готов")
        XCTAssertEqual(audioFiles(under: fixture.root).count, 1)
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["Claude Code готов"])
    }

    /// Quit takes the dictation while it is recognized; the late result,
    /// replaced or not, writes and pastes nothing.
    func testLateRecognitionWithADictionaryAfterQuitWritesNothing() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code")])
        await fixture.engine.holdDecodes()
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        fixture.coordinator.toggle()
        try await waitForDictation { await fixture.engine.isHoldingDecode() }

        let saved = await result(of: fixture.coordinator.beginTermination())
        await fixture.engine.releaseHeldDecode()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(saved, true)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["recognition_skipped"] as? Bool, true)
        XCTAssertEqual(lines.first?["text"] as? String, "")
        XCTAssertNil(lines.first?["raw_text"])
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
    }

    func testOnlyRemovingBlockedDictationLetsQuitGoWithoutIt() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        try Data("not a directory".utf8).write(to: fixture.root)
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        let first = await result(of: fixture.coordinator.beginTermination())
        XCTAssertEqual(first, false)
        fixture.coordinator.cancelTermination()
        XCTAssertTrue(fixture.coordinator.hasUnfinishedWork, "idle must not hide the unsaved dictation")
        let second = await result(of: fixture.coordinator.beginTermination())
        XCTAssertEqual(second, false)
        fixture.coordinator.cancelTermination()

        let item = try XCTUnwrap(fixture.coordinator.unsavedDictations.first)
        fixture.coordinator.removeUnsavedDictation(id: item.id)

        XCTAssertFalse(fixture.coordinator.hasUnfinishedWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceAudio.path), "removal keeps the file")
    }

    func testLateStartWithAudioIsKeptOnQuit() async throws {
        let fixture = try DictationPipelineFixture(
            text: "unused",
            makeMic: { GatedStartMic(template: $0) }
        )
        defer { fixture.cleanup() }
        let mic = try XCTUnwrap(fixture.activeMic as? GatedStartMic)
        fixture.coordinator.beginCaptureForTesting()
        XCTAssertEqual(fixture.coordinator.state, .starting)

        let termination = fixture.coordinator.beginTermination()
        await mic.open()
        let saved = await result(of: termination)

        XCTAssertEqual(saved, true)
        XCTAssertEqual(fixture.coordinator.state, .idle)
        let lines = try historyLines(in: fixture.root)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["recognition_skipped"] as? Bool, true)
        try assertAudioExists(for: lines.first, in: fixture.root, extension: "caf")
    }

    func testLateEmptyStartIsDroppedOnQuit() async throws {
        let fixture = try DictationPipelineFixture(
            text: "unused",
            makeMic: { GatedStartMic(template: $0, returnsEmptyFile: true) }
        )
        defer { fixture.cleanup() }
        let mic = try XCTUnwrap(fixture.activeMic as? GatedStartMic)
        fixture.coordinator.beginCaptureForTesting()

        let termination = fixture.coordinator.beginTermination()
        await mic.open()
        let saved = await result(of: termination)

        XCTAssertEqual(saved, true)
        XCTAssertTrue(try historyLines(in: fixture.root).isEmpty)
        let lastSource = await mic.lastSource
        let source = try XCTUnwrap(lastSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "a provably empty file is dropped")
    }

    // MARK: AppDelegate

    func testIdleQuitTerminatesNow() throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testBusyQuitRepliesAfterRecordingIsSaved() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        var finishes: [Bool] = []
        delegate.finishTermination = { finishes.append($0) }
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        // First phase: never wait inside AppKit's terminate, cancel and finish
        // in the normal event loop; a repeated request joins that work.
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        try await waitForDictation { !finishes.isEmpty }

        XCTAssertEqual(finishes, [true])
        XCTAssertEqual(try historyLines(in: fixture.root).count, 1)
        // Second phase: the app's own repeated terminate goes through at once.
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testDeadlineRefusesQuitAndKeepsStartsBlockedUntilWorkEnds() async throws {
        let fixture = try DictationPipelineFixture(
            text: "unused",
            makeMic: { GatedStartMic(template: $0) }
        )
        defer { fixture.cleanup() }
        let mic = try XCTUnwrap(fixture.activeMic as? GatedStartMic)
        let delegate = AppDelegate()
        delegate.terminationDeadline = .milliseconds(300)
        var finishes: [Bool] = []
        delegate.finishTermination = { finishes.append($0) }
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        fixture.coordinator.beginCaptureForTesting()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        try await waitForDictation { !finishes.isEmpty }

        // The stalled start is still held: the answer came from the timer alone.
        XCTAssertEqual(finishes, [false])
        XCTAssertTrue(fixture.coordinator.hasUnfinishedWork)
        fixture.coordinator.beginCaptureForTesting()
        let startsWhileBlocked = await mic.starts
        XCTAssertEqual(startsWhileBlocked, 1, "no new start while quit-time work is running")

        await mic.open()
        try await waitForDictation { !fixture.coordinator.hasUnfinishedWork }
        XCTAssertEqual(try historyLines(in: fixture.root).count, 1, "the late start's audio was kept")
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }
        let startsAfter = await mic.starts
        XCTAssertEqual(startsAfter, 2, "starts are allowed again once the work has ended")
    }

    /// The app opened again while it runs (Finder, Launchpad, the Dock)
    /// shows the main window, Settings on screen or not: Settings open and
    /// the meetings out of sight is the very case. SwiftUI opens nothing of
    /// its own.
    func testReopenShowsTheMainWindowWhateverIsOnScreen() {
        let delegate = AppDelegate()
        var shown = 0
        delegate.showMainWindow = { shown += 1 }

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))

        XCTAssertEqual(shown, 2)
    }

    // MARK: Losses

    /// №4. A meeting transcription is work nothing redoes by itself: the
    /// first quit only warns and leaves it running; quitting again goes ahead.
    func testQuitDuringMeetingTranscriptionWarnsFirstAndQuitsOnRepeat() async throws {
        let transcription = try makeTranscription()
        defer { transcription.cleanup() }
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let meeting = makeMeeting(behavior: .succeed)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        meeting.recorder.transcripts = transcription.queue
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish: no recording runs") }
        delegate.attach(dictation: fixture.coordinator, meeting: meeting.recorder)
        transcription.queue.enqueue(transcription.folder)
        try await waitForDictation(timeout: .seconds(10)) {
            transcription.detecting.isSet && transcription.queue.isTranscribing
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertTrue(transcription.queue.isTranscribing, "the warning must leave the transcription running")
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)

        transcription.queue.cancelCurrent()
        try await waitForDictation(timeout: .seconds(10)) { transcription.queue.lastOutcome != nil }
    }

    /// A finished transcript on its way to the chosen transcripts
    /// folder is a delivery nothing repeats: the launch scan queues the folder
    /// again without it. A quit at that moment — transcription over, queue
    /// empty — must warn; the copy is then made, and quitting again goes ahead.
    func testQuitWhileTheTranscriptIsBeingCopiedWarnsFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try await SavingMeetingCapture(root: root).stop()
        let folder = SavingMeetingCapture.folder(1, in: root)
        let suite = root.appendingPathComponent("settings").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptsFolderPath = target.path
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let meeting = makeMeeting(behavior: .succeed)
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish: no recording runs") }
        delegate.attach(dictation: fixture.coordinator, meeting: meeting.recorder, settings: settings)

        struct AtCopy { let replies: [NSApplication.TerminateReply]; let pill: IndicatorState?
                        let transcribing: Bool; let queued: Int; let copies: Int }
        let seen = Box<AtCopy?>(nil)
        let queue = Box<MeetingTranscriptionQueue?>(nil)
        queue.value = MeetingTranscriptionQueue(
            transcriber: MeetingTranscriber(
                cache: WhisperKitCache(factory: ConstantEngineFactory()),
                loadSpeechDetector: { _ in { _ in [0..<16_000] } },
                currentEngine: { _ in
                    MeetingTranscriber.Engine(
                        descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                        request: .whisper(WhisperDecodeRequest(language: nil)),
                        label: "Whisper"
                    )
                },
                temporaryRoot: root
            ),
            meetingsRoot: root.appendingPathComponent("Meetings", isDirectory: true),
            destinations: {
                // The job asks where to copy once the transcript is written and
                // before the copy: quit, then quit again, right at that moment.
                if let current = queue.value, current.lastOutcome != nil, seen.value == nil {
                    let first = delegate.applicationShouldTerminate(NSApp)
                    let pill = fixture.indicator.presentedState
                    let second = delegate.applicationShouldTerminate(NSApp)
                    seen.value = AtCopy(
                        replies: [first, second], pill: pill,
                        transcribing: current.isTranscribing, queued: current.pending.count,
                        copies: (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.count ?? -1
                    )
                }
                return .init(meetings: nil, transcripts: target)
            }
        )
        let transcripts = try XCTUnwrap(queue.value)
        meeting.recorder.transcripts = transcripts
        defer { queue.value = nil }

        transcripts.enqueue(folder)
        try await waitForDictation(timeout: .seconds(20)) { transcripts.activeJob == nil && seen.value != nil }

        let atCopy = try XCTUnwrap(seen.value, "the job never reached the copy — the check proves nothing")
        XCTAssertFalse(atCopy.transcribing, "the transcription must already be over")
        XCTAssertEqual(atCopy.queued, 0)
        XCTAssertEqual(atCopy.copies, 0, "the copy must not exist yet")
        XCTAssertEqual(atCopy.replies, [.terminateCancel, .terminateNow])
        guard case .meetingFailure(let message)? = atCopy.pill else {
            return XCTFail("no quit warning: \(String(describing: atCopy.pill))")
        }
        XCTAssertTrue(message.contains("transcripts folder"), message)
        let copies = try FileManager.default.contentsOfDirectory(atPath: target.path)
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        XCTAssertEqual(copies.count, 1, "the warned quit must leave the copy to be made")
    }

    func testQuitRouteTable() {
        let cases: [(reason: OSType?, signalled: Bool, expected: AppDelegate.QuitRoute)] = [
            (nil, false, .user),
            (OSType(kAELogOut), false, .system),
            (OSType(kAEReallyLogOut), false, .system),
            (OSType(kAEShowRestartDialog), false, .system),
            (OSType(kAERestart), false, .system),
            (OSType(kAEShowShutdownDialog), false, .system),
            (OSType(kAEShutDown), false, .system),
            (OSType(0x7175_6961), false, .user),
            (nil, true, .signal),
            (OSType(kAELogOut), true, .signal),
        ]
        for item in cases {
            XCTAssertEqual(
                AppDelegate.route(quitReason: item.reason, signalled: item.signalled),
                item.expected,
                "\(item)"
            )
        }
    }

    /// Logout, restart, shutdown and SIGTERM never wait for a person: they
    /// quit through losses without a warning.
    func testSystemQuitAndSignalGoAheadWithoutWarning() throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        delegate.fileLosses = { [.unsavedFileText] }

        delegate.quitReason = { OSType(kAELogOut) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        delegate.quitReason = { nil }
        delegate.signalled = true
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertNil(fixture.indicator.presentedState, "no warning for a quit nobody can answer")

        // The signal is read once: the next quit is a person's again.
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
    }

    /// The warning names what is lost; a repeat within the window goes ahead,
    /// a late one is warned again.
    func testWarnedQuitGoesAheadOnlyWhenRepeatedSoon() throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        delegate.fileLosses = { [.fileTranscription] }
        let now = Box(ContinuousClock.now)
        delegate.now = { now.value }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .meetingFailure(message: "A file is being transcribed in Files — quit again to stop it")
        )
        now.value = now.value.advanced(by: .seconds(11))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "consent must expire")
        now.value = now.value.advanced(by: .seconds(9))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    /// A loss that appears after the warning was not agreed to.
    func testNewLossAfterWarningIsWarnedAgain() throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        let losses = Box<Set<AppDelegate.QuitLoss>>([.fileTranscription])
        delegate.fileLosses = { losses.value }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        losses.value = [.unsavedFileText]
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .meetingFailure(message: "Files has unsaved text — save it as .md, or quit again to discard it")
        )
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    /// The warning leaves a running dictation alone; the confirmed quit then
    /// finishes it the usual two-phase way, and the app's own second quit is
    /// not warned again.
    func testWarningLeavesDictationRunningAndRepeatFinishesItInTwoPhases() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let delegate = AppDelegate()
        var finishes: [Bool] = []
        delegate.finishTermination = { finishes.append($0) }
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        delegate.fileLosses = { [.fileTranscription] }
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(fixture.coordinator.state, .recording, "the warning must not stop the dictation")
        XCTAssertTrue(finishes.isEmpty)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        try await waitForDictation { !finishes.isEmpty }
        XCTAssertEqual(finishes, [true])
        XCTAssertEqual(try historyLines(in: fixture.root).count, 1)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    /// A recording to be transcribed after it stops is saved by quit but
    /// never queued: warned. With nothing to do after the stop, no warning.
    func testRecordingThatWouldBeTranscribedIsWarnedOnlyWhenTranscriptionIsOn() async throws {
        let name = "io.github.spacevibes365.MurmurlyTests.QuitAfterStop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let meeting = makeMeeting(behavior: .succeed)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        let delegate = AppDelegate()
        var finishes: [Bool] = []
        delegate.finishTermination = { finishes.append($0) }
        delegate.attach(dictation: fixture.coordinator, meeting: meeting.recorder, settings: settings)
        meeting.recorder.toggle()
        try await waitForDictation { meeting.recorder.state == .recording }

        settings.meetingAfterStop = .transcribe
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(meeting.recorder.state, .recording)
        XCTAssertTrue(finishes.isEmpty)

        settings.meetingAfterStop = .nothing
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "two-phase stop")
        try await waitForDictation { !finishes.isEmpty }
        XCTAssertEqual(finishes, [true])
    }

    /// №4, Files as the app wires it: the real model's run, held at a gate,
    /// warns the first quit and goes on; once it ends, its unsaved result is a
    /// new loss and warns again; saved, it lets the quit through.
    func testFilesRunThenItsUnsavedTextWarnAndTheSavedTextQuits() async throws {
        let fixture = try DictationPipelineFixture(text: "unused")
        defer { fixture.cleanup() }
        let gate = TestGate()
        // The fixture's own folder; its Dictations root is made only on demand.
        let target = fixture.parent.appendingPathComponent("talk.md")
        let files = FilesModel(
            transcription: { _ in { _, _ in
                await gate.wait()
                return [TranscriptSegment(speaker: "", text: "text")]
            } },
            saveDestination: { _, _ in target }
        )
        let delegate = AppDelegate()
        delegate.finishTermination = { _ in XCTFail("nothing to finish: no recording runs") }
        delegate.attach(dictation: fixture.coordinator, meeting: makeMeeting(behavior: .succeed).recorder)
        delegate.fileLosses = { files.quitLosses }
        files.select(fixture.parent.appendingPathComponent("talk.wav"))
        files.start()
        try await waitForDictation { gate.entered }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .meetingFailure(message: AppDelegate.QuitLoss.fileTranscription.warning)
        )
        XCTAssertTrue(files.isTranscribing, "the warning must leave the run going")

        gate.open()
        try await waitForDictation { !files.isTranscribing }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel, "the text exists only here now")
        XCTAssertEqual(
            fixture.indicator.presentedState,
            .meetingFailure(message: AppDelegate.QuitLoss.unsavedFileText.warning)
        )

        let saved = await files.saveTranscript(owner: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testSeveralLossesAreListedInOneLine() {
        XCTAssertEqual(
            AppDelegate.warning(for: [.meetingTranscription]),
            "A meeting is being transcribed — quit again to stop it. Transcribe it later with Transcribe Meeting…"
        )
        let several = AppDelegate.warning(for: [.unsavedFileText, .meetingTranscription])
        XCTAssertTrue(several.hasPrefix("Quitting now loses: meeting transcription"), several)
        XCTAssertTrue(several.contains("unsaved Files text"), several)
        XCTAssertFalse(several.contains("\n"))
    }

    // MARK: Meeting

    func testMeetingQuitStopsAndConfirmsSave() async throws {
        let meeting = makeMeeting(behavior: .succeed)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        meeting.recorder.toggle()
        try await waitForDictation { meeting.recorder.state == .recording }

        let saved = await result(of: meeting.recorder.beginTermination())

        XCTAssertEqual(saved, true)
        let stops = await meeting.capture.stops
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(meeting.recorder.state, .idle)
    }

    func testMeetingFailedStopWithReadableMetadataCountsAsSaved() async throws {
        let meeting = makeMeeting(behavior: .failWithMetadata)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        meeting.recorder.toggle()
        try await waitForDictation { meeting.recorder.state == .recording }

        let saved = await result(of: meeting.recorder.beginTermination())

        XCTAssertEqual(saved, true)
        XCTAssertNil(meeting.recorder.unconfirmedRecording)
    }

    func testMeetingIntermediateMetadataIsNotProofOfSave() async throws {
        let meeting = makeMeeting(behavior: .failWithIntermediateMetadata)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        meeting.recorder.toggle()
        try await waitForDictation { meeting.recorder.state == .recording }

        let saved = await result(of: meeting.recorder.beginTermination())

        XCTAssertEqual(saved, false, "metadata with state \"recording\" is not a finished save")
        XCTAssertEqual(meeting.recorder.unconfirmedRecording?.directory, meeting.directory)
    }

    func testMeetingStopWithoutEvidenceBlocksQuitUntilReleased() async throws {
        let meeting = makeMeeting(behavior: .failWithoutEvidence)
        defer { try? FileManager.default.removeItem(at: meeting.directory) }
        meeting.recorder.toggle()
        try await waitForDictation { meeting.recorder.state == .recording }

        let first = await result(of: meeting.recorder.beginTermination())
        XCTAssertEqual(first, false)
        XCTAssertNotNil(meeting.recorder.unconfirmedRecording)
        meeting.recorder.cancelTermination()
        XCTAssertTrue(meeting.recorder.hasUnfinishedWork, "failed must not hide the unconfirmed recording")
        let second = await result(of: meeting.recorder.beginTermination())
        XCTAssertEqual(second, false)
        meeting.recorder.cancelTermination()

        meeting.recorder.releaseUnconfirmedRecording()

        XCTAssertFalse(meeting.recorder.hasUnfinishedWork)
    }

    // MARK: Helpers

    private func makeMeeting(
        behavior: FakeQuitMeetingCapture.StopBehavior
    ) -> (recorder: MeetingRecorder, capture: FakeQuitMeetingCapture, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-meeting-\(UUID().uuidString)", isDirectory: true)
        let capture = FakeQuitMeetingCapture(directory: directory, behavior: behavior)
        let recorder = MeetingRecorder(
            capture: capture,
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { [] },
            beepPlayer: {}
        )
        return (recorder, capture, directory)
    }

    /// A meeting folder whose transcription stays in speech detection until
    /// cancelled, so a quit is sure to find it running.
    private func makeTranscription() throws -> (
        queue: MeetingTranscriptionQueue, folder: URL, detecting: QuitFlag, cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-transcription-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("2026-10-09 10-00-00 Meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["microphone.caf", "system.caf"] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<96_000 { channel[frame] = frame > 24_000 && frame < 72_000 ? 0.1 : 0 }
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
        let detecting = QuitFlag()
        let transcriber = MeetingTranscriber(
            cache: WhisperKitCache(factory: NoQuitWhisperFactory()),
            loadSpeechDetector: { _ in
                { _ in
                    detecting.set()
                    while true {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            },
            currentEngine: { _ in
                MeetingTranscriber.Engine(
                    descriptor: EngineDescriptor(engine: .whisper, modelPath: "/models/whisper"),
                    request: .whisper(WhisperDecodeRequest(language: nil)),
                    label: "Whisper"
                )
            },
            temporaryRoot: root
        )
        let queue = MeetingTranscriptionQueue(
            transcriber: transcriber,
            meetingsRoot: root.appendingPathComponent("Meetings", isDirectory: true)
        )
        return (queue, folder, detecting, { try? FileManager.default.removeItem(at: root) })
    }

    private func historyLines(in root: URL) throws -> [[String: Any]] {
        let url = root.appendingPathComponent(DictationHistoryStore.historyFileName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return [] }
        return try Data(contentsOf: url)
            .split(separator: DictationHistoryStore.newline)
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    private func audioFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { ["m4a", "caf"].contains($0.pathExtension.lowercased()) }
    }

    private func assertAudioExists(
        for line: [String: Any]?,
        in root: URL,
        extension expected: String,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) throws {
        let audioPath = try XCTUnwrap(line?["audio_path"] as? String, file: file, line: lineNumber)
        XCTAssertEqual((audioPath as NSString).pathExtension, expected, file: file, line: lineNumber)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(audioPath).path),
            "archived audio is missing",
            file: file,
            line: lineNumber
        )
    }
}
