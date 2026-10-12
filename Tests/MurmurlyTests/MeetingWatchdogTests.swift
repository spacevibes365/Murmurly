import Foundation
import XCTest
@testable import Murmurly

/// A watchdog driven by hand: the snapshot and the recorder state are plain
/// values, a start moves the recorder to `.starting` the way the real one does.
@MainActor
private final class WatchdogHarness {
    var snapshot: [MeetingWatchdog.ProcessSnapshot]?
    var recorder: MeetingRecorder.State = .idle
    private(set) var snapshotReads = 0
    private(set) var starts: [String] = []
    private(set) var stops = 0
    private(set) var watchdog: MeetingWatchdog!

    init() {
        watchdog = MeetingWatchdog(
            snapshotSource: { [unowned self] in
                self.snapshotReads += 1
                return self.snapshot
            },
            recorderState: { [unowned self] in self.recorder },
            requestStart: { [unowned self] trigger in
                self.starts.append(trigger)
                self.recorder = .starting
                return true
            },
            requestStop: { [unowned self] in self.stops += 1 },
            ownPID: 1
        )
    }
}

@MainActor
final class MeetingWatchdogTests: XCTestCase {
    typealias Snapshot = MeetingWatchdog.ProcessSnapshot
    typealias LogicState = MeetingWatchdog.LogicState
    typealias Decision = MeetingWatchdog.Decision

    private let foreign = Snapshot(pid: 42, bundleID: "company.call", isRunningInput: true)
    private let seen = Snapshot(pid: 60, bundleID: "company.seen", isRunningInput: true)
    private let second = Snapshot(pid: 77, bundleID: "company.second", isRunningInput: true)
    private let blocked = Snapshot(pid: 90, bundleID: "company.blocked", isRunningInput: true)

    func testDecisionTable() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ownPID: pid_t = 1
        struct Step {
            let snapshot: [Snapshot]
            let recorder: MeetingRecorder.State
            let offset: TimeInterval
            let expected: Decision
        }
        typealias Case = (name: String, initial: LogicState, steps: [Step], final: LogicState)
        func step(
            _ snapshot: [Snapshot], _ recorder: MeetingRecorder.State = .idle,
            _ offset: TimeInterval = 0, _ expected: Decision = .none
        ) -> Step {
            Step(snapshot: snapshot, recorder: recorder, offset: offset, expected: expected)
        }
        func automatic(
            started: TimeInterval = 0, silent: TimeInterval? = nil,
            blocked: Set<pid_t> = [], attempt: Set<pid_t> = [42], session: Set<pid_t> = []
        ) -> LogicState {
            LogicState(
                blockedPIDs: blocked,
                automaticStartedAt: base.addingTimeInterval(started),
                silentSince: silent.map(base.addingTimeInterval),
                attemptHolders: attempt,
                sessionHolders: session
            )
        }

        let empty = LogicState()
        let autoState = automatic()
        let cases: [Case] = [
            ("foreign holder starts", empty,
             [step([foreign], .idle, 0, .start(pid: 42, trigger: "company.call"))], autoState),
            ("every free holder belongs to the attempt", empty,
             [step([second, foreign], .idle, 0, .start(pid: 42, trigger: "company.call"))],
             automatic(attempt: [42, 77])),
            ("Murmurly bundle is ignored", empty,
             [step([Snapshot(pid: 2, bundleID: Bundle.main.bundleIdentifier, isRunningInput: true)])], empty),
            ("own PID with nil bundle is ignored", empty,
             [step([Snapshot(pid: ownPID, bundleID: nil, isRunningInput: true)])], empty),
            ("another recorder is not excluded by default", empty,
             [step([Snapshot(pid: 2, bundleID: "com.example.recorder", isRunningInput: true)], .idle, 0,
                   .start(pid: 2, trigger: "com.example.recorder"))], automatic(attempt: [2])),
            ("nil bundle starts with PID provenance", empty,
             [step([Snapshot(pid: 12, bundleID: nil, isRunningInput: true)], .idle, 0,
                   .start(pid: 12, trigger: "pid:12"))], automatic(attempt: [12])),
            ("one of two holders can leave", autoState,
             [step([second], .recording, 10)], automatic(session: [77])),
            ("silence below hysteresis does not stop", automatic(silent: 0),
             [step([], .recording, 29)], automatic(silent: 0)),
            ("silence at hysteresis stops", automatic(silent: 0),
             [step([], .recording, 30, .stop)], automatic(silent: 0)),
            ("holder returning clears silence", automatic(silent: 0),
             [step([foreign], .recording, 10)], automatic(session: [42])),
            ("recording collects session holders", empty,
             [step([foreign], .recording, 0), step([second], .recording, 2)],
             LogicState(sessionHolders: [42, 77])),
            ("a banned holder is not a session holder", LogicState(blockedPIDs: [90]),
             [step([blocked, foreign], .recording)],
             LogicState(blockedPIDs: [90], sessionHolders: [42])),
            ("ban clears only after release", LogicState(blockedPIDs: [42]), [
                step([foreign]), step([], .idle, 1),
                step([foreign], .idle, 2, .start(pid: 42, trigger: "company.call")),
            ], automatic(started: 2)),
            ("banned holder is not part of the attempt", LogicState(blockedPIDs: [90]),
             [step([blocked, second], .idle, 0, .start(pid: 77, trigger: "company.second"))],
             automatic(blocked: [90], attempt: [77])),
            ("blocked holder does not keep another session alive",
             automatic(silent: 0, blocked: [90]),
             [step([blocked], .recording, 30, .stop)],
             automatic(silent: 0, blocked: [90])),
            ("inactive process is ignored", empty,
             [step([Snapshot(pid: 8, bundleID: "company.call", isRunningInput: false)])], empty),
        ]

        for testCase in cases {
            var state = testCase.initial
            for item in testCase.steps {
                let decision = MeetingWatchdog.decide(
                    snapshot: item.snapshot,
                    recorderState: item.recorder,
                    ownPID: ownPID,
                    now: base.addingTimeInterval(item.offset),
                    state: &state
                )
                XCTAssertEqual(decision, item.expected, testCase.name)
            }
            XCTAssertEqual(state, testCase.final, testCase.name)
        }
    }

    func testOnlyAnAutomaticRecordingHasTheTimeLimit() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let limit = MeetingWatchdog.maximumAutomaticDuration
        let automatic = LogicState(automaticStartedAt: base)
        let cases: [(name: String, state: LogicState, recorder: MeetingRecorder.State,
                     offset: TimeInterval, reached: Bool)] = [
            ("below the limit", automatic, .recording, limit - 1, false),
            ("at the limit", automatic, .recording, limit, true),
            ("not before the recording starts", automatic, .starting, limit, false),
            ("not while saving", automatic, .stopping, limit, false),
            ("manual recording has no limit", LogicState(), .recording, 10 * limit, false),
        ]
        for item in cases {
            XCTAssertEqual(
                MeetingWatchdog.automaticLimitReached(
                    item.state, recorderState: item.recorder, now: base.addingTimeInterval(item.offset)
                ),
                item.reached,
                item.name
            )
        }
    }

    /// System Settings and its panes never hold a call; anything else holding
    /// the microphone, Apple's or not, with or without a bundle ID, still does.
    func testSystemSettingsIsNeverAHolder() {
        let settings = [
            "com.apple.systempreferences",
            "com.apple.Sound-Settings.extension",
            "com.apple.Siri-Settings.extension",
            "com.apple.Keyboard-Settings.extension",
            "com.apple.Accessibility-Settings.extension",
        ]
        let calls: [String?] = ["us.zoom.xos", "com.apple.FaceTime", "com.apple.avconferenced", nil]
        let snapshot = (settings.map(Optional.some) + calls).enumerated().map {
            Snapshot(pid: pid_t(100 + $0.offset), bundleID: $0.element, isRunningInput: true)
        }
        XCTAssertEqual(MeetingWatchdog.holders(in: snapshot, ownPID: 1).map(\.bundleID), calls)
    }

    func testDeclinedStartIsRetried() {
        let snapshot = Snapshot(pid: 42, bundleID: "company.call", isRunningInput: true)
        var starts = 0
        let watchdog = MeetingWatchdog(
            snapshotSource: { [snapshot] }, recorderState: { .idle },
            requestStart: { _ in starts += 1; return false }, requestStop: {}
        )
        watchdog.tick(now: Date(timeIntervalSince1970: 1))
        watchdog.tick(now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(starts, 2)
    }

    // MARK: Events

    func testFailedStartBansOnlyTheHoldersOfItsAttempt() {
        let harness = WatchdogHarness()
        harness.snapshot = [foreign]
        harness.watchdog.tick()
        harness.snapshot = [foreign, second]
        harness.recorder = .failed("boom")
        harness.watchdog.automaticStartFailed()

        harness.watchdog.tick()
        XCTAssertEqual(harness.starts, ["company.call", "company.second"])
        harness.recorder = .failed("boom")
        harness.watchdog.automaticStartFailed()
        harness.watchdog.tick()
        XCTAssertEqual(harness.starts.count, 2, "the failed holder was restarted")

        harness.snapshot = []
        harness.watchdog.tick()
        harness.snapshot = [foreign]
        harness.watchdog.tick()
        XCTAssertEqual(harness.starts.last, "company.call", "releasing did not lift the ban")
    }

    func testStopBansTheHoldersOfTheSnapshotTakenAsItBegins() {
        let harness = WatchdogHarness()
        harness.recorder = .recording
        harness.snapshot = [foreign]
        harness.watchdog.recordingWillStop()
        harness.snapshot = [foreign, second]
        harness.watchdog.recordingDidEnd()
        harness.recorder = .idle

        harness.watchdog.tick()
        XCTAssertEqual(harness.starts, ["company.second"])
    }

    func testStopWithoutSnapshotBansOnlyKnownSessionHolders() {
        let harness = WatchdogHarness()
        harness.snapshot = [foreign]
        harness.watchdog.tick()
        harness.recorder = .recording
        harness.snapshot = [foreign, seen]
        harness.watchdog.tick()
        harness.snapshot = nil
        harness.watchdog.recordingWillStop()
        harness.snapshot = [foreign, seen, second]
        harness.watchdog.recordingDidEnd()
        harness.recorder = .idle

        harness.watchdog.tick()
        XCTAssertEqual(harness.starts, ["company.call", "company.second"])
    }

    func testEndOfRecordingAloneBansNothing() {
        let harness = WatchdogHarness()
        harness.recorder = .recording
        harness.snapshot = [foreign]
        harness.watchdog.tick()
        harness.watchdog.recordingDidEnd()
        harness.recorder = .idle

        harness.watchdog.tick()
        XCTAssertEqual(harness.starts, ["company.call"])
    }

    func testManualStartDropsTheAttemptButKeepsBans() {
        let harness = WatchdogHarness()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let limit = MeetingWatchdog.maximumAutomaticDuration
        harness.recorder = .recording
        harness.snapshot = [blocked]
        harness.watchdog.recordingWillStop()
        harness.watchdog.recordingDidEnd()
        harness.recorder = .idle
        harness.snapshot = [blocked, foreign]
        harness.watchdog.tick(now: startedAt)
        XCTAssertEqual(harness.starts, ["company.call"])

        // The automatic attempt is still open when the manual one starts.
        harness.recorder = .failed("boom")
        harness.watchdog.manualRecordingStarted()
        harness.recorder = .recording
        harness.snapshot = [blocked]
        harness.watchdog.tick(now: startedAt.addingTimeInterval(10))
        harness.watchdog.tick(now: startedAt.addingTimeInterval(10 + MeetingWatchdog.stopHysteresis))
        harness.watchdog.tick(now: startedAt.addingTimeInterval(limit))
        XCTAssertEqual(harness.stops, 0, "a manual recording obeyed the automatic rules")

        harness.recorder = .idle
        harness.watchdog.tick()
        XCTAssertEqual(harness.starts, ["company.call"], "a manual start lifted the earlier ban")
    }

    func testLimitIsCheckedBeforeTheSnapshotIsRead() {
        let harness = WatchdogHarness()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let limit = MeetingWatchdog.maximumAutomaticDuration
        harness.snapshot = [foreign]
        harness.watchdog.tick(now: startedAt)
        harness.recorder = .recording
        harness.snapshot = nil

        harness.watchdog.tick(now: startedAt.addingTimeInterval(limit - 1))
        XCTAssertEqual(harness.stops, 0)
        let reads = harness.snapshotReads
        harness.watchdog.tick(now: startedAt.addingTimeInterval(limit))
        XCTAssertEqual(harness.snapshotReads, reads, "the limit waited for a snapshot read")
        XCTAssertEqual(harness.stops, 1)
    }
}
