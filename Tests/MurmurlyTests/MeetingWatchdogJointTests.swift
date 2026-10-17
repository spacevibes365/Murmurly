import Foundation
import XCTest
@testable import Murmurly

/// A capture whose first start can fail and whose stop can be held, so a test
/// can place a snapshot change inside the save. Every stop writes its own
/// folder, so the trigger recorded there names the call that was recorded.
private actor JointCapture: MeetingCaptureBackend {
    struct StartFailure: LocalizedError {
        var errorDescription: String? { "test start failure" }
    }

    private let root: URL
    private var failsNextStart: Bool
    /// Starts still to fail because the microphone is not ready yet.
    private var notReadyStarts: Int
    private var holdsStop = false
    private var holdsStart = false
    private(set) var startWasCancelled = false
    private(set) var starts = 0
    private(set) var stops = 0

    init(root: URL, failsFirstStart: Bool, notReadyStarts: Int = 0) {
        self.root = root
        failsNextStart = failsFirstStart
        self.notReadyStarts = notReadyStarts
    }

    func start(in _: URL) async throws -> Date {
        starts += 1
        for _ in 0..<1_000 where holdsStart { try? await Task.sleep(for: .milliseconds(10)) }
        startWasCancelled = Task.isCancelled
        if notReadyStarts > 0 {
            notReadyStarts -= 1
            throw SystemAudioCaptureError.microphoneNotReady
        }
        if failsNextStart {
            failsNextStart = false
            throw StartFailure()
        }
        return Date()
    }

    func holdStop() { holdsStop = true }
    func releaseStop() { holdsStop = false }
    func holdStart() { holdsStart = true }
    func releaseStart() { holdsStart = false }

    func stop() async throws -> [URL] {
        stops += 1
        // Bounded: a test that never releases the hold still finishes.
        for _ in 0..<1_000 where holdsStop { try? await Task.sleep(for: .milliseconds(10)) }
        holdsStop = false
        let folder = root.appendingPathComponent("recording-\(stops)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = MeetingMetadata(
            startedAt: "2026-10-05T10:00:00Z",
            endedAt: "2026-10-05T10:01:00Z",
            sampleRate: 48_000,
            state: "done",
            segments: []
        )
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        try Data("captured samples".utf8).write(to: folder.appendingPathComponent("system.caf"))
        return [folder.appendingPathComponent("system.caf")]
    }
}

private actor IdleMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

@MainActor
private final class SnapshotBox {
    var value: [MeetingWatchdog.ProcessSnapshot]?
    init(_ value: [MeetingWatchdog.ProcessSnapshot]?) { self.value = value }
}

/// The real recorder with its real watchdog, isolated settings and a temporary
/// folder for the fake capture.
@MainActor
private final class JointFixture {
    let snapshots: SnapshotBox
    let capture: JointCapture
    let recorder: MeetingRecorder
    let indicator = RecordingIndicator(renderingEnabled: false)
    let dictation: DictationCoordinator
    let settings: SettingsStore
    private let root: URL
    private let suiteName: String
    private let defaults: UserDefaults

    init(
        snapshot: [MeetingWatchdog.ProcessSnapshot]?, failsFirstStart: Bool = false, notReadyStarts: Int = 0
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-joint-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "io.github.spacevibes365.MurmurlyTests.WatchdogJoint.\(UUID().uuidString)"
        let snapshots = SnapshotBox(snapshot)
        let capture = JointCapture(root: root, failsFirstStart: failsFirstStart, notReadyStarts: notReadyStarts)
        self.root = root
        self.suiteName = suiteName
        self.snapshots = snapshots
        self.capture = capture
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = SettingsStore(defaults: defaults)
        recorder = MeetingRecorder(
            capture: capture,
            indicator: indicator,
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero,
            watchdogSnapshotSource: { snapshots.value },
            beepPlayer: {}
        )
        dictation = DictationCoordinator(
            mic: IdleMic(),
            indicator: RecordingIndicator(renderingEnabled: false)
        )
    }

    /// Runs the watchdog's initial tick without its periodic timer: from here
    /// on only the test's explicit ticks run.
    func activate() {
        MeetingWatchdog.periodicTicksDisabledForTesting = true
        defer { MeetingWatchdog.periodicTicksDisabledForTesting = false }
        recorder.activate(
            settings: settings,
            permissions: PermissionManager(),
            dictation: dictation
        )
    }

    func tick(_ now: Date = Date()) { recorder.tickWatchdogForTesting(now: now) }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Bans and the time limit through the real recorder and watchdog. Only the initial tick and
/// the explicit ticks below run, so the order of events is set by the test and
/// never by how fast it is. A start is synchronous up to `.starting`, so the
/// state right after a tick shows whether the watchdog started.
@MainActor
final class MeetingWatchdogJointTests: XCTestCase {
    private typealias Snapshot = MeetingWatchdog.ProcessSnapshot
    /// A has the lower PID: when both are free the watchdog picks A, so a
    /// recording triggered by B proves A is banned.
    private let callA = Snapshot(pid: 42, bundleID: "company.call", isRunningInput: true)
    private let callB = Snapshot(pid: 77, bundleID: "company.second", isRunningInput: true)
    private let pastLimit = MeetingWatchdog.maximumAutomaticDuration + 1

    func testDisabledAutomaticRecordingDoesNotStartAtActivation() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.settings.autoRecordMeetings = false
        fixture.activate()
        XCTAssertEqual(fixture.recorder.state, .idle)
        // Also drain an incorrect start on the parent commit.
        if fixture.recorder.isBusy {
            try await wait(fixture, for: .recording)
            try await finish(fixture)
        }
    }

    func testConfiguredExclusionDoesNotStartAtActivation() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.settings.meetingExcludedBundleIDs = ["company.call"]
        fixture.activate()
        XCTAssertEqual(fixture.recorder.state, .idle)
        if fixture.recorder.isBusy {
            try await wait(fixture, for: .recording)
            try await finish(fixture)
        }
    }

    func testDisablingDuringStartSavesLateSuccessWithoutCancellingCapture() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        await fixture.capture.holdStart()
        fixture.activate()
        try await waitUntilAsync("capture.start was not called") { await fixture.capture.starts == 1 }
        fixture.settings.autoRecordMeetings = false
        // Re-enabling must not erase the stop the user already requested.
        fixture.settings.autoRecordMeetings = true
        await fixture.capture.releaseStart()
        try await wait(fixture, for: .idle)
        let cancelled = await fixture.capture.startWasCancelled
        let stops = await fixture.capture.stops
        XCTAssertFalse(cancelled)
        XCTAssertEqual(stops, 1)
        try assertSavedAudio(fixture)
        fixture.tick()
        XCTAssertEqual(fixture.recorder.state, .idle, "the stopped holder was restarted")
    }

    func testDisablingActiveAutomaticRecordingSavesEvenWithoutSnapshot() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)
        fixture.snapshots.value = nil
        fixture.settings.autoRecordMeetings = false
        try await wait(fixture, for: .idle)
        try assertSavedAudio(fixture)
        fixture.snapshots.value = [callB]
        fixture.tick()
        XCTAssertEqual(fixture.recorder.state, .idle)
    }

    func testExclusionDuringStartSavesLateSuccess() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        await fixture.capture.holdStart()
        fixture.activate()
        try await waitUntilAsync("capture.start was not called") { await fixture.capture.starts == 1 }
        fixture.settings.meetingExcludedBundleIDs.insert("company.call")
        await fixture.capture.releaseStart()
        try await wait(fixture, for: .idle)
        let cancelled = await fixture.capture.startWasCancelled
        XCTAssertFalse(cancelled)
        try assertSavedAudio(fixture)
    }

    func testManualRecordingAndHotkeySurviveAutomaticOff() async throws {
        let fixture = try JointFixture(snapshot: [])
        defer { fixture.cleanUp() }
        fixture.activate()
        fixture.recorder.toggle()
        try await wait(fixture, for: .recording)
        fixture.settings.autoRecordMeetings = false
        fixture.tick(Date().addingTimeInterval(pastLimit))
        XCTAssertEqual(fixture.recorder.state, .recording)
        try await finish(fixture)
        fixture.recorder.toggle()
        try await wait(fixture, for: .recording)
        try await finish(fixture)
        try assertSavedAudio(fixture)
    }

    func testExclusionStopsOnlyAfterLastEligibleHolderIsExcluded() async throws {
        let fixture = try JointFixture(snapshot: [callA, callB])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)
        fixture.settings.meetingExcludedBundleIDs.insert("company.call")
        XCTAssertEqual(fixture.recorder.state, .recording)
        fixture.tick(Date().addingTimeInterval(MeetingWatchdog.stopHysteresis + 1))
        XCTAssertEqual(fixture.recorder.state, .recording)
        fixture.settings.meetingExcludedBundleIDs.insert("company.second")
        try await wait(fixture, for: .idle)
        try assertSavedAudio(fixture)
    }

    func testReleaseWhileAutomaticOffLiftsTheStoppedHoldersBan() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)
        fixture.settings.autoRecordMeetings = false
        try await wait(fixture, for: .idle)
        fixture.snapshots.value = []
        fixture.tick()
        fixture.snapshots.value = [callA]
        fixture.settings.autoRecordMeetings = true
        fixture.tick()
        try await assertRecording(of: fixture, triggeredBy: "company.call")
    }

    // MARK: System Settings is not a call

    /// Sound → Input holds the microphone for its level meter; the pane runs as
    /// its own extension process (seen live on macOS 26). Its lower PID would
    /// also make it the trigger next to a real call.
    private let soundSettings = Snapshot(
        pid: 30, bundleID: "com.apple.Sound-Settings.extension", isRunningInput: true
    )

    func testCheckingTheMicrophoneInSystemSettingsStartsNothing() async throws {
        let fixture = try JointFixture(snapshot: [soundSettings])
        defer { fixture.cleanUp() }
        fixture.activate()
        fixture.tick()
        XCTAssertEqual(fixture.recorder.state, .idle, "System Settings started an automatic recording")
        if fixture.recorder.isBusy {
            try await wait(fixture, for: .recording)
            try await finish(fixture)
        }
    }

    func testCallNextToSystemSettingsIsRecordedAsTheCall() async throws {
        let zoom = Snapshot(pid: 77, bundleID: "us.zoom.xos", isRunningInput: true)
        let fixture = try JointFixture(snapshot: [soundSettings, zoom])
        defer { fixture.cleanUp() }
        fixture.activate()
        guard assertStarted(fixture, "a call next to System Settings was not recorded") else { return }
        XCTAssertEqual(fixture.recorder.automaticRecordingBundleID, "us.zoom.xos")
        try await assertRecording(of: fixture, triggeredBy: "us.zoom.xos")
    }

    func testSystemSettingsDoesNotKeepAnAutomaticRecordingGoing() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)
        // The call ends while Sound → Input stays open.
        fixture.snapshots.value = [soundSettings]
        let now = Date()
        fixture.tick(now)
        fixture.tick(now.addingTimeInterval(MeetingWatchdog.stopHysteresis))
        try await wait(fixture, for: .idle)
        try assertSavedAudio(fixture)
    }

    private func assertSavedAudio(_ fixture: JointFixture) throws {
        let folder = try XCTUnwrap(fixture.recorder.lastRecordingDirectory)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("system.caf")), Data("captured samples".utf8))
        let metadata = try JSONDecoder().decode(
            MeetingMetadata.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.state, "done")
    }

    // MARK: A failed automatic start owns nothing after it

    func testManualRecordingAfterFailedAutomaticStartIsNotStoppedBySilence() async throws {
        let fixture = try JointFixture(snapshot: [callA], failsFirstStart: true)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)

        fixture.recorder.toggle()
        try await wait(fixture, for: .recording)
        fixture.snapshots.value = []
        let now = Date()
        fixture.tick(now)
        fixture.tick(now.addingTimeInterval(MeetingWatchdog.stopHysteresis))
        XCTAssertEqual(fixture.recorder.state, .recording, "a failed automatic attempt stopped the manual recording")
        let stops = await fixture.capture.stops
        XCTAssertEqual(stops, 0)
        try await finish(fixture)
    }

    func testCallThatAppearsAfterFailedAutomaticStartGetsItsOwnAttempt() async throws {
        let fixture = try JointFixture(snapshot: [callA], failsFirstStart: true)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)

        fixture.snapshots.value = [callA, callB]
        fixture.tick()
        guard assertStarted(fixture, "B was banned together with the failed attempt of A") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.second")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 2)
    }

    func testFailedHolderIsNotRetriedWhileItHoldsTheMicrophone() async throws {
        let fixture = try JointFixture(snapshot: [callA], failsFirstStart: true)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)

        let now = Date()
        for offset in [0.0, 2, 4] { fixture.tick(now.addingTimeInterval(offset)) }
        XCTAssertTrue(isFailed(fixture.recorder.state), "the failed holder was restarted")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 1)
    }

    /// Seen in a live run: the automatic start failed because the
    /// microphone was not ready yet, and the ban that followed left the whole
    /// call unrecorded. Such a failure is tried again at the next tick.
    func testHolderIsRetriedAfterTheMicrophoneWasNotReady() async throws {
        let fixture = try JointFixture(snapshot: [callA], notReadyStarts: 1)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)

        fixture.tick()
        guard assertStarted(fixture, "the call was banned after a microphone that was not ready yet") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.call")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 2)
    }

    /// The retry is one: a microphone still not ready bans the holder like any
    /// failure, so a broken device is not tried every two seconds of a call.
    func testMicrophoneStillNotReadyAfterTheRetryBansTheHolder() async throws {
        let fixture = try JointFixture(snapshot: [callA], notReadyStarts: 2)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)
        fixture.tick()
        guard assertStarted(fixture, "the call was banned after a microphone that was not ready yet") else { return }
        try await waitUntil("the retry did not fail") { self.isFailed(fixture.recorder.state) }

        let now = Date()
        for offset in [0.0, 2, 4] { fixture.tick(now.addingTimeInterval(offset)) }
        XCTAssertTrue(isFailed(fixture.recorder.state), "the holder was tried again after its retry")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 2)
    }

    /// Automatic recording turned off and on while the start
    /// waits stops that call, and the stop outranks the retry a microphone not
    /// ready yet would earn: the call is not recorded again.
    func testStopOrderedDuringStartOutranksTheNotReadyRetry() async throws {
        let fixture = try JointFixture(snapshot: [callA], notReadyStarts: 1)
        defer { fixture.cleanUp() }
        await fixture.capture.holdStart()
        fixture.activate()
        try await waitUntilAsync("capture.start was not called") { await fixture.capture.starts == 1 }
        fixture.settings.autoRecordMeetings = false
        fixture.settings.autoRecordMeetings = true
        await fixture.capture.releaseStart()
        try await waitUntil("the start did not fail") { self.isFailed(fixture.recorder.state) }

        let now = Date()
        for offset in [0.0, 2, 4] { fixture.tick(now.addingTimeInterval(offset)) }
        XCTAssertTrue(isFailed(fixture.recorder.state), "the call stopped during its start was recorded again")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 1)
    }

    /// The same stop ordered by excluding the call's app during the start and
    /// letting it back in.
    func testStopByExclusionDuringStartOutranksTheNotReadyRetry() async throws {
        let fixture = try JointFixture(snapshot: [callA], notReadyStarts: 1)
        defer { fixture.cleanUp() }
        await fixture.capture.holdStart()
        fixture.activate()
        try await waitUntilAsync("capture.start was not called") { await fixture.capture.starts == 1 }
        fixture.settings.meetingExcludedBundleIDs.insert("company.call")
        fixture.settings.meetingExcludedBundleIDs.remove("company.call")
        await fixture.capture.releaseStart()
        try await waitUntil("the start did not fail") { self.isFailed(fixture.recorder.state) }

        let now = Date()
        for offset in [0.0, 2, 4] { fixture.tick(now.addingTimeInterval(offset)) }
        XCTAssertTrue(isFailed(fixture.recorder.state), "the call stopped during its start was recorded again")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 1)
    }

    /// The one retry belongs to each holder. A, already retried,
    /// fails again together with a new call B: A is banned, B keeps its own
    /// try, and the next attempt records B.
    func testNotReadyRetryIsCountedForEachHolder() async throws {
        let fixture = try JointFixture(snapshot: [callA], notReadyStarts: 2)
        defer { fixture.cleanUp() }
        fixture.activate()
        try await waitForFailedStart(fixture)
        fixture.snapshots.value = [callA, callB]
        fixture.tick()
        guard assertStarted(fixture, "A lost its retry") else { return }
        try await waitUntil("the retry did not fail") { self.isFailed(fixture.recorder.state) }

        fixture.tick()
        guard assertStarted(fixture, "B lost its own try") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.second")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 3)
    }

    func testStartDeclinedForBusyDictationIsRetriedAfterIt() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.dictation.beginCaptureForTesting()
        try await waitUntil("dictation did not start") { fixture.dictation.state == .recording }
        fixture.activate()
        XCTAssertEqual(fixture.recorder.state, .idle)

        fixture.dictation.toggle()
        try await waitUntil("dictation did not finish") { fixture.dictation.state == .idle }
        fixture.tick()
        guard assertStarted(fixture, "a refusal because of dictation left a ban") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.call")
    }

    // MARK: A stop bans the call it stops, not the next one

    func testCallThatReplacesStoppedOneBeforeNextTickIsRecorded() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)

        fixture.recorder.toggle()
        try await wait(fixture, for: .idle)
        fixture.snapshots.value = [callB]
        fixture.tick()
        guard assertStarted(fixture, "B was banned together with the stopped A") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.second")
    }

    func testCallThatStartsDuringSaveIsRecorded() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        let capture = fixture.capture
        defer { fixture.cleanUp() }
        defer { Task { await capture.releaseStop() } }
        fixture.activate()
        try await wait(fixture, for: .recording)

        await capture.holdStop()
        fixture.recorder.toggle()
        XCTAssertEqual(fixture.recorder.state, .stopping)
        try await waitUntilAsync("saving did not start") { await capture.stops == 1 }
        fixture.snapshots.value = [callA, callB]
        XCTAssertEqual(fixture.recorder.state, .stopping, "B did not appear during saving")
        await capture.releaseStop()
        try await wait(fixture, for: .idle)

        fixture.tick()
        guard assertStarted(fixture, "B, started during saving, was banned") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.second")
    }

    func testStopWithoutSnapshotBansOnlyTheSessionsHolders() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)
        fixture.tick()

        fixture.snapshots.value = nil
        fixture.recorder.toggle()
        try await wait(fixture, for: .idle)
        fixture.snapshots.value = [callA, callB]
        fixture.tick()
        guard assertStarted(fixture, "B was banned although the stop had no snapshot") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.second")
    }

    func testReleasingTheMicrophoneLiftsTheBanFromAStopWithoutSnapshot() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)

        fixture.snapshots.value = nil
        fixture.recorder.toggle()
        try await wait(fixture, for: .idle)
        fixture.snapshots.value = [callA]
        fixture.tick()
        XCTAssertEqual(fixture.recorder.state, .idle, "A was restarted while it holds the microphone")
        fixture.snapshots.value = []
        fixture.tick()
        fixture.snapshots.value = [callA]
        fixture.tick()
        guard assertStarted(fixture, "releasing the microphone did not lift the ban on A") else { return }
        try await assertRecording(of: fixture, triggeredBy: "company.call")
    }

    func testManualStopWhileHolderStaysDoesNotRestart() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        try await wait(fixture, for: .recording)

        fixture.recorder.toggle()
        try await wait(fixture, for: .idle)
        fixture.tick()
        fixture.tick()
        XCTAssertEqual(fixture.recorder.state, .idle, "the stopped meeting was restarted")
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 1)
    }

    // MARK: The automatic limit does not wait for a snapshot

    func testAutomaticRecordingStopsAtTheLimitWithoutSnapshot() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        let activatedAt = Date()
        try await wait(fixture, for: .recording)

        fixture.snapshots.value = nil
        fixture.tick(activatedAt.addingTimeInterval(pastLimit))
        XCTAssertEqual(fixture.recorder.state, .stopping, "automatic recording runs past the limit")
        try await finish(fixture)
        let stops = await fixture.capture.stops
        XCTAssertEqual(stops, 1)
    }

    /// №7: the stop at the limit is told apart from an ordinary one, in the
    /// recording's warning and on the indicator, while `metadata.json` keeps
    /// describing only the tracks.
    func testRecordingStoppedAtTheLimitSaysSoOnlyInMemory() async throws {
        let fixture = try JointFixture(snapshot: [callA])
        defer { fixture.cleanUp() }
        fixture.activate()
        let activatedAt = Date()
        try await wait(fixture, for: .recording)

        fixture.tick(activatedAt.addingTimeInterval(pastLimit))
        try await wait(fixture, for: .idle)
        try assertSavedAudio(fixture)
        let folder = try XCTUnwrap(fixture.recorder.lastRecordingDirectory)
        let warning = try XCTUnwrap(fixture.recorder.recordingWarning, "the stop at the limit was not explained")
        XCTAssertEqual(warning.directory, folder)
        XCTAssertTrue(warning.issues.contains { $0.contains("4-hour limit") }, "\(warning.issues)")
        XCTAssertEqual(fixture.indicator.presentedState, .meetingSavedSuspect)
        let written = try String(decoding: Data(contentsOf: folder.appendingPathComponent("metadata.json")), as: UTF8.self)
        XCTAssertFalse(written.contains("limit"), "the limit is not a fact about the tracks: \(written)")
    }

    func testManualRecordingIsNotLimitedWithoutSnapshot() async throws {
        let fixture = try JointFixture(snapshot: nil)
        defer { fixture.cleanUp() }
        fixture.activate()
        let activatedAt = Date()
        fixture.recorder.toggle()
        try await wait(fixture, for: .recording)

        fixture.tick(activatedAt.addingTimeInterval(pastLimit))
        XCTAssertEqual(fixture.recorder.state, .recording, "the automatic recording limit stopped a manual recording")
        let stops = await fixture.capture.stops
        XCTAssertEqual(stops, 0)
        try await finish(fixture)
    }

    // MARK: Helpers

    private func isFailed(_ state: MeetingRecorder.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func waitUntil(_ message: String, _ done: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), message)
    }

    private func waitUntilAsync(
        _ message: String, _ done: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    private func wait(_ fixture: JointFixture, for state: MeetingRecorder.State) async throws {
        try await waitUntil("recording did not reach \(state)") { fixture.recorder.state == state }
    }

    private func waitForFailedStart(_ fixture: JointFixture) async throws {
        try await waitUntil("the automatic start did not fail") { self.isFailed(fixture.recorder.state) }
        let starts = await fixture.capture.starts
        XCTAssertEqual(starts, 1)
    }

    /// True when the tick just made the recorder start.
    private func assertStarted(_ fixture: JointFixture, _ message: String) -> Bool {
        XCTAssertEqual(fixture.recorder.state, .starting, message)
        return fixture.recorder.state == .starting
    }

    /// Lets the started recording run, stops it and reads which call the saved
    /// folder says triggered it.
    private func assertRecording(
        of fixture: JointFixture, triggeredBy trigger: String
    ) async throws {
        try await wait(fixture, for: .recording)
        fixture.recorder.toggle()
        try await wait(fixture, for: .idle)
        let directory = try XCTUnwrap(fixture.recorder.lastRecordingDirectory)
        let metadata = try JSONDecoder().decode(
            MeetingMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.trigger, trigger)
    }

    private func finish(_ fixture: JointFixture) async throws {
        if fixture.recorder.state == .recording { fixture.recorder.toggle() }
        try await waitUntil("recording did not finish") { !fixture.recorder.isBusy }
    }
}
