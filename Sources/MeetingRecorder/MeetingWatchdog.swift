import AppKit
import CoreAudio
import Foundation

@MainActor
final class MeetingWatchdog {
    struct ProcessSnapshot: Equatable, Sendable {
        let pid: pid_t
        let bundleID: String?
        let isRunningInput: Bool
    }
    struct LogicState: Equatable, Sendable {
        var blockedPIDs: Set<pid_t> = []
        var automaticStartedAt: Date?
        var silentSince: Date?
        /// Active holders when the watchdog decided to start: the only PIDs a
        /// failed attempt may ban. A PID that appears later is not its own.
        var attemptHolders: Set<pid_t> = []
        /// Active holders seen while recording. A stop that cannot read Core
        /// Audio bans these instead of guessing from a later snapshot.
        var sessionHolders: Set<pid_t> = []
        /// Holders whose automatic start already failed once for a passing
        /// reason (a microphone not ready yet) and was let try again: the
        /// next failure bans them. Forgotten, like a ban, once they let go.
        var retriedPIDs: Set<pid_t> = []

        mutating func resetAutomaticAttempt() {
            automaticStartedAt = nil
            silentSince = nil
            attemptHolders = []
        }
    }
    enum Decision: Equatable, Sendable {
        case none, stop
        case start(pid: pid_t, trigger: String)
    }

    typealias SnapshotSource = @MainActor () -> [ProcessSnapshot]?
    typealias RecorderStateSource = @MainActor () -> MeetingRecorder.State
    typealias StartRequest = @MainActor (String) -> Bool
    typealias StopRequest = @MainActor () -> Void
    nonisolated static let stopHysteresis: TimeInterval = 30
    nonisolated static let maximumAutomaticDuration: TimeInterval = 4 * 60 * 60

    private let snapshotSource: SnapshotSource
    private let recorderState: RecorderStateSource
    private let requestStart: StartRequest
    private let requestStop: StopRequest
    /// The stop at the time limit, which the recorder reports as such.
    private let requestLimitStop: StopRequest
    private let ownPID: pid_t
    private var logic = LogicState()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var automaticEnabled = true
    private var excludedBundleIDs: Set<String> = []
    #if DEBUG
    /// Test-only: keeps the initial tick and manual `tick(now:)`, drops the
    /// periodic timer, so a test alone decides when the watchdog runs.
    static var periodicTicksDisabledForTesting = false
    #endif

    init(
        snapshotSource: @escaping SnapshotSource = MeetingWatchdog.readSystemSnapshot,
        recorderState: @escaping RecorderStateSource,
        requestStart: @escaping StartRequest,
        requestStop: @escaping StopRequest,
        requestLimitStop: StopRequest? = nil,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.snapshotSource = snapshotSource
        self.recorderState = recorderState
        self.requestStart = requestStart
        self.requestStop = requestStop
        self.requestLimitStop = requestLimitStop ?? requestStop
        self.ownPID = ownPID
    }

    func start() {
        guard timer == nil else { return }
        tick()
        #if DEBUG
        guard !Self.periodicTicksDisabledForTesting else { return }
        #endif
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopForSleep() }
        }
    }

    func tick(now: Date = Date()) {
        // Before the snapshot is read: an automatic recording must end on time
        // even while Core Audio cannot be read.
        if Self.automaticLimitReached(logic, recorderState: recorderState(), now: now) {
            requestLimitStop()
            return
        }
        guard let snapshot = snapshotSource() else { return }
        guard automaticEnabled else {
            // Off forbids starts, but an observed release still lifts a ban.
            let holding = Self.holders(in: snapshot, ownPID: ownPID).map(\.pid)
            logic.blockedPIDs.formIntersection(holding)
            logic.retriedPIDs.formIntersection(holding)
            return
        }
        let decision = Self.decide(
            snapshot: snapshot, recorderState: recorderState(), ownPID: ownPID,
            now: now, excludedBundleIDs: excludedBundleIDs, state: &logic
        )
        switch decision {
        case .none:
            break
        case let .start(_, trigger):
            if !requestStart(trigger) { logic.resetAutomaticAttempt() }
        case .stop:
            requestStop()
        }
    }

    func updateSettings(enabled: Bool, excludedBundleIDs: Set<String>) {
        let addedExclusions = excludedBundleIDs.subtracting(self.excludedBundleIDs)
        automaticEnabled = enabled
        self.excludedBundleIDs = excludedBundleIDs
        guard logic.automaticStartedAt != nil else { return }
        if !enabled {
            requestStop()
        } else if !addedExclusions.isEmpty, let snapshot = snapshotSource() {
            let holders = Self.holders(in: snapshot, ownPID: ownPID)
            let excludedHolder = holders.contains { $0.bundleID.map(addedExclusions.contains) ?? false }
            let remainingHolder = holders.contains { !($0.bundleID.map(excludedBundleIDs.contains) ?? false) }
            if excludedHolder && !remainingHolder { requestStop() }
        }
    }

    func automaticStartCancelled() { logic.resetAutomaticAttempt() }

    /// `capture.start` really failed. Bans only the holders this attempt was
    /// started for, so a call that appeared meanwhile gets its own attempt and
    /// the failed holder is not retried every tick until it lets go.
    /// `passing`: the failure may be gone in a moment (the microphone was not
    /// ready, as when the call itself was just taking it). Each holder may be
    /// let off once: those that were not get the next tick's attempt instead
    /// of a ban, so one such failure does not cost the whole call; those that
    /// already were are banned like after any failure.
    func automaticStartFailed(passing: Bool = false) {
        let holders = logic.attemptHolders
        let letOff = passing ? holders.subtracting(logic.retriedPIDs) : []
        logic.blockedPIDs.formUnion(holders.subtracting(letOff))
        logic.retriedPIDs.formUnion(letOff)
        logic.resetAutomaticAttempt()
    }

    /// The user started this session, so no automatic attempt owns it: neither
    /// the silence stop nor the time limit applies. Earned bans stay.
    func manualRecordingStarted() { logic.resetAutomaticAttempt() }

    /// Called as the stop begins, before the save is awaited: the call being
    /// stopped is the one holding the microphone now, and a call that starts
    /// while the save runs is someone else's.
    func recordingWillStop() {
        let holders = snapshotSource()
            .map { Set(Self.holders(in: $0, ownPID: ownPID).map(\.pid)) }
            ?? logic.attemptHolders.union(logic.sessionHolders)
        logic.blockedPIDs.formUnion(holders)
    }

    func recordingDidEnd() {
        logic.resetAutomaticAttempt()
        logic.sessionHolders = []
    }

    private func stopForSleep() { if recorderState() == .recording { requestStop() } }

    nonisolated static func readSystemSnapshot() -> [ProcessSnapshot]? {
        // A test copy never watches real processes. To the watchdog this reads
        // as an unreadable snapshot, which starts nothing.
        guard !TestIsolation.isEnabled else { return nil }
        guard let processes = try? AudioHardwareSystem.shared.processes else { return nil }
        return processes.compactMap { process in
            guard let pid = try? process.pid,
                  let isRunningInput = try? process.isRunningInput else { return nil }
            return ProcessSnapshot(
                pid: pid, bundleID: (try? process.bundleID) ?? nil,
                isRunningInput: isRunningInput
            )
        }
    }

    /// Foreign processes holding the microphone input. System Settings is
    /// never a call: Sound → Input holds the microphone for its level meter
    /// while someone only checks it, so it neither starts nor prolongs an
    /// automatic recording.
    nonisolated static func holders(
        in snapshot: [ProcessSnapshot], ownPID: pid_t
    ) -> [ProcessSnapshot] {
        snapshot.filter {
            $0.isRunningInput && $0.pid != ownPID
                && ($0.bundleID == nil || $0.bundleID != Bundle.main.bundleIdentifier)
                && !isSystemSettings($0.bundleID)
        }
    }

    /// The app and its panes; each pane runs as an extension process of its
    /// own, such as `com.apple.Sound-Settings.extension`.
    private nonisolated static func isSystemSettings(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.apple.systempreferences"
            || bundleID.hasPrefix("com.apple.systempreferences.")
            || (bundleID.hasPrefix("com.apple.") && bundleID.hasSuffix("-Settings.extension"))
    }

    /// Only an automatic attempt has a time limit; a manual session has none.
    nonisolated static func automaticLimitReached(
        _ state: LogicState, recorderState: MeetingRecorder.State, now: Date
    ) -> Bool {
        guard let startedAt = state.automaticStartedAt, recorderState == .recording else {
            return false
        }
        return now.timeIntervalSince(startedAt) >= maximumAutomaticDuration
    }

    nonisolated static func decide(
        snapshot: [ProcessSnapshot],
        recorderState: MeetingRecorder.State,
        ownPID: pid_t,
        now: Date,
        hysteresis: TimeInterval = stopHysteresis,
        excludedBundleIDs: Set<String> = [],
        state: inout LogicState
    ) -> Decision {
        let raw = holders(in: snapshot, ownPID: ownPID)
        let rawPIDs = Set(raw.map(\.pid))
        state.blockedPIDs.formIntersection(rawPIDs)
        state.retriedPIDs.formIntersection(rawPIDs)
        let active = raw.filter {
            !state.blockedPIDs.contains($0.pid)
                && !($0.bundleID.map(excludedBundleIDs.contains) ?? false)
        }
        if recorderState == .recording { state.sessionHolders.formUnion(active.map(\.pid)) }

        if state.automaticStartedAt != nil {
            guard recorderState == .recording else { return .none }
            guard active.isEmpty else {
                state.silentSince = nil
                return .none
            }
            guard let silentSince = state.silentSince else {
                state.silentSince = now
                return .none
            }
            return now.timeIntervalSince(silentSince) >= hysteresis ? .stop : .none
        }

        let canStart: Bool
        switch recorderState {
        case .idle, .failed: canStart = true
        case .starting, .recording, .stopping: canStart = false
        }
        guard canStart,
              let trigger = active.min(by: { $0.pid < $1.pid }) else { return .none }
        state.automaticStartedAt = now
        state.silentSince = nil
        state.attemptHolders = Set(active.map(\.pid))
        return .start(pid: trigger.pid, trigger: trigger.bundleID ?? "pid:\(trigger.pid)")
    }
}
