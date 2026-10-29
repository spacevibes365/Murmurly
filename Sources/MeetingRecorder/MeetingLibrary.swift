import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// What the Murmurly window knows about meetings: the meetings in the local
/// root and in the chosen meetings folder, read off the main thread, with the
/// recorder's and the queue's live state laid over them. Owned by the app, so
/// a closed window keeps its last snapshot and nothing it started stops.
///
/// Reads only while the window is open. Each folder it reads (a root, or one
/// meeting outside both) has a serial queue of its own, never the cooperative
/// pool: a dead network volume holds that queue's one thread and nothing
/// else. At most one read per folder is under way; requests made meanwhile
/// are joined and run after it. An answer counts as fresh only if it was
/// started for the latest request of this opening of the window; a text
/// only reaches the screen for the meeting and version it was read for.
@MainActor
final class MeetingLibrary: ObservableObject {
    enum Place: Sendable, Equatable { case local, chosen, outside }

    /// One transcript file of a meeting; the type itself is
    /// `Archive.TranscriptVersion` (`Sources/Archive/Meetings.swift`), shared
    /// with the helper.
    typealias Version = Archive.TranscriptVersion

    /// What the last attempt by number left: none (no records, as with
    /// transcripts from before records existed), its record, or a record
    /// that cannot be read, which proves nothing about the transcripts. The
    /// type is `Archive.LastAttempt`, shared with the helper.
    typealias LastAttempt = Archive.LastAttempt

    struct Meeting: Sendable, Equatable, Identifiable {
        /// Its identity: two folders are two meetings, whatever their names.
        let directory: URL
        let place: Place
        let startedAt: Date?
        let duration: TimeInterval?
        /// `metadata.json`'s state; nil without it: the recording under way,
        /// or one cut off before its stop.
        let state: String?
        let issues: [String]
        let trigger: String?
        /// Nil when part of the folder could not be measured.
        let bytes: Int64?
        let versions: [Version]
        let lastAttempt: LastAttempt
        /// Files that are not the app's own.
        let otherFiles: [String]
        let hasTracks: Bool
        /// False when the folder itself could not be listed.
        let readable: Bool
        /// The user's name and star, from `murmurly.json`.
        var marks: MeetingMarks.State = .none
        /// The folder itself, whatever path reached it; nil when it could not
        /// be read. Its marks have one writer by it.
        var identity: FolderIdentity? = nil
        /// Read strictly, as a deletion would: what its audio is, and what
        /// the folder holds.
        var audio = MeetingStorage.Audio.unknown("")
        var manifest = MeetingStorage.ManifestRead.refused("")
        /// What the audio rule would do with it, read as the rule reads it.
        var retention = MeetingStorage.Retention.kept("")
        /// The files the player would play.
        var playback = MeetingStorage.Playback.unknown("")

        var id: URL { directory }
        /// Nothing from a file this app cannot read; the card says why.
        var title: String? { marks.marks?.title }
        var starred: Bool { marks.marks?.starred ?? false }
        var name: String { directory.lastPathComponent }
        /// Shorter than a minute: shown faded, never hidden.
        var isShort: Bool { duration.map { $0 < 60 } ?? false }
    }

    /// One folder the window reads and what it found.
    struct Listing: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case notRead
            case read
            /// A chosen folder that is not there: its meetings are not shown.
            case unavailable
            /// Could not be listed; the meetings shown are from before.
            case failed(String)
        }

        let folder: URL
        var state = State.notRead
        var meetings: [Meeting] = []
        /// Read for the latest request since the window opened.
        var fresh = false
        var reading = false
        /// The read has gone on longer than `notRespondingAfter`.
        var notResponding = false
    }

    enum ReadResult: Sendable, Equatable {
        case meetings([Meeting])
        case unavailable
        case failed(String)
    }

    /// How the disk is read, and a meeting's marks written off the main
    /// actor; tests stand in for it.
    struct Reader: Sendable {
        var root: @Sendable (_ folder: URL, _ place: Place) -> ReadResult
        /// One meeting outside both roots.
        var meeting: @Sendable (_ folder: URL) -> ReadResult
        var text: @Sendable (_ file: URL) throws -> String
        typealias MarksWrite = @Sendable (_ change: MeetingMarks.Change, _ folder: URL, _ identity: FolderIdentity) throws -> MeetingMarks
        var writeMarks: MarksWrite = { try MeetingMarks.write($0, in: $1, expecting: $2) }
        /// The folder the transcripts folder setting leads to, read right
        /// before a meeting goes to the Trash.
        var copiesFolder: @Sendable (_ folder: URL) -> FolderIdentity.Reach = { FolderIdentity.reach($0) }

        static let disk = Reader(
            root: { MeetingLibrary.readRoot($0, place: $1) },
            meeting: { MeetingLibrary.readOutside($0) },
            text: { try String(contentsOf: $0, encoding: .utf8) }
        )
    }

    enum Text: Sendable, Equatable {
        case none
        case loading
        case loaded(MeetingTranscript)
        case failed(String)
    }

    /// Where a transcript saved as a file goes, and its write; tests stand
    /// in for both.
    struct Saving: Sendable {
        /// The save panel's answer, on the window the save was asked from;
        /// nil when it was cancelled or that window was gone.
        var destination: @MainActor @Sendable (_ name: String, _ type: UTType, _ owner: NSWindow?) async -> URL?
        /// The write, on the library's own serial queue for saving.
        var write: @Sendable (_ data: Data, _ url: URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

        /// The panel of every window of the app (`FilesModel.present`): a
        /// test process never opens one.
        static let live = Saving(destination: askWhereToSave)

        /// A sheet on the window, as every panel of the app: never `runModal`.
        @MainActor
        static func askWhereToSave(_ name: String, _ type: UTType, _ owner: NSWindow?) async -> URL? {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [type]
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            return await FilesModel.present(panel, on: owner, as: .meetingTranscript)
        }
    }

    /// A transcript being saved as a file, one at a time: from the click,
    /// through the panel, to the end of its write. Taken as it was shown.
    struct Export: Equatable, Sendable {
        let meeting: URL
        let identity: FolderIdentity?
        let version: String
        let format: MeetingTranscript.Format
        /// The file's name: as suggested, then as chosen.
        var file: String
        /// Its place was chosen and it is being written: quit and updates
        /// wait for it.
        var writing = false
    }

    /// What became of a save.
    struct ExportOutcome: Equatable, Sendable {
        let meeting: URL
        let identity: FolderIdentity?
        let version: String
        let file: String
        /// Nil: saved.
        let failure: String?
    }

    /// The three things a meeting's transcription state is made of: what is
    /// going on now, what the last attempt left, and whether there is text.
    struct Status: Equatable {
        enum Operation: Equatable {
            case starting
            case recording(since: Date?)
            case saving
            case queued
            /// The queue's step, in the menu's words.
            case working(String)
        }

        enum Outcome: Equatable {
            case complete
            case incomplete(cutShort: Bool, failedChunks: Int, missingTracks: [MeetingAttempt.Source])
            case noSpeech
            case failed(String)
            /// Its record says it never ended: the app was killed, or the
            /// result could not be written.
            case interrupted
            /// The last record cannot be read.
            case unknown
        }

        var operation: Operation?
        var outcome: Outcome?
        var hasTranscript: Bool
        /// No metadata, and neither being recorded nor being saved.
        var brokenOff: Bool
        /// The folder itself could not be read: nothing else is known.
        var unreadable = false
    }

    @Published private(set) var local: Listing
    @Published private(set) var chosen: Listing?
    @Published private(set) var outside: [Listing] = []
    @Published private(set) var selection: URL?
    /// The meetings selected in the list; `selection` is the one on the card
    /// when there is exactly one.
    @Published private(set) var selectedFolders: Set<URL> = []
    @Published private(set) var version: String?
    @Published private(set) var text = Text.none
    @Published private(set) var isWindowOpen = false
    /// The main window's section, in memory only and kept while the window
    /// is closed: a command given then is there for its first appearance,
    /// and Open Murmurly or a reopen shows the last one.
    @Published var section: MainSection = .meetings {
        didSet {
            guard section != oldValue else { return }
            // Away from the meetings the card is not shown: its sound stops,
            // and a match waiting to take the focus no longer does.
            if !isCardShown { searchFocus = nil }
            syncPlayer()
        }
    }

    /// The card can be seen: the window open on Meetings or Starred.
    var isCardShown: Bool { isWindowOpen && (section == .meetings || section == .starred) }
    /// The folders whose marks the user set are not on disk yet:
    /// being written to a folder that is not on this Mac. Quit and updates
    /// wait for them.
    @Published private(set) var pendingMarks: Set<FolderIdentity> = []
    /// Why the last write of a meeting's marks failed, and what it would
    /// have written; shown on its card until the next write.
    @Published private(set) var markFailures: [FolderIdentity: MarkFailure] = [:]
    /// A write that failed off the main actor while another meeting, or
    /// none, was on the card: nothing on screen would say so. Shown above the
    /// list until dismissed; the latest one wins.
    @Published private(set) var markNotice: MarkNotice?

    /// The save under way, from its click to the end of its write.
    @Published private(set) var exporting: Export?
    /// The last save of the meeting and version on the card, said there
    /// until another meeting or version is shown.
    @Published private(set) var exportOutcome: ExportOutcome?
    /// A save that ended while its meeting and version were not on the
    /// card, or the window was closed, saved or not: said above the list
    /// until dismissed.
    @Published private(set) var exportNotice: ExportOutcome?

    /// What became of the last deletions, until dismissed.
    @Published private(set) var removalReport: [RemovalLine] = []
    /// Meetings that changed between their confirmation and their deletion:
    /// asked about again, with what they hold now.
    @Published private(set) var removalRecheck: RemovalPlan?
    /// Shows a folder in Finder; tests stand in for it.
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private var removalRecheckItems: [RemovalItem] = []
    private var removalsUnderWay = 0

    /// A write of a meeting's marks that failed: why, and every field the
    /// user set that it would have written, so what was typed is said, not
    /// lost unsaid.
    struct MarkFailure: Equatable, Sendable {
        let reason: String
        let lost: MeetingMarks.Change
    }

    struct MarkNotice: Equatable, Sendable {
        /// What was not saved.
        let lost: MeetingMarks.Change
        /// The meeting as its row showed it then.
        let meeting: String
        let reason: String

        /// The name that was not saved; nil when only other marks were.
        var title: String? { lost.title ?? nil }
    }

    private let recorder: MeetingRecorder
    private let queue: MeetingTranscriptionQueue
    private let settings: SettingsStore
    private weak var dictation: DictationCoordinator?
    private let reader: Reader
    private let saving: Saving
    /// Saves go one after another, off the main thread and off the
    /// cooperative pool: the chosen folder may be on a network volume.
    private let exportQueue = DispatchQueue(label: "meeting-export", qos: .userInitiated)
    /// The selected meeting's audio; this model alone loads and lets go of it.
    let player: MeetingPlayer
    private var playerSubscriptions: [AnyCancellable] = []
    private var playerQueues: [String: DispatchQueue] = [:]
    private var playerSyncScheduled = false
    private let notRespondingAfter: Duration
    private let applicationName: @MainActor (String) -> String
    private var applicationNames: [String: String] = [:]
    /// A version chosen by hand stays chosen when the folder is read again.
    private var versionPicked = false
    /// The folder of the session that just ended, until a read of the local
    /// root started after the end answers: until then a snapshot without its
    /// metadata is out of date, not a recording that broke off. After it, a
    /// folder still without metadata did break off (its stop could not write
    /// them).
    private var recentlyStopped: URL?
    /// Counts the reads started, so a read can tell whether it began after
    /// the session ended (`readsAtStop`).
    private var readsStarted = 0
    private var readsAtStop = 0
    private var liveSession: URL?
    private var windowGeneration = 0
    private var requestGeneration = 0
    private var textToken = 0
    private var refreshScheduled = false
    private var channels: [String: Channel] = [:]
    private var windowSubscriptions: [AnyCancellable] = []
    private var sessionSubscription: AnyCancellable?
    /// Each meeting folder's marks writer, by the folder itself.
    private var marksStates: [FolderIdentity: Marks] = [:]
    /// Counts the marks writes that succeeded; a read knows which came before it.
    private var marksClock = 0

    init(
        recorder: MeetingRecorder,
        queue: MeetingTranscriptionQueue,
        settings: SettingsStore,
        localRoot: URL = RecordingsStore.meetingsRoot(),
        reader: Reader = .disk,
        notRespondingAfter: Duration = .seconds(3),
        applicationName: @escaping @MainActor (String) -> String = { MeetingsSettingsView.applicationName($0) },
        dictation: DictationCoordinator? = nil,
        deck: MeetingPlayer.Deck = .live,
        saving: Saving = .live
    ) {
        self.recorder = recorder
        self.queue = queue
        self.settings = settings
        self.dictation = dictation
        self.reader = reader
        self.saving = saving
        player = MeetingPlayer(deck: deck)
        self.notRespondingAfter = notRespondingAfter
        self.applicationName = applicationName
        local = Listing(folder: Self.canonical(localRoot))
        // Without the window too, and without reading anything: a session
        // that ends while the window is closed is not a broken one later.
        sessionSubscription = recorder.$currentSession.sink { [weak self] session in
            self?.sessionChanged(to: session)
        }
        // The queue's move waits for a write of the folder's marks under way.
        queue.marksBeingWritten = { [weak self] identity in self?.marksStates[identity]?.isPending ?? false }
        listen()
    }

    // MARK: - The window

    func windowOpened() {
        guard !isWindowOpen else { return }
        isWindowOpen = true
        windowGeneration += 1
        for path in listingPaths { update(path) { $0.fresh = false } }
        // A move made while the window was closed was heard by no one.
        follow(queue.movedTo)
        // `@Published` sends before the property changes; each of these only
        // asks for a read, which looks at the state once it has changed.
        windowSubscriptions = [
            queue.$lastOutcome.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() },
            queue.$finishedJobs.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() },
            queue.$movedTo.dropFirst().sink { [weak self] moves in self?.follow(moves) },
            settings.$meetingsFolderPath.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() },
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.scheduleRefresh() },
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
                .sink { [weak self] _ in self?.scheduleRefresh() },
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
                .sink { [weak self] note in
                    self?.volumeWentAway(note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
                    self?.scheduleRefresh()
                },
        ]
        refresh()
        syncPlayer()
    }

    /// The last snapshot stays for the next opening; a meeting read on its
    /// own, outside both roots, goes.
    func windowClosed() {
        guard isWindowOpen else { return }
        isWindowOpen = false
        windowSubscriptions = []
        player.unload()
        // The texts are large and the query is the window's: both go.
        searchQuery = ""
        searchTexts = [:]
        searchFailures = [:]
        outside = []
        if let selection, meeting(at: selection) == nil {
            self.selection = nil
            version = nil
            text = .none
        }
    }

    /// Reads every folder the window shows again: "Refresh", "Try Again".
    func refresh() {
        guard isWindowOpen else { return }
        requestGeneration += 1
        followChosenFolder()
        // What was read before this request may be out of date already.
        for path in listingPaths {
            update(path) { $0.fresh = false }
            listingRevisions[path, default: 0] += 1
            requestList(path)
        }
        searchInvalidated()
    }

    // MARK: - Selection

    /// A meeting from the list; its newest version.
    func select(_ folder: URL?) {
        let folder = folder.map(Self.canonical)
        selectedFolders = folder.map { [$0] } ?? []
        guard folder != selection else { return }
        selection = folder
        exportOutcome = nil
        versionPicked = false
        version = folder.flatMap { meeting(at: $0) }?.versions.last?.name
        loadText()
        syncPlayer()
    }

    /// Several meetings from the list: none on the card, unless only one.
    func select(_ folders: Set<URL>) {
        let folders = Set(folders.map(Self.canonical))
        guard folders.count > 1 else {
            select(folders.first)
            return
        }
        selectedFolders = folders
        selection = nil
        exportOutcome = nil
        version = nil
        versionPicked = false
        loadText()
        syncPlayer()
    }

    /// A version picked by hand; reading the folder again keeps it.
    func pick(version name: String) {
        guard name != version else { return }
        version = name
        exportOutcome = nil
        versionPicked = true
        // The same audio, another text: the lines are another version's.
        player.pause()
        loadText()
    }

    /// A meeting asked for from the menu, with the version it names. One
    /// outside both roots (the meetings folder changed since, or picked by
    /// hand anywhere) is read on its own and listed until the window closes.
    func open(_ folder: URL, transcript: String? = nil) {
        // On the meetings, whatever the window showed: not under a search
        // that leaves the meeting out, nor among the starred without it.
        section = .meetings
        if !searchQuery.isEmpty { searchQuery = "" }
        let folder = Self.canonical(folder)
        if !isInRoots(folder), !outside.contains(where: { $0.folder == folder }) {
            outside.append(Listing(folder: folder))
            if isWindowOpen { requestList(folder.path) }
        }
        if selection != folder { exportOutcome = nil }
        selection = folder
        selectedFolders = [folder]
        version = transcript ?? meeting(at: folder)?.versions.last?.name
        versionPicked = transcript != nil
        loadText()
        syncPlayer()
    }

    func meeting(at folder: URL) -> Meeting? {
        let path = folder.standardizedFileURL.path
        return ([local] + [chosen].compactMap { $0 } + outside)
            .lazy.flatMap(\.meetings).first { $0.directory.path == path }
    }

    // MARK: - What the list shows

    /// Both roots' meetings, newest first, without the recording under way,
    /// which has a row of its own. A name in both roots is two meetings.
    var meetings: [Meeting] {
        let live = recorder.currentSession?.directory.standardizedFileURL.path
        let chosenMeetings = chosen?.state == .unavailable ? [] : chosen?.meetings ?? []
        return (local.meetings + chosenMeetings)
            .filter { $0.directory.path != live }
            .sorted { ($0.startedAt ?? .distantPast, $0.name) > ($1.startedAt ?? .distantPast, $1.name) }
    }

    /// Meetings read on their own, outside both roots.
    var outsideMeetings: [Meeting] { outside.flatMap(\.meetings) }

    /// Whether a meeting of the same name is in the other root: not merged,
    /// but said, since the two may or may not be one recording.
    func isInBothPlaces(_ meeting: Meeting) -> Bool {
        guard meeting.place != .outside, let chosen else { return false }
        let other = meeting.place == .local ? chosen.meetings : local.meetings
        return other.contains { $0.name == meeting.name }
    }

    func status(of meeting: Meeting) -> Status {
        let path = meeting.directory.path
        var operation: Status.Operation?
        if recorder.currentSession?.directory.standardizedFileURL.path == path {
            switch recorder.state {
            case .starting: operation = .starting
            case .recording: operation = .recording(since: recorder.currentSession?.startedAt)
            case .stopping, .idle, .failed: operation = .saving
            }
        } else if recentlyStopped?.path == path, meeting.state == nil {
            operation = .saving
        } else if let other = queue.operation(on: meeting.identity), other.kind != .moving {
            // A deletion; a move is the job's own step, said below.
            operation = .working(MeetingTranscriptionQueue.describe(other.kind))
        } else if queue.activeJob?.folder.standardizedFileURL.path == path {
            operation = .working(queue.stepLabel ?? "")
        } else if queue.pending.contains(where: { $0.transcribe && $0.folder.standardizedFileURL.path == path }) {
            operation = .queued
        }

        var outcome: Status.Outcome?
        if case .failed(_, let reason)? = queue.unrecordedOutcomes[path] {
            outcome = .failed(reason)
        } else {
            switch meeting.lastAttempt {
            case .none: outcome = nil
            case .unreadable: outcome = .unknown
            case .recorded(let attempt):
                switch attempt.result {
                case .inProgress:
                    // The record of the job under way, or one that never ended.
                    let underWay: Bool = if case .working? = operation { true } else { operation == .queued }
                    outcome = underWay ? nil : .interrupted
                case .complete: outcome = .complete
                case .incomplete:
                    outcome = .incomplete(
                        cutShort: attempt.cutShort, failedChunks: attempt.failedChunks, missingTracks: attempt.missingTracks
                    )
                case .noSpeech: outcome = .noSpeech
                case .failed: outcome = .failed(attempt.reason ?? "")
                }
            }
        }
        return Status(
            operation: operation,
            outcome: outcome,
            hasTranscript: !meeting.versions.isEmpty,
            brokenOff: meeting.readable && meeting.state == nil && operation == nil,
            unreadable: !meeting.readable
        )
    }

    /// What the card warns about besides the last attempt: the recording's
    /// own problems (its metadata, and the recorder's note of the 4-hour
    /// limit, which lives in memory only) and what kept the queue from
    /// compressing, copying or moving it, under the address it had then.
    func warnings(of meeting: Meeting) -> [String] {
        let path = meeting.directory.path
        var lines: [String] = []
        if let state = meeting.state, state != "done" {
            lines += meeting.issues.isEmpty
                ? [String(localized: "state “\(state)” — check the recording")] : meeting.issues
        }
        if let warning = recorder.recordingWarning, address(of: warning.directory).path == path {
            lines += warning.issues.filter { !lines.contains($0) }
        }
        let addresses = [path] + queue.movedTo.filter { Self.canonical($0.value).path == path }.map(\.key)
        for (folder, issues) in queue.issues.sorted(by: { $0.key.path < $1.key.path })
        where addresses.contains(folder.standardizedFileURL.path) {
            lines += issues.lines
        }
        return lines
    }

    /// Who started the recording, for the row: the app's name, "Manual", an
    /// unknown process, or nil for recordings from before this was written.
    func sourceName(of trigger: String?) -> String? {
        guard let trigger else { return nil }
        if trigger == MeetingMetadata.manualTrigger {
            return String(localized: "Manual", comment: "Who started a meeting recording: the user, by hand")
        }
        if trigger.hasPrefix("pid:") { return String(localized: "Unknown process") }
        if let name = applicationNames[trigger] { return name }
        let name = applicationName(trigger)
        applicationNames[trigger] = name
        return name
    }

    // MARK: - Transcribing

    /// Where a meeting is now: where this run's own move took it, or where it
    /// was. A folder at the old place again (a copy put back) is a meeting of
    /// its own, as the queue also takes it: only a local path that is gone is
    /// followed, and only a local one is checked on disk.
    func address(of folder: URL) -> URL {
        let folder = Self.canonical(folder)
        guard let place = queue.movedTo[folder.path], !FileManager.default.fileExists(atPath: folder.path) else {
            return folder
        }
        return Self.canonical(place)
    }

    /// Why the meeting cannot be transcribed now, or nil. The model is the
    /// view's to check, as it offers the download.
    func transcriptionRefusal(for folder: URL) -> String? {
        let folder = address(of: folder)
        if recorder.currentSession?.directory.standardizedFileURL.path == folder.path {
            return String(localized: "The meeting is being recorded.")
        }
        guard let meeting = meeting(at: folder), meeting.readable else {
            return String(localized: "The meeting folder can’t be read.")
        }
        guard meeting.hasTracks else { return String(localized: "The meeting has no audio.") }
        if let operation = queue.operation(on: meeting.identity) { return MeetingTranscriptionQueue.describe(operation.kind) }
        let listing = listingPath(of: meeting).flatMap(listing(at:))
        if listing?.state == .unavailable || listing?.notResponding == true {
            return String(localized: "The meetings folder isn’t available.")
        }
        return nil
    }

    /// The meeting a sheet or a button was opened for, at its address now,
    /// whatever is selected by then; checked again before it is queued.
    @discardableResult
    func transcribe(_ folder: URL, choice: SettingsSnapshot.Choice? = nil) -> Bool {
        let target = address(of: folder)
        guard transcriptionRefusal(for: target) == nil else { return false }
        queue.enqueue(target, choice: choice, identity: meeting(at: target)?.identity)
        return true
    }

    // MARK: - Listening

    /// The player follows the recorder, the dictation and the queue from the
    /// start: a recording starting or a deletion taken while the window is
    /// closed meets no player to stop, and one open meets it in that turn.
    private func listen() {
        player.startRefusal = { [weak self] in self?.startRefusal() }
        queue.releaseAudio = { [weak self] addresses, kind in
            self?.player.release(Set(addresses.compactMap(\.identity)), reason: MeetingTranscriptionQueue.describe(kind))
        }
        queue.audioOpening = { [weak self] identities in self?.player.isOpening(identities) ?? false }
        // `@Published` sends before the property changes: the state sent.
        playerSubscriptions = [
            recorder.$state.sink { [weak self] state in
                if state.isBusy { self?.player.hold(Self.recordingRefusal) } else { self?.player.unhold() }
            },
            queue.$operations.dropFirst().sink { [weak self] _ in self?.schedulePlayerSync() },
        ]
        if let dictation {
            playerSubscriptions.append(dictation.$state.sink { [weak self] state in
                if state != .idle { self?.player.hold(Self.dictationRefusal) } else { self?.player.unhold() }
            })
        }
    }

    /// The system audio is recorded whole: what plays would be in the recording.
    nonisolated static var recordingRefusal: String {
        String(localized: "A meeting is being recorded: what plays would be recorded with it.")
    }

    /// The microphone would hear what plays.
    nonisolated static var dictationRefusal: String {
        String(localized: "Dictation is under way.")
    }

    /// Why the player may not start now, asked right before every start.
    private func startRefusal() -> String? {
        if recorder.isBusy { return Self.recordingRefusal }
        if dictation?.isBusy == true { return Self.dictationRefusal }
        guard isCardShown, let identity = player.identity,
              let shown = selection.flatMap({ meeting(at: $0) }), shown.identity == identity else {
            return String(localized: "Select a meeting")
        }
        if let operation = queue.operation(on: identity) { return MeetingTranscriptionQueue.describe(operation.kind) }
        return nil
    }

    /// Why the meeting's audio cannot be opened now, or nil.
    func audioRefusal(for meeting: Meeting) -> String? {
        guard meeting.readable, let identity = meeting.identity else {
            return String(localized: "The meeting folder can’t be read.")
        }
        if let operation = queue.operation(on: identity) { return MeetingTranscriptionQueue.describe(operation.kind) }
        if listingPath(of: meeting).flatMap(listing(at:))?.state == .unavailable {
            return String(localized: "The meetings folder isn’t available.")
        }
        switch meeting.playback {
        case .unknown(let reason): return String(localized: "The audio can’t be told: \(reason)")
        case .tracks(let files) where files.isEmpty:
            return MeetingText.audioNote(meeting) ?? String(localized: "The meeting has no audio.")
        case .tracks: return nil
        }
    }

    private func schedulePlayerSync() {
        guard !playerSyncScheduled else { return }
        playerSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.playerSyncScheduled = false
                self?.syncPlayer()
            }
        }
    }

    /// The meeting on the card, its audio open or why not. A meeting already
    /// loaded stays so while it is the same folder: a compression that
    /// replaced a track does not cut the sound off.
    private func syncPlayer() {
        guard isCardShown, let selection, let meeting = meeting(at: selection),
              recorder.currentSession.map({ Self.canonical($0.directory) }) != selection else {
            player.unload()
            return
        }
        if let reason = audioRefusal(for: meeting) {
            if player.state != .unavailable(reason) || player.folder != meeting.directory { player.unload(reason) }
            return
        }
        guard case .tracks(let files) = meeting.playback, let identity = meeting.identity else { return }
        if player.folder == meeting.directory, player.identity == identity, player.isLoaded || player.state == .loading {
            return
        }
        let serial = playerQueue(meeting.directory.deletingLastPathComponent().path)
        player.load(meeting.directory, identity: identity, files: files) { serial.async(execute: $0) }
    }

    /// The player's own serial queue for a parent folder: an open waits
    /// neither for the list's reads nor makes them wait, and a dead volume
    /// holds only its own.
    private func playerQueue(_ path: String) -> DispatchQueue {
        if let queue = playerQueues[path] { return queue }
        let queue = DispatchQueue(label: "meeting-player \(path)", qos: .userInitiated)
        playerQueues[path] = queue
        return queue
    }

    /// A volume went: the player's files on it are closed.
    private func volumeWentAway(_ volume: URL?) {
        guard let volume, let folder = player.folder else { return }
        let root = volume.standardizedFileURL.path.hasSuffix("/") ? volume.standardizedFileURL.path : volume.standardizedFileURL.path + "/"
        if folder.standardizedFileURL.path.hasPrefix(root) {
            player.unload(String(localized: "The meeting folder isn’t available."))
        }
    }

    // MARK: - Marks

    /// One meeting folder's marks writer, by the folder itself: the only
    /// writer of its murmurly.json, whichever section, root, menu or path
    /// shows the meeting, so two writes of one folder never race and every
    /// change goes after the one under way.
    private struct Marks {
        /// Where to write: the address the user last changed it through.
        var folder: URL
        /// Every field the user set that is not known to be on disk yet.
        var change = MeetingMarks.Change()
        /// Counts the user's changes, so a write knows whether it took the last.
        var edits = 0
        /// The count of the write under way.
        var writing: Int?
        /// What the last write left on disk, and when (`marksClock`): a read
        /// started before it does not take it back.
        var confirmed: (marks: MeetingMarks, at: Int)?

        var isPending: Bool { !change.isEmpty || writing != nil }
    }

    /// The marks shown: the folder's, with what the user set and is not on disk yet.
    func marks(of meeting: Meeting) -> MeetingMarks? {
        guard let marks = meeting.marks.marks else { return nil }
        return meeting.identity.flatMap { marksStates[$0] }.map { $0.change.applied(to: marks) } ?? marks
    }

    var starredMeetings: [Meeting] { meetings.filter { marks(of: $0)?.starred == true } }

    /// The text on the card as it is shown, copied and saved: the user's
    /// names in place of the labels where the record says which track each
    /// line came from. Nil while the meeting's text is not on the card.
    func shownTranscript(of meeting: Meeting) -> MeetingTranscript? {
        guard selection == meeting.directory, case .loaded(let transcript) = text,
              let meeting = self.meeting(at: meeting.directory) else { return nil }
        return transcript.named(marks(of: meeting)?.speakers ?? [:])
    }

    /// Who speaks on each track, for the player: the user's name for it
    /// whichever version is shown, as the track is known even where the
    /// text's lines are not; else the label as written.
    func trackLabels(of meeting: Meeting) -> [MeetingAttempt.Source: String] {
        let names = marks(of: self.meeting(at: meeting.directory) ?? meeting)?.speakers ?? [:]
        return writtenLabels(of: meeting).merging(names) { _, name in name }
    }

    /// The labels the shown version's record says it wrote, else the app's
    /// own: what an empty name gives back.
    func writtenLabels(of meeting: Meeting) -> [MeetingAttempt.Source: String] {
        let speakers = meeting.versions.first { $0.name == version }?.attempt?.speakers
        return [
            .microphone: speakers?.microphone ?? MeetingTranscriber.microphoneSpeaker,
            .system: speakers?.system ?? MeetingTranscriber.systemSpeaker,
        ]
    }

    /// Why a meeting's name and star cannot be changed now, or nil. While the
    /// queue moves the folder nothing is written into it: the copy would
    /// leave the change behind.
    func markRefusal(for meeting: Meeting) -> String? {
        if recorder.currentSession.map({ Self.canonical($0.directory).path }) == meeting.directory.path
            || meeting.identity != nil && recorder.currentSession?.identity == meeting.identity {
            return String(localized: "The meeting is being recorded.")
        }
        guard meeting.readable, let identity = meeting.identity else {
            return String(localized: "The meeting folder can’t be read.")
        }
        if let operation = queue.operation(on: identity) {
            return MeetingTranscriptionQueue.describe(operation.kind)
        }
        if isInBothPlaces(meeting) {
            return String(localized: "A folder of this name is both on this Mac and in the meetings folder: marks wait until one is left.")
        }
        switch meeting.marks {
        case .unreadable(let reason): return MeetingMarks.Refusal.unreadable(reason).localizedDescription
        case .newer(let version): return MeetingMarks.Refusal.newer(version: version).localizedDescription
        case .none, .read: break
        }
        let listing = listingPath(of: meeting).flatMap(listing(at:))
        if listing?.state == .unavailable || listing?.notResponding == true {
            return String(localized: "The meetings folder isn’t available.")
        }
        return nil
    }

    func dismissMarkNotice() {
        markNotice = nil
    }

    /// The marks are not on disk yet.
    func isSavingMarks(_ meeting: Meeting) -> Bool { meeting.identity.map(pendingMarks.contains) ?? false }

    /// Why the last write of the meeting's marks failed.
    func markFailure(of meeting: Meeting) -> MarkFailure? { meeting.identity.flatMap { markFailures[$0] } }

    func toggleStar(_ meeting: Meeting) {
        guard let marks = marks(of: meeting) else { return }
        change(MeetingMarks.Change(starred: !marks.starred), of: meeting)
    }

    /// Only the title changes, never the folder's name; an empty name gives
    /// the date back. Returns why it was not taken or not written, or nil.
    @discardableResult
    func rename(_ meeting: Meeting, to name: String) -> String? {
        guard let marks = marks(of: meeting) else { return markRefusal(for: meeting) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = name.isEmpty ? nil : name
        guard title != marks.title else { return nil }
        return change(MeetingMarks.Change(title: .some(title)), of: meeting)
    }

    /// A name typed on a meeting, taken when the typing ends, whatever is
    /// selected by then: the meeting is found by its folder, at the path it
    /// was typed at or any other. Returns why it was not taken, or nil.
    func rename(typedOn identity: FolderIdentity?, at path: String, to name: String) -> String? {
        guard let meeting = typed(on: identity, at: path) else {
            return String(localized: "The meeting moved while its name was typed.")
        }
        return rename(meeting, to: name)
    }

    /// The meeting something was typed on, by its folder: at the path it
    /// showed then, or any other. Never by the path alone: another folder
    /// may be there now, and a copy the queue moved is another folder.
    private func typed(on identity: FolderIdentity?, at path: String) -> Meeting? {
        let meetings = ([local] + [chosen].compactMap { $0 } + outside).flatMap(\.meetings)
        guard let identity else { return nil }
        return meetings.first(where: { $0.identity == identity && $0.directory.path == path })
            ?? meetings.first(where: { $0.identity == identity })
    }

    /// The names of a meeting's speakers typed in its sheet, for the meeting
    /// it was opened on, as a name typed. Only a name that differs from the
    /// one kept changes; an empty one gives the transcript's label back.
    /// Returns why they were not taken, or nil.
    func setNames(typedOn identity: FolderIdentity?, at path: String, microphone: String, system: String) -> String? {
        guard let meeting = typed(on: identity, at: path) else {
            return String(localized: "The meeting moved while the names were typed.")
        }
        guard let marks = marks(of: meeting) else { return markRefusal(for: meeting) }
        var change = MeetingMarks.Change()
        for (source, typed) in [(MeetingAttempt.Source.microphone, microphone), (.system, system)] {
            if let refusal = Self.speakerNameRefusal(typed) { return refusal }
            let name = Self.speakerName(typed)
            if name != marks.speakers[source] { change.speakers.updateValue(name, forKey: source) }
        }
        guard !change.isEmpty else { return nil }
        return self.change(change, of: meeting)
    }

    /// The names sheet's Save: as `setNames`, then, for a folder written off
    /// the main actor, until that write has ended: nil once the names are on
    /// disk, else why not, with the names, so the sheet that waits on it
    /// says a late refusal where they are still typed.
    func saveNames(typedOn identity: FolderIdentity?, at path: String, microphone: String, system: String) async -> String? {
        if let refusal = setNames(typedOn: identity, at: path, microphone: microphone, system: system) { return refusal }
        guard let identity else { return nil }
        for await pending in $pendingMarks.values where !pending.contains(identity) { break }
        return markFailures[identity].map { MeetingText.marksNotSaved($0.lost, reason: $0.reason, meeting: nil) }
    }

    /// A name as kept: one line, as it stands in a line's label and a
    /// subtitle; nil when nothing is left.
    nonisolated static func speakerName(_ typed: String) -> String? {
        let name = typed.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A name goes between the `**` of a line's label in a saved Markdown
    /// file: with a `*` of its own it would end the label early, and the
    /// file would read back with other labels and other words.
    nonisolated static func speakerNameRefusal(_ typed: String) -> String? {
        typed.contains("*") ? String(localized: "Names can’t contain “*”.") : nil
    }

    /// Why the transcript shown has no record of the attempt that wrote it
    /// matching it, so no names, no exact times and no subtitles; nil when it
    /// has. Said as proven: no records only when the meeting has none at
    /// all, changed only when the record's fingerprint differs.
    func recordRefusal(for meeting: Meeting) -> String? {
        guard selection == meeting.directory, case .loaded(let transcript) = text else {
            return String(localized: "The transcript isn’t read yet.")
        }
        let attempt = meeting.versions.first { $0.name == version }?.attempt
        return Self.recordRefusal(transcript, attempt: attempt, meetingHasRecords: meeting.lastAttempt != .none)
    }

    /// Why the transcript shown cannot be saved as subtitles, or nil: no
    /// matching record, or times in it a subtitle cannot hold.
    func subtitlesRefusal(for meeting: Meeting) -> String? {
        if let refusal = recordRefusal(for: meeting) { return refusal }
        guard shownTranscript(of: meeting)?.exported(as: .subtitles) == nil else { return nil }
        return String(localized: "The record’s line times can’t be used for subtitles.")
    }

    nonisolated static func recordRefusal(
        _ transcript: MeetingTranscript, attempt: MeetingAttempt?, meetingHasRecords: Bool
    ) -> String? {
        if case .exact = transcript.timing { return nil }
        if attempt == nil, !meetingHasRecords {
            return String(localized: "There are no records of this meeting’s transcriptions: which track each line came from isn’t known.")
        }
        if let fingerprint = attempt?.fingerprint, !transcript.matches(fingerprint) {
            return String(localized: "The transcript file was changed after it was written: its record no longer matches it.")
        }
        return String(localized: "No record of a transcription matches this transcript.")
    }

    @discardableResult
    private func change(_ change: MeetingMarks.Change, of meeting: Meeting) -> String? {
        if let refusal = markRefusal(for: meeting) { return refusal }
        guard let identity = meeting.identity else { return nil }
        var state = marksStates[identity] ?? Marks(folder: meeting.directory)
        state.folder = meeting.directory
        state.change.add(change)
        state.edits += 1
        marksStates[identity] = state
        markFailures[identity] = nil
        writeMarks(of: identity)
        publishMarks()
        // A folder written at once has its answer already: a failure is the
        // caller's to show, as the row it was found by may be gone.
        return markFailures[identity]?.reason
    }

    /// Starts the next write of a folder's marks, unless one is under way.
    /// A folder the queue may move (by its own rule, `isInMeetingsRoot`) is
    /// written at once, here: the queue marks a move before it copies
    /// anything, on the main actor, so the write lands before the copy or is
    /// refused. Anything else (a network volume may hang) on the serial
    /// queue of its parent folder; a move of that folder waits for it. Every
    /// write checks the folder at its address is still this one.
    private func writeMarks(of identity: FolderIdentity) {
        guard var state = marksStates[identity], state.writing == nil, !state.change.isEmpty else { return }
        state.writing = state.edits
        marksStates[identity] = state
        let folder = state.folder
        let change = state.change
        let edits = state.edits
        let write = reader.writeMarks
        if queue.isInMeetingsRoot(folder) {
            switch Result(catching: { try write(change, folder, identity) }) {
            case .success(let marks): finishMarks(of: identity, edits: edits, written: marks)
            case .failure(let error): finishMarks(of: identity, edits: edits, failure: error.localizedDescription)
            }
            return
        }
        channel(folder.deletingLastPathComponent().path).queue.async { [weak self] in
            let result = Result(catching: { try write(change, folder, identity) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let marks): self?.finishMarks(of: identity, edits: edits, written: marks)
                    case .failure(let error):
                        self?.finishMarks(of: identity, edits: edits, failure: error.localizedDescription, late: true)
                    }
                }
            }
        }
    }

    /// A write has ended. What it wrote is what is on disk now, whatever is
    /// still to come; a failure drops only what no later change asks for
    /// again. A later change goes next, with every field the user set since
    /// the last write that took them all.
    /// `late`: the write ran off the main actor, and whoever asked for it has
    /// moved on; a failure no card shows becomes the window's notice.
    private func finishMarks(
        of identity: FolderIdentity, edits: Int, written: MeetingMarks? = nil, failure: String? = nil, late: Bool = false
    ) {
        guard var state = marksStates[identity] else { return }
        state.writing = nil
        let tookAll = state.edits == edits
        let onCard = isCardShown && selection.flatMap({ meeting(at: $0) })?.identity == identity
        if let failure, tookAll, late, !onCard {
            let shown = meeting(at: state.folder).map { MeetingText.title($0, marks: $0.marks.marks) } ?? state.folder.lastPathComponent
            markNotice = MarkNotice(lost: state.change, meeting: shown, reason: failure)
        }
        if let written {
            marksClock += 1
            state.confirmed = (written, marksClock)
            if tookAll { state.change = MeetingMarks.Change() }
            markFailures[identity] = nil
            show(written, of: identity)
        } else if let failure, tookAll {
            markFailures[identity] = MarkFailure(reason: failure, lost: state.change)
            state.change = MeetingMarks.Change()
            AppLog.error("meeting-library", "\(state.folder.lastPathComponent): marks not saved: \(failure)")
        }
        marksStates[identity] = state
        writeMarks(of: identity)
        forgetIdleMarks()
        publishMarks()
    }

    /// The snapshot takes the marks without reading the folder again.
    private func show(_ marks: MeetingMarks, of identity: FolderIdentity) {
        for listing in listingPaths {
            update(listing) { listing in
                for index in listing.meetings.indices where listing.meetings[index].identity == identity {
                    listing.meetings[index].marks = .read(marks)
                }
            }
        }
    }

    /// A read started before a write of marks succeeded does not take that
    /// write back: the meeting keeps what was written.
    private func withWrittenMarks(_ meetings: [Meeting], readAt clock: Int) -> [Meeting] {
        meetings.map { meeting in
            guard let confirmed = meeting.identity.flatMap({ marksStates[$0]?.confirmed }), confirmed.at > clock else {
                return meeting
            }
            var meeting = meeting
            meeting.marks = .read(confirmed.marks)
            return meeting
        }
    }

    /// Writers with nothing to write, once no read under way could take
    /// their last write back.
    private func forgetIdleMarks() {
        let reading = channels.values.contains { $0.busy }
        marksStates = marksStates.filter { _, state in state.isPending || (reading && state.confirmed != nil) }
    }

    /// One assignment, so quit and Sparkle never see a moment with nothing
    /// unsaved between two steps of one change.
    private func publishMarks() {
        let pending = Set(marksStates.filter { $0.value.isPending }.keys)
        if pending != pendingMarks { pendingMarks = pending }
    }

    // MARK: - Deletion

    enum RemovalKind: Sendable, Equatable { case audio, meeting }

    /// What goes when a deletion is confirmed: the audio files as they were
    /// read, or everything the folder held.
    enum RemovalTarget: Sendable, Equatable {
        case audio([MeetingStorage.FileFact])
        case meeting(MeetingStorage.Manifest)

        var bytes: Int64 {
            switch self {
            case .audio(let files): files.reduce(0) { $0 + $1.bytes }
            case .meeting(let manifest): manifest.files.reduce(0) { $0 + $1.bytes }
            }
        }
    }

    /// One meeting in a deletion, as the user is asked about it.
    struct RemovalItem: Identifiable, Equatable {
        let meeting: Meeting
        let identity: FolderIdentity
        let target: RemovalTarget
        var id: URL { meeting.directory }
        /// Files of the meeting's folder that are not the app's own: they go too.
        var others: [String] {
            guard case .meeting(let manifest) = target else { return [] }
            return manifest.files.map(\.name).filter {
                !MeetingStorage.isOwnFile($0, tracks: []) && !MeetingStorage.isSystemFile($0)
            }
        }
    }

    struct RemovalPlan: Identifiable, Equatable {
        let id = UUID()
        let kind: RemovalKind
        var items: [RemovalItem]
        /// Meetings that cannot go now, with the reason.
        var refused: [Refused]
        /// Asked again: these changed after they were confirmed.
        var changed = false

        struct Refused: Equatable {
            let meeting: Meeting
            let reason: String
        }

        var bytes: Int64 { items.reduce(0) { $0 + $1.target.bytes } }
    }

    /// What became of one meeting of a deletion.
    struct RemovalLine: Equatable, Identifiable {
        enum Outcome: Equatable {
            /// Everything asked for is in the Trash.
            case trashed
            /// The volume has no Trash: the folder is shown in Finder.
            case noTrash
            /// Stopped after `trashed` files: why, and what is left;
            /// `noTrash` when the volume turned out to have no Trash.
            case stopped(reason: String, trashed: [String], left: [String], noTrash: Bool = false)
            case refused(String)
        }

        let id = UUID()
        let folder: URL
        let kind: RemovalKind
        let outcome: Outcome
    }

    /// Why this meeting cannot have this deleted now, or nil: from what the
    /// window knows; checked again, with the disk, when it is carried out.
    func removalRefusal(for meeting: Meeting, kind: RemovalKind) -> String? {
        guard meeting.readable, let identity = meeting.identity else {
            return String(localized: "The meeting folder can’t be read.")
        }
        // Whatever it holds, a folder not named as a meeting's loses nothing.
        guard MeetingStorage.isMeetingFolderName(meeting.name) else {
            return String(localized: "This is not a meeting’s folder.")
        }
        if recorder.currentSession.map({ Self.canonical($0.directory).path }) == meeting.directory.path
            || recorder.currentSession?.identity == identity {
            return String(localized: "The meeting is being recorded.")
        }
        if recentlyStopped?.path == meeting.directory.path, meeting.state == nil {
            return String(localized: "Saving the recording…")
        }
        if let operation = queue.operation(on: identity) { return MeetingTranscriptionQueue.describe(operation.kind) }
        if queue.activeJob.map({ Self.canonical($0.folder).path }) == meeting.directory.path
            || queue.activeAddress?.identity == identity {
            return String(localized: "The meeting is being processed: \(queue.stepLabel ?? "")")
        }
        if queue.pending.contains(where: { job in
            job.transcribe && (job.identity == identity || Self.canonical(job.folder).path == meeting.directory.path)
        }) {
            return String(localized: "The meeting is waiting to be transcribed.")
        }
        if let reason = queue.untoldTranscription { return reason }
        if marksStates[identity]?.isPending == true { return String(localized: "Saving changes to this meeting…") }
        let listing = listingPath(of: meeting).flatMap(listing(at:))
        if listing?.state == .unavailable || listing?.notResponding == true {
            return String(localized: "The meetings folder isn’t available.")
        }
        switch kind {
        case .meeting:
            if settings.transcriptsFolderPath.map({ Self.canonical(URL(fileURLWithPath: $0, isDirectory: true)).path })
                == meeting.directory.path {
                return Self.copiesHere
            }
            if case .refused(let reason) = meeting.manifest { return reason }
        case .audio:
            guard meeting.state != nil else {
                return String(localized: "This recording broke off: only the whole meeting can be deleted.")
            }
            switch meeting.audio {
            case .unknown(let reason): return reason
            case .known(let files, _) where files.isEmpty: return String(localized: "The meeting has no audio.")
            case .known: break
            }
        }
        return nil
    }

    /// The sheet promises the transcripts' copies stay: a meeting folder
    /// that is itself the transcripts folder is not deleted whole.
    private nonisolated static var copiesHere: String {
        String(localized: "Transcripts are copied into this folder: delete it in Finder.")
    }

    /// The meetings asked about, as the window has them now.
    func removalPlan(for folders: [URL], kind: RemovalKind) -> RemovalPlan {
        var plan = RemovalPlan(kind: kind, items: [], refused: [])
        for folder in folders {
            guard let meeting = meeting(at: folder) else { continue }
            if let reason = removalRefusal(for: meeting, kind: kind) {
                plan.refused.append(.init(meeting: meeting, reason: reason))
            } else if let identity = meeting.identity, let target = Self.target(of: meeting, kind: kind) {
                plan.items.append(RemovalItem(meeting: meeting, identity: identity, target: target))
            }
        }
        return plan
    }

    private static func target(of meeting: Meeting, kind: RemovalKind) -> RemovalTarget? {
        switch (kind, meeting.audio, meeting.manifest) {
        case (.audio, .known(let files, _), _): .audio(files)
        case (.meeting, _, .read(let manifest)): .meeting(manifest)
        default: nil
        }
    }

    /// The deletion the user confirmed. Each meeting is read again on its
    /// folder's queue: the folder itself and exactly what was confirmed must
    /// still be there, or it is asked about again; then, on the main actor
    /// in one turn, checked and taken from the queue; then each file (or the
    /// folder) goes to the Trash, each call checked right before it.
    func remove(_ plan: RemovalPlan) {
        if plan.changed { removalRecheck = nil }
        for item in plan.items {
            removalsUnderWay += 1
            let folder = item.meeting.directory
            let kind = plan.kind
            channel(folder.deletingLastPathComponent().path).queue.async { [weak self] in
                let address = MeetingStorage.address(of: folder)
                let now: Result<RemovalTarget, ReadFailure> = switch kind {
                case .audio:
                    switch MeetingStorage.audio(in: folder, requiringMetadata: true) {
                    case .known(let files, _): .success(.audio(files))
                    case .unknown(let reason): .failure(ReadFailure(reason: reason))
                    }
                case .meeting:
                    switch MeetingStorage.manifest(of: folder) {
                    case .read(let manifest): .success(.meeting(manifest))
                    case .refused(let reason): .failure(ReadFailure(reason: reason))
                    }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.checked(item, kind: kind, address: address, now: now) }
                }
            }
        }
    }

    private struct ReadFailure: Error {
        let reason: String
    }

    private func checked(
        _ item: RemovalItem, kind: RemovalKind, address: MeetingStorage.Address?, now: Result<RemovalTarget, ReadFailure>
    ) {
        let folder = item.meeting.directory
        guard let address, let identity = address.identity else {
            report(RemovalLine(folder: folder, kind: kind, outcome: .refused(String(localized: "The meeting folder can’t be read."))))
            removalDone()
            return
        }
        let target: RemovalTarget
        switch now {
        case .failure(let failure):
            report(RemovalLine(folder: folder, kind: kind, outcome: .refused(failure.reason)))
            removalDone()
            return
        case .success(let read):
            target = read
        }
        guard identity == item.identity, Self.sameTarget(item.target, target) else {
            // Changed since the sheet: asked again with what is there now.
            removalRecheckItems.append(RemovalItem(meeting: item.meeting, identity: identity, target: target))
            removalDone()
            return
        }
        let current = meeting(at: folder) ?? item.meeting
        if let reason = removalRefusal(for: current, kind: kind) {
            report(RemovalLine(folder: folder, kind: kind, outcome: .refused(reason)))
            removalDone()
            return
        }
        let operation: Int
        switch queue.reserve(address, folder: folder) {
        case .failure(let refusal):
            report(RemovalLine(folder: folder, kind: kind, outcome: .refused(refusal.reason)))
            removalDone()
            return
        case .success(let id):
            operation = id
        }
        let removal = queue.removal
        // The transcripts folder as the settings name it when the call is
        // about to go, after every wait.
        let copies: @Sendable () -> String? = { [settings] in
            DispatchQueue.main.sync { MainActor.assumeIsolated { settings.transcriptsFolderPath } }
        }
        let reach = reader.copiesFolder
        // What the menu points to, by any address: matched to this folder
        // before it goes, on the folder's queue, so the menu forgets it
        // whichever way it was reached.
        let links = [recorder.lastRecordingLocation, recorder.warnedRecordingLocation, queue.lastMeeting].compactMap { $0 }
        channel(folder.deletingLastPathComponent().path).queue.async { [weak self] in
            let pointing = links.filter { MeetingStorage.address(of: $0)?.isSameFolder(as: address) == true }
            let outcome = Self.carryOut(item.target, in: folder, identity: identity, removal: removal, copies: copies, reach: reach)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.carriedOut(folder, kind: kind, operation: operation, outcome: outcome, pointing: pointing)
                }
            }
        }
    }

    /// The transcripts folder as the setting names it now, resolved (a
    /// network volume may take long to say): why the folder must not go as
    /// it, or nil, and the setting it was resolved for. A folder that cannot
    /// be told refuses.
    nonisolated static func copiesCheck(
        _ identity: FolderIdentity, copies: @Sendable () -> String?, reach: @Sendable (URL) -> FolderIdentity.Reach
    ) -> (refusal: String?, setting: String?) {
        guard let path = copies() else { return (nil, nil) }
        switch reach(URL(fileURLWithPath: path, isDirectory: true)) {
        case .none: return (nil, path)
        case .folder(let found): return (found == identity ? copiesHere : nil, path)
        case .unknown(let reason): return (String(localized: "The transcripts folder can’t be told apart now: \(reason)"), path)
        }
    }

    private nonisolated static var copiesSettingChanged: String {
        String(localized: "The transcripts folder setting changed while it was checked: try again.")
    }

    /// The same folder holding what was confirmed; Finder's own files may change.
    private static func sameTarget(_ confirmed: RemovalTarget, _ now: RemovalTarget) -> Bool {
        switch (confirmed, now) {
        case (.audio(let then), .audio(let now)): Set(then.map(\.name)) == Set(now.map(\.name)) && then.allSatisfy(now.contains)
        case (.meeting(let then), .meeting(let now)): then.matches(now)
        default: false
        }
    }

    /// Off the main actor, on the folder's queue: one call at a time, each
    /// checked right before it. Stops at the first that does not go.
    private nonisolated static func carryOut(
        _ target: RemovalTarget, in folder: URL, identity: FolderIdentity, removal: MeetingStorage.Removal,
        copies: @escaping @Sendable () -> String?, reach: @escaping @Sendable (URL) -> FolderIdentity.Reach
    ) -> RemovalLine.Outcome {
        switch target {
        case .meeting(let manifest):
            // The transcripts folder through any address, a link included:
            // the sheet promised its copies stay. Resolved first; then the
            // meeting is checked for the last time; after that only whether
            // the setting is still the one resolved, which waits for no
            // disk. Changed, the whole admission goes again.
            let changed = copiesSettingChanged
            for _ in 0..<3 {
                let (refusal, setting) = copiesCheck(identity, copies: copies, reach: reach)
                if let refusal { return .refused(refusal) }
                let unchanged: @Sendable () -> String? = { copies() == setting ? nil : changed }
                switch removal.perform(.folder(manifest), in: folder, folderIdentity: identity, forGood: false, stillWanted: unchanged) {
                case .success: return .trashed
                case .failure(.noTrash): return .noTrash
                case .failure(.stale(let reason)) where reason == changed: continue
                case .failure(.stale(let reason)): return .refused(reason)
                case .failure(let failure):
                    return .stopped(reason: failure.localizedDescription, trashed: [], left: manifest.files.map(\.name))
                }
            }
            return .refused(changed)
        case .audio(let files):
            var trashed: [String] = []
            for (index, file) in files.enumerated() {
                switch removal.perform(.file(file), in: folder, folderIdentity: identity, forGood: false) {
                case .success:
                    trashed.append(file.name)
                case .failure(.noTrash) where trashed.isEmpty:
                    return .noTrash
                case .failure(let failure):
                    return .stopped(
                        reason: failure.localizedDescription, trashed: trashed, left: files[index...].map(\.name),
                        noTrash: failure == .noTrash
                    )
                }
            }
            return .trashed
        }
    }

    private func carriedOut(
        _ folder: URL, kind: RemovalKind, operation: Int, outcome: RemovalLine.Outcome, pointing: [URL]
    ) {
        queue.endOperations([operation])
        report(RemovalLine(folder: folder, kind: kind, outcome: outcome))
        // No Trash, at the first file or after some went: the rest is the
        // user's to delete, in Finder.
        if case .stopped(_, _, _, true) = outcome { reveal(folder) }
        switch outcome {
        case .noTrash:
            reveal(folder)
        case .trashed, .stopped:
            let whole = kind == .meeting && outcome == .trashed
            for link in [folder] + pointing {
                recorder.forget(link, wholeMeeting: whole)
                queue.forget(link, wholeMeeting: whole)
            }
            if whole {
                selectedFolders.remove(folder)
                if selection == folder { select(nil as URL?) }
            }
        case .refused:
            break
        }
        removalDone()
    }

    private func report(_ line: RemovalLine) {
        removalReport.append(line)
        AppLog.info("meeting-library", "\(line.folder.lastPathComponent): deletion \(line.kind): \(line.outcome)")
    }

    /// Once every meeting of a confirmation is settled: the disk is read
    /// again, and what changed meanwhile is asked about anew.
    private func removalDone() {
        removalsUnderWay -= 1
        guard removalsUnderWay == 0 else { return }
        if !removalRecheckItems.isEmpty, let kind = removalRecheckItems.first.map({ Self.kind(of: $0.target) }) {
            removalRecheck = RemovalPlan(kind: kind, items: removalRecheckItems, refused: [], changed: true)
            removalRecheckItems = []
        }
        refresh()
    }

    private static func kind(of target: RemovalTarget) -> RemovalKind {
        if case .audio = target { .audio } else { .meeting }
    }

    func dismissRemovalReport() {
        removalReport = []
    }

    func dismissRemovalRecheck() {
        removalRecheck = nil
    }

    /// A change of a meeting's marks not on disk yet; a transcript being
    /// written to the file the user chose.
    var quitLosses: Set<AppDelegate.QuitLoss> {
        var losses: Set<AppDelegate.QuitLoss> = pendingMarks.isEmpty ? [] : [.unsavedMeetingMark]
        if exporting?.writing == true { losses.insert(.transcriptFile) }
        return losses
    }

    // MARK: - Saving as a file

    /// Saves the text on the card as a file of `format`, as it is shown,
    /// the user's names included, taken now: whatever is selected or
    /// changed later, this text, this meeting. The panel comes next, on
    /// `owner`, the window it was asked from, then the write on the saving
    /// queue; closing the window once a place is chosen stops neither.
    /// Returns why it does not start, or nil.
    @discardableResult
    func export(_ meeting: Meeting, as format: MeetingTranscript.Format, from owner: NSWindow?) -> String? {
        guard exporting == nil else { return String(localized: "A transcript is being saved already.") }
        guard let version, let shown = shownTranscript(of: meeting) else { return String(localized: "The transcript isn’t read yet.") }
        guard let content = shown.exported(as: format) else {
            return subtitlesRefusal(for: meeting) ?? String(localized: "No record of a transcription matches this transcript.")
        }
        let name = MeetingTranscript.exportName(folder: meeting.name, version: version, format: format)
        let job = Export(meeting: meeting.directory, identity: meeting.identity, version: version, format: format, file: name)
        exporting = job
        exportOutcome = nil
        exportNotice = nil
        AppLog.info("meeting-library", "\(meeting.name): saving \(name)")
        let destination = saving.destination
        Task { [weak self] in
            let url = await destination(name, format.type, owner)
            guard let self else { return }
            guard let url else {
                AppLog.info("meeting-library", "\(meeting.name): \(name) not saved: no place chosen")
                exporting = nil
                return
            }
            write(content, to: url, for: job)
        }
        return nil
    }

    func dismissExportNotice() {
        exportNotice = nil
    }

    private func write(_ content: String, to url: URL, for asked: Export) {
        var job = asked
        job.file = url.lastPathComponent
        job.writing = true
        exporting = job
        let written = job
        let write = saving.write
        exportQueue.async { [weak self] in
            let failure: String?
            if let refusal = Self.destinationRefusal(url, meeting: written.identity) {
                failure = refusal
            } else {
                do {
                    try write(Data(content.utf8), url)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exported(written, to: url, failure: failure) }
            }
        }
    }

    /// The card says it while the meeting and version saved are on it;
    /// otherwise the window says it above the list.
    private func exported(_ job: Export, to url: URL, failure: String?) {
        exporting = nil
        if let failure {
            AppLog.error("meeting-library", "\(job.meeting.lastPathComponent): \(url.path) not saved: \(failure)")
        } else {
            AppLog.info("meeting-library", "\(job.meeting.lastPathComponent): saved \(url.path)")
        }
        let outcome = ExportOutcome(meeting: job.meeting, identity: job.identity, version: job.version, file: job.file, failure: failure)
        if isCardShown, selection == job.meeting, version == job.version, meeting(at: job.meeting)?.identity == job.identity {
            exportOutcome = outcome
        } else {
            exportNotice = outcome
        }
    }

    /// A file saved in a meeting's folder, its own or another's, could take
    /// the place of a transcript, the marks or the audio, which are never
    /// written over: refused before anything is written, by the folder's
    /// name and, for the meeting's own, by the folder itself. The path's
    /// links are followed first, so no address of the folder passes.
    nonisolated static func destinationRefusal(_ url: URL, meeting identity: FolderIdentity?) -> String? {
        let components = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for count in stride(from: components.count, to: 1, by: -1) {
            let folder = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count))), isDirectory: true)
            if MeetingStorage.isMeetingFolderName(folder.lastPathComponent) || identity != nil && FolderIdentity.of(folder) == identity {
                return String(localized: "Choose a folder outside the meetings’ own folders: the files in them are the app’s.")
            }
        }
        return nil
    }

    // MARK: - Search

    /// What the search of all meetings found in one: in how many places of
    /// its newest transcript's lines, and whether in its name.
    struct SearchMatch: Equatable, Sendable {
        let count: Int
        let inTitle: Bool
    }

    /// What the search could not vouch for: a meeting not found is a
    /// meeting whose text was read, or one with no text.
    struct SearchState: Equatable {
        /// Transcripts not read yet.
        var waiting = 0
        /// The meetings whose transcript could not be read.
        var failed: [String] = []
        /// The meetings whose folder could not be read: what they hold is
        /// not known.
        var unreadable: [String] = []
        /// Folders not read, away or failing: how many meetings they hold
        /// is not known.
        var unknownFolders: [String] = []
        /// Folders being read again: what they hold now is not known yet;
        /// the matches shown for them are the last known.
        var updating = false
        /// The matches are being counted.
        var counting = false
        var settled: Bool {
            waiting == 0 && failed.isEmpty && unreadable.isEmpty && unknownFolders.isEmpty && !updating && !counting
        }
    }

    /// The search field's text; in memory, and gone when the window closes.
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            // The last query's matches are not this one's.
            searchMatches = [:]
            searchChanged()
        }
    }
    /// By the meeting's folder; empty while there is no query.
    @Published private(set) var searchMatches: [URL: SearchMatch] = [:]
    @Published private(set) var searchState = SearchState()
    /// The meeting whose text takes the focus at its first match: Return in
    /// the search field. Its card takes it once, and says so.
    @Published private(set) var searchFocus: URL?

    /// A transcript read for the search: the version it is, the folded text
    /// and the lines' words in it. Immutable; read off the main actor.
    private final class SearchText: @unchecked Sendable {
        let path: String
        let version: String
        let modified: Date?
        let folded: NSString
        let searchable: [NSRange]

        init(path: String, version: String, modified: Date?, layout: MeetingTranscript.Layout) {
            self.path = path
            self.version = version
            self.modified = modified
            folded = MeetingSearch.fold(layout.string) as NSString
            searchable = layout.searchable
        }

        func fits(_ meeting: Meeting) -> Bool {
            path == meeting.directory.path && version == meeting.versions.last?.name && modified == meeting.versions.last?.modified
        }
    }

    /// By the folder itself: a folder put at a meeting's address is another text.
    private var searchTexts: [FolderIdentity: SearchText] = [:]
    /// The version that could not be read, and why.
    private var searchFailures: [FolderIdentity: (version: String, reason: String)] = [:]
    /// Numbers the counts of matches; only the latest one's answer is taken.
    private(set) var searchCount = 0
    /// Told each time a count of matches answers, by its number, and whether
    /// its answer was taken: a test waits for the very answer that must be
    /// dropped, not for any.
    var countAnswered: @MainActor (_ count: Int, _ taken: Bool) -> Void = { _, _ in }
    private static let searchBatch = 20
    /// Raised by each request to read a folder and by each answer: a search
    /// read started under an earlier one is dropped.
    private var listingRevisions: [String: Int] = [:]

    private var searchedMeetings: [Meeting] { meetings + outsideMeetings }

    /// Read for the latest request: what the search counts on.
    private func isFresh(_ meeting: Meeting) -> Bool {
        listingPath(of: meeting).flatMap(listing(at:)).map { $0.state == .read && $0.fresh } ?? false
    }

    /// The newest transcript of a meeting, unless read already.
    private func needsText(_ meeting: Meeting) -> Bool {
        guard meeting.readable, let identity = meeting.identity, let newest = meeting.versions.last else { return false }
        if searchTexts[identity]?.fits(meeting) == true { return false }
        return searchFailures[identity]?.version != newest.name
    }

    /// Return in the search field: the first meeting found, unless the one
    /// on the card is one, and its text at the first match.
    func searchSubmitted() {
        guard !searchQuery.isEmpty else { return }
        let found = searchedMeetings.filter { searchMatches[$0.directory] != nil }.map(\.directory)
        if selection.map(found.contains) != true {
            guard let first = found.first else { return }
            select(first)
        }
        searchFocus = selection
    }

    /// The card's text took the focus.
    func searchFocused() {
        searchFocus = nil
    }

    /// "Try Again" for transcripts and meeting folders that could not be
    /// read: the folders are read again, then what is still unread.
    func retrySearch() {
        searchFailures = [:]
        refresh()
    }

    /// Asks each folder read for the transcripts not read yet, and counts.
    private func searchChanged() {
        guard isWindowOpen, !searchQuery.isEmpty else {
            searchCount += 1
            if !searchMatches.isEmpty { searchMatches = [:] }
            if searchState != SearchState() { searchState = SearchState() }
            return
        }
        for path in listingPaths where listing(at: path).map({ $0.state == .read && $0.fresh }) == true {
            if listing(at: path)?.meetings.contains(where: needsText) == true {
                channel(path).searchWanted = true
                runNext(path)
            }
        }
        countMatches()
    }

    /// One batch of a folder's transcripts, on its queue; then the list and
    /// the card go first again. Each comes back for the meeting, the folder
    /// itself and the version it was read for, or is dropped.
    private func startSearch(_ listing: Listing, on path: String, _ channel: Channel) {
        guard !searchQuery.isEmpty, listing.state == .read, listing.fresh else { return }
        let batch = listing.meetings.filter(needsText).prefix(Self.searchBatch).compactMap { meeting -> SearchItem? in
            guard let identity = meeting.identity, let newest = meeting.versions.last else { return nil }
            return SearchItem(folder: meeting.directory, identity: identity, version: newest.name, modified: newest.modified)
        }
        guard !batch.isEmpty else { return }
        channel.busy = true
        channel.token += 1
        let window = windowGeneration
        let revision = listingRevisions[path, default: 0]
        let reader = self.reader
        channel.queue.async { [weak self] in
            let read = batch.map { item -> (SearchItem, Result<SearchText, ReadFailure>) in
                guard FolderIdentity.of(item.folder) == item.identity else {
                    return (item, .failure(ReadFailure(reason: String(localized: "Another folder is at the meeting’s address now."))))
                }
                do {
                    let layout = MeetingTranscript.parse(try reader.text(item.folder.appendingPathComponent(item.version))).layout
                    return (item, .success(SearchText(path: item.folder.path, version: item.version, modified: item.modified, layout: layout)))
                } catch {
                    return (item, .failure(ReadFailure(reason: error.localizedDescription)))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishSearch(path, window: window, revision: revision, read: read) }
            }
        }
    }

    private struct SearchItem: Sendable {
        let folder: URL
        let identity: FolderIdentity
        let version: String
        let modified: Date?
    }

    private func finishSearch(
        _ path: String, window: Int, revision: Int, read: [(SearchItem, Result<SearchText, ReadFailure>)]
    ) {
        channels[path]?.busy = false
        // The folder was asked for again meanwhile: what was read may be of
        // what is no longer there; once its list is in, it is read anew.
        guard isWindowOpen, window == windowGeneration, listingRevisions[path, default: 0] == revision else {
            runNext(path)
            return
        }
        for (item, result) in read {
            // The meeting as the window has it now: the same folder, by
            // itself, and the same newest version.
            guard let meeting = meeting(at: item.folder), meeting.identity == item.identity,
                  meeting.versions.last?.name == item.version, meeting.versions.last?.modified == item.modified else { continue }
            switch result {
            case .success(let text):
                searchTexts[item.identity] = text
                searchFailures[item.identity] = nil
            case .failure(let failure):
                searchFailures[item.identity] = (item.version, failure.reason)
            }
        }
        if !searchQuery.isEmpty, listing(at: path)?.meetings.contains(where: needsText) == true {
            channels[path]?.searchWanted = true
        }
        countMatches()
        runNext(path)
    }

    /// What the search cannot vouch for now, from the listings as they are.
    private func searchStateNow(counting: Bool) -> SearchState {
        var state = SearchState()
        let counted = searchedMeetings.filter(isFresh)
        state.waiting = counted.filter(needsText).count
        state.failed = counted.compactMap { meeting in
            guard let identity = meeting.identity, let newest = meeting.versions.last,
                  searchFailures[identity]?.version == newest.name else { return nil }
            return MeetingText.title(meeting, marks: marks(of: meeting))
        }
        state.unreadable = counted.filter { !$0.readable || $0.identity == nil }.map { MeetingText.title($0, marks: marks(of: $0)) }
        let listings = [local] + [chosen].compactMap { $0 } + outside
        state.unknownFolders = listings.filter { $0.state != .read || $0.notResponding }.map(\.folder.path)
        state.updating = listings.contains { $0.state == .read && !$0.fresh && !$0.notResponding }
        state.counting = counting
        return state
    }

    /// The folders were asked for again: a count under way took texts they
    /// may no longer hold, so it is dropped and the matches counted again,
    /// the folders being read keeping their last known ones. The search
    /// says so until they answer.
    private func searchInvalidated() {
        guard isWindowOpen, !searchQuery.isEmpty else { return }
        countMatches()
    }

    /// Off the main actor, on the texts of folders read for the latest
    /// request; a folder being read again keeps its last known matches. An
    /// answer for an older query, older texts or a request made since is
    /// dropped; until the count is in, nothing is settled.
    private func countMatches() {
        searchCount += 1
        let count = searchCount
        let query = searchQuery
        let fresh = searchedMeetings.filter(isFresh)
        let kept = searchMatches.filter { match in !fresh.contains { $0.directory == match.key } }
        let items = fresh.map { meeting -> (URL, String, SearchText?) in
            let text = meeting.identity.flatMap { searchTexts[$0] }.flatMap { $0.fits(meeting) ? $0 : nil }
            return (meeting.directory, MeetingText.title(meeting, marks: marks(of: meeting)), text)
        }
        let state = searchStateNow(counting: true)
        if state != searchState { searchState = state }
        Task.detached(priority: .userInitiated) { [weak self] in
            var found = kept
            for (folder, title, text) in items {
                let inText = text.map { MeetingSearch.ranges(of: query, inFolded: $0.folded, within: $0.searchable).count } ?? 0
                let inTitle = MeetingSearch.matches(query, title)
                if inText > 0 || inTitle { found[folder] = SearchMatch(count: inText, inTitle: inTitle) }
            }
            await MainActor.run {
                guard let self else { return }
                let taken = count == self.searchCount && query == self.searchQuery
                if taken {
                    if found != self.searchMatches { self.searchMatches = found }
                    self.searchState.counting = false
                }
                self.countAnswered(count, taken)
            }
        }
    }

    // MARK: - Reading

    /// One folder's serial queue and what waits for it.
    private final class Channel {
        let queue: DispatchQueue
        var busy = false
        var token = 0
        var listWanted = false
        var textWanted: TextRequest?
        /// Transcripts to read for the search, after the card's and the list's.
        var searchWanted = false

        init(path: String) {
            queue = DispatchQueue(label: "meeting-library \(path)", qos: .utility)
        }
    }

    private struct TextRequest {
        let meeting: URL
        let version: String
        let token: Int
        /// The record of the attempt that wrote the version, for its lines' times.
        let attempt: MeetingAttempt?
    }

    private var listingPaths: [String] {
        [local.folder.path] + [chosen?.folder.path].compactMap { $0 } + outside.map(\.folder.path)
    }

    private func listing(at path: String) -> Listing? {
        if local.folder.path == path { return local }
        if chosen?.folder.path == path { return chosen }
        return outside.first { $0.folder.path == path }
    }

    private func update(_ path: String, _ change: (inout Listing) -> Void) {
        if local.folder.path == path {
            change(&local)
        } else if chosen?.folder.path == path {
            change(&chosen!)
        } else if let index = outside.firstIndex(where: { $0.folder.path == path }) {
            change(&outside[index])
        }
    }

    private func listingPath(of meeting: Meeting) -> String? {
        switch meeting.place {
        case .local: local.folder.path
        case .chosen: chosen?.folder.path
        case .outside: meeting.directory.path
        }
    }

    private func isInRoots(_ folder: URL) -> Bool {
        let parent = folder.deletingLastPathComponent().standardizedFileURL.path
        return parent == local.folder.path || parent == chosenFolder?.path
    }

    /// The chosen meetings folder by its path alone: it may be a dead
    /// network volume, which only the reads touch.
    private var chosenFolder: URL? {
        settings.meetingsFolderPath.map { Self.canonical(URL(fileURLWithPath: $0, isDirectory: true)) }
            .flatMap { $0.path == local.folder.path ? nil : $0 }
    }

    private func followChosenFolder() {
        guard chosenFolder?.path != chosen?.folder.path else { return }
        chosen = chosenFolder.map { Listing(folder: $0) }
    }

    private func channel(_ path: String) -> Channel {
        if let channel = channels[path] { return channel }
        let channel = Channel(path: path)
        channels[path] = channel
        return channel
    }

    private func requestList(_ path: String) {
        channel(path).listWanted = true
        runNext(path)
    }

    private func runNext(_ path: String) {
        let channel = channel(path)
        guard !channel.busy else { return }
        // Reads only while the window is open; what was asked for meanwhile
        // waits for it to open again, when everything is read anyway. Marks
        // are written on the same serial queue, by their own writer.
        if !isWindowOpen {
            return
        } else if let request = channel.textWanted {
            channel.textWanted = nil
            startText(request, on: path, channel)
        } else if channel.listWanted, let listing = listing(at: path) {
            channel.listWanted = false
            startList(listing, on: path, channel)
        } else if channel.searchWanted, let listing = listing(at: path) {
            channel.searchWanted = false
            startSearch(listing, on: path, channel)
        }
    }

    private func startList(_ listing: Listing, on path: String, _ channel: Channel) {
        channel.busy = true
        channel.token += 1
        let token = channel.token
        let generation = (request: requestGeneration, window: windowGeneration, marks: marksClock)
        readsStarted += 1
        let serial = readsStarted
        update(path) { $0.reading = true }
        let reader = self.reader
        let folder = listing.folder
        let place: Place = path == local.folder.path ? .local : path == chosen?.folder.path ? .chosen : .outside
        channel.queue.async { [weak self] in
            let result = place == .outside ? reader.meeting(folder) : reader.root(folder, place)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishList(path, generation: generation, serial: serial, result: result)
                }
            }
        }
        watchForAnswer(path, token: token)
    }

    /// `generation.marks`: the marks writes that had succeeded when the read
    /// began; a later one is not taken back by what the read found.
    private func finishList(
        _ path: String, generation: (request: Int, window: Int, marks: Int), serial: Int, result: ReadResult
    ) {
        channels[path]?.busy = false
        listingRevisions[path, default: 0] += 1
        if path == local.folder.path, serial > readsAtStop { recentlyStopped = nil }
        let current = isWindowOpen && generation.request == requestGeneration && generation.window == windowGeneration
        update(path) { listing in
            listing.reading = false
            listing.notResponding = false
            switch result {
            case .meetings(let meetings):
                listing.state = .read
                listing.meetings = withWrittenMarks(meetings, readAt: generation.marks)
            case .unavailable:
                listing.state = .unavailable
                listing.meetings = []
            case .failed(let reason):
                listing.state = .failed(reason)
            }
            listing.fresh = current
        }
        forgetIdleMarks()
        snapshotChanged(freshFrom: current ? path : nil)
        if !searchQuery.isEmpty { channels[path]?.searchWanted = true }
        searchChanged()
        runNext(path)
    }

    /// Said only while that very read is still under way.
    private func watchForAnswer(_ path: String, token: Int) {
        let delay = notRespondingAfter
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let channel = self.channels[path], channel.busy, channel.token == token else { return }
            self.update(path) { $0.notResponding = true }
        }
    }

    /// `again`: the same version read once more; what is shown stays until
    /// the answer, so a refresh neither blanks the text nor moves its scroll.
    private func loadText(again: Bool = false) {
        textToken += 1
        guard let selection, let version, let meeting = meeting(at: selection),
              meeting.versions.contains(where: { $0.name == version }),
              let path = listingPath(of: meeting) else {
            text = .none
            return
        }
        if !again || text == .none { text = .loading }
        let attempt = meeting.versions.first { $0.name == version }?.attempt
        channel(path).textWanted = TextRequest(meeting: selection, version: version, token: textToken, attempt: attempt)
        runNext(path)
    }

    private func startText(_ request: TextRequest, on path: String, _ channel: Channel) {
        channel.busy = true
        channel.token += 1
        let token = channel.token
        let reader = self.reader
        let file = request.meeting.appendingPathComponent(request.version)
        channel.queue.async { [weak self] in
            let text: Text
            do {
                text = .loaded(MeetingTranscript.parse(try reader.text(file)).timed(by: request.attempt))
            } catch {
                text = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishText(request, on: path, text: text) }
            }
        }
        watchForAnswer(path, token: token)
    }

    /// Shown only for the meeting and version it was read for, and only if
    /// no newer text was asked for since.
    private func finishText(_ request: TextRequest, on path: String, text: Text) {
        channels[path]?.busy = false
        update(path) { $0.notResponding = false }
        if request.token == textToken, request.meeting == selection, request.version == version {
            self.text = text
        }
        runNext(path)
    }

    /// After a read: the selected meeting's version (the newest, unless one
    /// was picked by hand and is still there), and the saved session's metadata.
    /// `freshFrom`: the folder a fresh read came from. The selected meeting's
    /// text is read again with it: the file may have changed outside, or an
    /// earlier read of it failed.
    private func snapshotChanged(freshFrom path: String? = nil) {
        defer { syncPlayer() }
        if let stopped = recentlyStopped, meeting(at: stopped)?.state != nil { recentlyStopped = nil }
        guard let selection, let meeting = meeting(at: selection) else { return }
        let names = meeting.versions.map(\.name)
        let wanted = versionPicked && version.map(names.contains) == true ? version : names.last
        if wanted != version {
            version = wanted
            versionPicked = versionPicked && wanted != nil
            player.pause()
            loadText()
        } else if text == .none, version != nil {
            loadText()
        } else if let path, listingPath(of: meeting) == path, version != nil {
            loadText(again: true)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func sessionChanged(to session: MeetingRecorder.Session?) {
        let directory = session.map { Self.canonical($0.directory) }
        if directory == nil, let ended = liveSession {
            recentlyStopped = ended
            readsAtStop = readsStarted
        }
        liveSession = directory
        if isWindowOpen { scheduleRefresh() }
    }

    /// The queue moved a meeting: the selection follows it.
    /// The queue moved a meeting: the selection follows it, and its text is
    /// asked for at the new address, as an answer for the old one is dropped.
    /// `moves` is the map as sent: `@Published` sends before it changes.
    private func follow(_ moves: [String: URL]) {
        if let selection, let place = moves[selection.path],
           !FileManager.default.fileExists(atPath: selection.path) {
            self.selection = Self.canonical(place)
            loadText()
            syncPlayer()
        }
        selectedFolders = Set(selectedFolders.map { folder in
            moves[folder.path].flatMap { FileManager.default.fileExists(atPath: folder.path) ? nil : Self.canonical($0) } ?? folder
        })
        scheduleRefresh()
    }

    // MARK: - The disk

    /// One spelling per folder, so a meeting from the list, the menu and the
    /// queue is the same value: standardized, with its trailing slash.
    nonisolated static func canonical(_ folder: URL) -> URL {
        Archive.canonical(folder)
    }

    nonisolated static func readRoot(_ root: URL, place: Place) -> ReadResult {
        if place == .chosen, !MeetingStorage.isAvailable(root) { return .unavailable }
        do {
            return .meetings(try MeetingStorage.meetingFolders(in: root).map { readMeeting($0, place: place) })
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func readOutside(_ folder: URL) -> ReadResult {
        guard MeetingStorage.isAvailable(folder) else { return .unavailable }
        return .meetings([readMeeting(folder, place: .outside)])
    }

    /// Everything a row and a card show. The files alone, read without
    /// `AVFoundation` or a byte count, are `Archive.MeetingFolder.read`
    /// (`Sources/Archive/Meetings.swift`), shared with the helper; this adds
    /// what only the window needs (the folder's size, its audio, what the
    /// Trash and the audio rule would do with it, what the player would
    /// play). `metadata.json` is read loosely and without filtering its
    /// state: July recordings have no `endedAt`, and a folder without it is
    /// still a meeting.
    nonisolated static func readMeeting(_ folder: URL, place: Place) -> Meeting {
        let info = Archive.MeetingFolder.read(folder, links: .follow)
        let directory = info.directory
        let size = MeetingStorage.folderSize(of: directory)

        return Meeting(
            directory: directory,
            place: place,
            startedAt: info.startedAt,
            duration: info.duration,
            state: info.state,
            issues: info.issues,
            trigger: info.trigger,
            bytes: size.complete ? size.bytes : nil,
            versions: info.versions,
            lastAttempt: info.lastAttempt,
            otherFiles: (info.names ?? []).filter {
                !MeetingStorage.isOwnFile($0, tracks: info.tracks) && !MeetingStorage.isSystemFile($0)
            }.sorted(),
            hasTracks: !Set(info.names ?? []).isDisjoint(with: MeetingStorage.defaultTrackNames.union(info.tracks)),
            readable: info.names != nil,
            marks: info.marks,
            identity: info.identity,
            audio: MeetingStorage.audio(in: directory),
            manifest: MeetingStorage.manifest(of: directory),
            retention: MeetingStorage.audioRetention(of: directory),
            playback: MeetingStorage.playback(in: directory)
        )
    }

    // MARK: - Labels

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let meetings: [Meeting]
    }

    /// Today, Yesterday, This Week, then one group a month, newest first.
    /// `meetings` come newest first.
    nonisolated static func groups(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        for meeting in meetings {
            let date = meeting.startedAt ?? .distantPast
            let key: String
            let title: String
            if calendar.isDate(date, inSameDayAs: now) || date > now {
                (key, title) = ("today", String(localized: "Today"))
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(date, inSameDayAs: yesterday) {
                (key, title) = ("yesterday", String(localized: "Yesterday"))
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                (key, title) = ("week", String(localized: "This Week"))
            } else {
                let components = calendar.dateComponents([.year, .month], from: date)
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
                // A month on its own is named as itself, not "of October".
                var style = Date.FormatStyle.dateTime.month(.wide).year()
                style.calendar = calendar
                style.timeZone = calendar.timeZone
                let month = date.formatted(style)
                title = month.prefix(1).uppercased() + month.dropFirst()
            }
            if groups.last?.id == key {
                groups[groups.count - 1] = Group(id: key, title: title, meetings: groups[groups.count - 1].meetings + [meeting])
            } else {
                groups.append(Group(id: key, title: title, meetings: [meeting]))
            }
        }
        return groups
    }

    /// The engine, language and time of the attempt that wrote it; a
    /// transcript from before attempt records only has its number and date.
    nonisolated static func label(of version: Version) -> String {
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        guard let attempt = version.attempt else {
            let date = version.modified.map { " · " + $0.formatted(format) } ?? ""
            return String(localized: "Transcript \(version.number)") + date
        }
        let engines = attempt.engines.map { DictationEngine(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
        let languages = attempt.languages.map {
            $0 == "auto" ? String(localized: "Auto") : DictationEngine.languageName($0)
        }.joined(separator: ", ")
        return [engines, languages, (attempt.endedAt ?? attempt.startedAt).formatted(format)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The app's own concern for `MeetingTranscript`: exporting it as a file. The
/// type itself, its parsing and its layout (`Sources/Archive/MeetingText.swift`)
/// are shared with the helper; `UTType` is not.
extension MeetingTranscript {
    /// A file the transcript is saved as.
    enum Format: String, CaseIterable, Sendable {
        case markdown, text, subtitles

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .text: "txt"
            case .subtitles: "srt"
            }
        }

        var type: UTType { UTType(filenameExtension: fileExtension) ?? .plainText }
    }

    /// The text as a file of `format`, as the window shows it, the user's
    /// names included; nil for subtitles without the record's exact spans.
    func exported(as format: Format) -> String? {
        switch format {
        case .text:
            // What Copy Text copies, ending in one line break.
            var text = layout.string
            while text.hasSuffix("\n") { text.removeLast() }
            return text + "\n"
        case .markdown:
            return markdown
        case .subtitles:
            return subtitles
        }
    }

    /// The file itself, byte for byte, unless the user's names took the
    /// place of the labels: then its own header bytes, a line saying who is
    /// who, and every line with the name in its label and nothing else
    /// changed, so it reads back as the same lines.
    private var markdown: String {
        guard let namesNote, let lines else { return raw }
        var rows = raw.components(separatedBy: "\n")
        guard let rule = rows.firstIndex(of: "---") else { return raw }
        var index = 0
        for row in (rule + 1)..<rows.count where !rows[row].trimmingCharacters(in: .whitespaces).isEmpty {
            guard index < lines.count else { return raw }
            let line = lines[index]
            rows[row] = "[\(line.timecode)] **\(line.speaker):** \(line.text)"
            index += 1
        }
        let header = rule == 0 ? "" : rows[..<rule].joined(separator: "\n") + "\n"
        return header + namesNote + "\n\n" + rows[rule...].joined(separator: "\n")
    }

    /// SubRip: each line's exact span from the record, its label or name
    /// and its words; no header. Only with times a subtitle can hold: a
    /// record changed by hand may say anything, and a time past what an
    /// integer of milliseconds holds would stop the app.
    private var subtitles: String? {
        guard case .exact(let spans) = timing, let lines, lines.count == spans.count,
              spans.allSatisfy({ Self.isSubtitleTime($0.start) && Self.isSubtitleTime($0.end) }) else { return nil }
        return zip(lines, spans).enumerated().map { index, pair in
            let (line, span) = pair
            return "\(index + 1)\n\(Self.subtitleTime(span.start)) --> \(Self.subtitleTime(max(span.end, span.start)))\n"
                + "\(line.speaker): \(line.text)\n"
        }.joined(separator: "\n")
    }

    /// Not negative, and under 100 hours: no recording is longer.
    static func isSubtitleTime(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds < 360_000
    }

    /// `HH:MM:SS,mmm`.
    static func subtitleTime(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000
        )
    }

    /// `2026-10-15 10-31 Meeting.md`: when the meeting began, to the
    /// minute, from its folder's name (the local time of its start, so no
    /// dates are formatted), and a later version's number. A file name, so
    /// never translated.
    static func exportName(folder: String, version: String, format: Format) -> String {
        let base = MeetingStorage.isMeetingFolderName(folder) ? String(folder.prefix(16)) + " Meeting" : folder
        let number = MeetingStorage.transcriptNumber(version).flatMap { $0 > 1 ? " \($0)" : nil } ?? ""
        return base + number + "." + format.fileExtension
    }
}
