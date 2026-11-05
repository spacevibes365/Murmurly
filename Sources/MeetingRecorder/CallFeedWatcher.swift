import Darwin
import Foundation

/// Watches a call's page while a meeting is recorded (`MeetingPageReader`,
/// another card) and appends every change to `.call.murmurly.jsonl` in the
/// meeting's own folder, in `CallFeed`'s format (`Sources/Archive`). Started
/// by `MeetingRecorder` once `capture.start` succeeds and finished in
/// `beginStop`, before `capture.stop()` writes `metadata.json`.
actor CallFeedWatcher {
    /// One read of the call page. `skipped`: the microphone holders could
    /// not be read, so this read says nothing at all — no line, no state
    /// change, not even the clock. Only reachable before a pin is set: once
    /// pinned, an unreadable holder list must not stop the pinned page from
    /// being read (`MeetingRecorder.feedSource`).
    enum Read: Sendable {
        case skipped
        case notFound
        case found(CallFeed.Event, MeetingPageReader.Pin)
    }

    private let directory: URL
    /// Already converted to `CallFeed.Event` on the recorder's side, with a
    /// placeholder `t` this actor overwrites before use: `MeetingPageSnapshot`
    /// is not `Sendable`, and this keeps it from ever crossing into the
    /// actor. Takes this watcher's own pin, so it can read only the pinned
    /// app's windows once one is set.
    private let snapshotSource: @Sendable (MeetingPageReader.Pin?) async -> Read
    private let writtenSeconds: @Sendable () async -> TimeInterval?
    private let isEnabled: @MainActor @Sendable () -> Bool
    private let interval: Duration

    private var closed = false
    private var task: Task<Void, Never>?
    private var fileHandle: FileHandle?
    private var openFailed = false
    private var lastEvent: CallFeed.Event?
    /// Whether the page was ever found, this session: until it is, nothing
    /// is written at all, so a meeting with no call page leaves no file.
    private var everFound = false
    /// The service and app a find has fixed the recording to, never changed
    /// again: holders no longer matter for the choice once this is set.
    private var pin: MeetingPageReader.Pin?
    /// The capture's own clock as of the last line written, kept so
    /// `finish()` has a `t` to close the feed with even when the capture's
    /// clock cannot be read any more (the capture has already stopped).
    private var lastClock: TimeInterval?
    private(set) var snapshotCount = 0
    private(set) var changeCount = 0
    private(set) var skippedCount = 0

    init(
        directory: URL,
        snapshotSource: @escaping @Sendable (MeetingPageReader.Pin?) async -> Read,
        writtenSeconds: @escaping @Sendable () async -> TimeInterval?,
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        interval: Duration
    ) {
        self.directory = directory
        self.snapshotSource = snapshotSource
        self.writtenSeconds = writtenSeconds
        self.isEnabled = isEnabled
        self.interval = interval
    }

    /// Converts one `MeetingPageSnapshot` into a `Read`, the one place that
    /// builds the feed's own event out of what the reader saw — so
    /// `MeetingRecorder.feedSource` stays a plain hand-over of the snapshot,
    /// and `selfVisible` (3b) reaches the feed through exactly one path.
    /// `nonisolated`: touches no actor state, so the recorder's closure can
    /// call it before this actor is ever involved.
    nonisolated static func read(from snapshot: MeetingPageSnapshot) -> Read {
        guard snapshot.found else { return .notFound }
        let event = CallFeed.Event(
            t: 0, service: snapshot.service, visible: snapshot.visible,
            ownName: snapshot.selfName.isEmpty ? nil : snapshot.selfName,
            selfSpeaking: snapshot.selfSpeaking, people: snapshot.people, speaking: snapshot.speaking,
            selfVisible: snapshot.selfVisible
        )
        return .found(
            event,
            MeetingPageReader.Pin(service: snapshot.service, app: snapshot.app, meeting: snapshot.meeting)
        )
    }

    func start() {
        guard task == nil, !closed else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !closed {
            guard await isEnabled() else {
                // The setting was turned off mid-meeting: stop reading the
                // page ourselves, the same as a `finish()` from `beginStop`.
                await finish()
                return
            }
            let read = await snapshotSource(pin)
            switch read {
            case .skipped:
                // The microphone holders could not be read: this read says
                // nothing at all, not even the clock. Only possible before a
                // pin is set — once pinned, `snapshotSource` never answers
                // `.skipped` (see `MeetingRecorder.feedSource`), so an
                // unreadable holder list never stops the pinned page being
                // read.
                skippedCount += 1
            case .notFound:
                // Right after the snapshot answers, not before it: a slow
                // read (a browser tab taking up to 5 s) must not be timed
                // against a clock read before it even started.
                let seconds = await writtenSeconds()
                handle(nil, writtenSeconds: seconds)
            case let .found(event, foundPin):
                let seconds = await writtenSeconds()
                handle(event, writtenSeconds: seconds)
                // After `handle`, not before: the pin's effect on what is
                // read starts with the next poll either way. Only a
                // confirmed find (a tile actually seen) sets the pin: the
                // reader itself already refuses to pin an empty or
                // ambiguous area (2), and this is the watcher's own second
                // guard against pinning one anyway.
                if pin == nil, event.visible { pin = foundPin }
            }
            guard !closed else { return }
            try? await Task.sleep(for: interval)
        }
    }

    /// One snapshot's worth of work. `freshEvent` is what the page shows
    /// now (nil when no page was found on this read); `writtenSeconds` is
    /// the capture's clock at the same moment.
    private func handle(_ freshEvent: CallFeed.Event?, writtenSeconds: TimeInterval?) {
        guard !closed else { return }
        snapshotCount += 1
        // Without a clock there is no `t` to put the line at: skip it
        // rather than guess with the wall clock.
        guard let t = writtenSeconds else { return }
        lastClock = t

        let event: CallFeed.Event
        if var freshEvent {
            everFound = true
            freshEvent.t = t
            event = freshEvent
        } else if everFound {
            // The page was found before and is not now (the tab was closed
            // or navigated away): nobody is speaking any more, and the
            // name-picking function must not go on crediting whoever spoke
            // last. The service id is the one the last written line carried
            // — the page that just disappeared, not a guess.
            event = CallFeed.Event(
                t: t, service: lastEvent?.service ?? "", visible: false, ownName: nil, selfSpeaking: false,
                people: [], speaking: []
            )
        } else {
            // Never found: no file at all.
            return
        }
        write(event)
    }

    private func write(_ event: CallFeed.Event) {
        guard !isUnchanged(from: event) else { return }
        lastEvent = event
        guard !openFailed else { return }
        if fileHandle == nil {
            guard let handle = Self.openForAppending(directory.appendingPathComponent(CallFeed.fileName)) else {
                openFailed = true
                AppLog.error("meeting", "call feed: couldn’t open the feed file")
                return
            }
            fileHandle = handle
        }
        guard let fileHandle, let data = event.encodedLine().data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
            changeCount += 1
        } catch {
            openFailed = true
            try? fileHandle.close()
            self.fileHandle = nil
            AppLog.error("meeting", "call feed: write failed: \(error.localizedDescription)")
        }
    }

    /// Whether `event` is the same as the last one written, `t` aside: a
    /// moved clock alone is not a change the transcript needs a new line
    /// for.
    private func isUnchanged(from event: CallFeed.Event) -> Bool {
        guard var last = lastEvent else { return false }
        last.t = event.t
        return last == event
    }

    /// Closes the feed and stops reading the page. Never waits for a read
    /// already under way: a hung browser tab must not hold up a recording's
    /// stop. If anything was ever written, appends one last line marking the
    /// page `visible: false` with no names — otherwise the last speaker
    /// written would keep “speaking” for every second between this point and
    /// the end of the recording, once the transcript's lines are built from
    /// the feed. `closed` is set before the one `await` below: `self` is an
    /// actor, so that `await` lets `run()`'s loop back in, and without the
    /// flag set first a line from a read already in flight could land after
    /// this closing one. Safe to call more than once; later calls do
    /// nothing.
    func finish() async {
        guard !closed else { return }
        closed = true
        task?.cancel()
        if lastEvent != nil {
            let t = await writtenSeconds() ?? lastClock
            if let t {
                write(CallFeed.Event(
                    t: t, service: lastEvent?.service ?? "", visible: false, ownName: nil, selfSpeaking: false,
                    people: [], speaking: []
                ))
            }
        }
        if let fileHandle {
            try? fileHandle.close()
        }
        fileHandle = nil
        AppLog.info(
            "meeting",
            "call feed watcher finished; snapshots: \(snapshotCount), changes: \(changeCount), "
                + "skipped: \(skippedCount), page found: \(everFound ? "yes" : "no")"
        )
    }

    /// Opens for appending, creating the file at `0600` if it does not
    /// exist yet (it may hold other people's names): `O_NOFOLLOW` so a link
    /// at the address is never written through, `O_CLOEXEC` so a helper
    /// launched meanwhile never inherits the descriptor.
    private static func openForAppending(_ url: URL) -> FileHandle? {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
