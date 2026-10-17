import AVFoundation
import Foundation

/// One track as the player drives it: `AVAudioPlayer`'s own members and
/// what went wrong with it, so the app plays through it and a test or a UI
/// test's probe stands in.
protocol MeetingTrack: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var deviceCurrentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }
    var volume: Float { get set }
    /// Why it stopped by itself, when it did not play out: a decoding
    /// error, a file that went away.
    var failure: String? { get }
    func play(atTime time: TimeInterval) -> Bool
    func pause()
    func stop()
}

/// `AVAudioPlayer` with its delegate, which says why it stopped.
final class AudioPlayerTrack: NSObject, MeetingTrack, AVAudioPlayerDelegate, @unchecked Sendable {
    private let player: AVAudioPlayer
    private let lock = NSLock()
    private var failed: String?

    init(_ url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.enableRate = true
        guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var deviceCurrentTime: TimeInterval { player.deviceCurrentTime }
    var isPlaying: Bool { player.isPlaying }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var failure: String? { lock.withLock { failed } }
    func play(atTime time: TimeInterval) -> Bool { player.play(atTime: time) }
    func pause() { player.pause() }
    func stop() { player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !flag { lock.withLock { failed = String(localized: "Playback ended with an error") } }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        lock.withLock { failed = error?.localizedDescription ?? String(localized: "Audio decoding error") }
    }
}

/// A meeting's two tracks played as one: one shared start time, one rate,
/// each track only on or muted, never louder than recorded. Owned by the
/// window's model, which alone loads and lets go of it: the files stay open
/// while the card shows the meeting, so the timeline knows the real length
/// and a start is at once; any operation on the folder, a deletion above all,
/// has them closed first. Files are opened off the main actor (a network
/// volume may hang), each load under a generation of its own: a late one
/// only closes what it opened.
@MainActor
final class MeetingPlayer: ObservableObject {
    enum State: Equatable {
        case empty
        case loading
        case ready
        case playing
        /// Why there is nothing to play.
        case unavailable(String)
    }

    /// How a track is opened; off the main actor.
    struct Deck: Sendable {
        var open: @Sendable (URL) throws -> any MeetingTrack

        /// AVFoundation's player, never in a test process: a test copy
        /// makes no sound, whatever its environment. A DEBUG UI test that
        /// asks for it (`-PlayerProbe`) gets silent tracks of its own.
        static let live: Deck = {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-PlayerProbe") { return probe }
            #endif
            return TestIsolation.isTestProcess ? refusing : audioPlayers
        }()

        static let audioPlayers = Deck { try AudioPlayerTrack($0) }

        static let refusing = Deck { _ in
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Nothing is played in a test process."),
            ])
        }

        #if DEBUG
        /// Silent tracks of a minute and a half on the system clock.
        static let probe = Deck { _ in SilentTrack(duration: 90) }
        #endif
    }

    @Published private(set) var state = State.empty
    /// The longest track's length: the timeline, by the files' frames.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var sources: [MeetingAttempt.Source] = []
    @Published private(set) var muted: Set<MeetingAttempt.Source> = []
    @Published private(set) var rate: Float = 1
    /// What a start was refused with, until the next action.
    @Published private(set) var refusal: String?
    /// Why no start is allowed for now (a recording, a dictation), loaded
    /// or not: the card turns Play off with it.
    @Published private(set) var held: String?
    /// The folder whose files are open or being opened.
    private(set) var folder: URL?
    private(set) var identity: FolderIdentity?
    private(set) var files: [MeetingAttempt.Source: String] = [:]

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Why a start is not allowed now, asked right before every start; set by
    /// the window's model (a recording, a dictation, an operation, another
    /// meeting on the card, a closed window).
    var startRefusal: @MainActor () -> String? = { nil }

    private let deck: Deck
    private var tracks: [MeetingAttempt.Source: any MeetingTrack] = [:]
    private var generation = 0
    /// Loads whose opening is not over yet, late ones included, by the
    /// folder itself: what they open may be open now. An operation on the
    /// folder waits for none to be left (`isOpening`).
    private var opening: [FolderIdentity: Int] = [:]
    private var ticket: LoadTicket?

    /// Said off the main actor, between two opens: a load let go of opens
    /// nothing more.
    private final class LoadTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct LoadFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    /// Where a start begins: the position while not playing.
    @Published private(set) var resumeAt: TimeInterval = 0
    private var endWatch: Timer?

    init(deck: Deck = .live) {
        self.deck = deck
    }

    /// Where the sound is now; not published: the view reads it while it plays.
    var position: TimeInterval {
        guard state == .playing, let lead else { return resumeAt }
        return min(lead.currentTime, duration)
    }

    var isLoaded: Bool { !tracks.isEmpty }

    private var lead: (any MeetingTrack)? { tracks.values.max { $0.duration < $1.duration } }

    // MARK: - Loading

    /// Opens the folder's tracks on `queue`, one after another: right before
    /// each, the folder at its address must still be `identity` and the
    /// track a plain file there (a link is not followed), and the load must
    /// not have been let go of. A later load, an unload or a release makes
    /// this one late: what it opened is only closed.
    func load(
        _ folder: URL, identity: FolderIdentity, files: [MeetingAttempt.Source: String],
        on queue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        unload()
        generation += 1
        let loading = generation
        self.folder = folder
        self.identity = identity
        self.files = files
        state = .loading
        let ticket = LoadTicket()
        self.ticket = ticket
        opening[identity, default: 0] += 1
        let deck = self.deck
        queue {
            let opened = Result { () -> Opened in
                var tracks: [MeetingAttempt.Source: any MeetingTrack] = [:]
                for (source, name) in files.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    guard !ticket.isCancelled else { throw CancellationError() }
                    guard FolderIdentity.of(folder) == identity else {
                        throw LoadFailure(reason: String(localized: "Another folder is at the meeting’s address now."))
                    }
                    switch MeetingStorage.entry(name, in: folder) {
                    case .file: break
                    case .absent: throw LoadFailure(reason: String(localized: "“\(name)” is gone."))
                    case .unknown(let reason): throw LoadFailure(reason: reason)
                    }
                    tracks[source] = try deck.open(folder.appendingPathComponent(name))
                }
                return Opened(tracks: tracks)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoad(loading, identity: identity, opened) }
            }
        }
    }

    /// Whether a load of any of these folders is still opening files.
    func isOpening(_ identities: Set<FolderIdentity>) -> Bool {
        identities.contains { opening[$0, default: 0] > 0 }
    }

    /// `@unchecked`: the tracks go from the queue that opened them to the
    /// main actor once, and are used there only.
    private final class Opened: @unchecked Sendable {
        let tracks: [MeetingAttempt.Source: any MeetingTrack]
        init(tracks: [MeetingAttempt.Source: any MeetingTrack]) { self.tracks = tracks }
    }

    private func finishLoad(_ loading: Int, identity: FolderIdentity, _ opened: Result<Opened, Error>) {
        defer {
            opening[identity, default: 1] -= 1
            if opening[identity] == 0 { opening[identity] = nil }
        }
        // Late: what it opened goes with it, here.
        guard loading == generation else { return }
        switch opened {
        case .success(let opened):
            tracks = opened.tracks
            for track in tracks.values { track.rate = rate }
            for (source, track) in tracks { track.volume = muted.contains(source) ? 0 : 1 }
            duration = tracks.values.map(\.duration).max() ?? 0
            sources = [.microphone, .system].filter { tracks[$0] != nil }
            resumeAt = 0
            state = .ready
        case .failure(let error):
            close(String(localized: "The audio can’t be played: \(error.localizedDescription)"))
        }
    }

    /// Closes the files, here and now, and stops a start scheduled on them.
    /// `reason`: what the card says instead of the player.
    func unload(_ reason: String? = nil) {
        generation += 1
        ticket?.cancel()
        ticket = nil
        close(reason)
    }

    /// Closes the files if they are of any of these folders: the queue is
    /// about to move or delete them.
    func release(_ identities: Set<FolderIdentity>, reason: String) {
        guard let identity, identities.contains(identity) else { return }
        unload(reason)
    }

    private func close(_ reason: String?) {
        stopWatchingTheEnd()
        // `stop` undoes a `play(atTime:)` not yet due; the last reference
        // to each player closes its file.
        for track in tracks.values { track.stop() }
        tracks = [:]
        duration = 0
        sources = []
        resumeAt = 0
        refusal = nil
        if reason == nil {
            folder = nil
            identity = nil
            files = [:]
        }
        state = reason.map(State.unavailable) ?? .empty
    }

    // MARK: - Playing

    func toggle() {
        state == .playing ? pause() : play()
    }

    /// From `resumeAt`, every track at one moment of the output's clock;
    /// a track shorter than that stays quiet.
    func play() {
        guard state == .ready, let lead else { return }
        if let reason = startRefusal() {
            refusal = reason
            return
        }
        refusal = nil
        if resumeAt >= duration { resumeAt = 0 }
        let start = lead.deviceCurrentTime + 0.05
        for track in tracks.values where resumeAt < track.duration {
            track.currentTime = resumeAt
            // One track that won't start would leave the other playing alone.
            guard track.play(atTime: start) else {
                stopBoth(String(localized: "The audio didn’t start."))
                return
            }
        }
        state = .playing
        watchTheEnd()
    }

    /// Both tracks stop together, with the reason; the files close, as a
    /// track that failed may fail again.
    private func stopBoth(_ reason: String) {
        unload(String(localized: "The audio stopped: \(reason)"))
    }

    func pause() {
        guard state == .playing else { return }
        resumeAt = position
        for track in tracks.values { track.pause() }
        stopWatchingTheEnd()
        state = .ready
    }

    /// Anywhere on the timeline; goes on playing if it was, asked again.
    func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        let playing = state == .playing
        if playing { pause() }
        resumeAt = min(max(0, time), duration)
        if playing { play() }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    /// From a line: there, and playing.
    func play(from time: TimeInterval) {
        seek(to: time)
        if state == .ready { play() }
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        let playing = state == .playing
        if playing { pause() }
        for track in tracks.values { track.rate = rate }
        if playing { play() }
    }

    func toggleMute(_ source: MeetingAttempt.Source) {
        if muted.contains(source) { muted.remove(source) } else { muted.insert(source) }
        tracks[source]?.volume = muted.contains(source) ? 0 : 1
    }

    /// Paused where it is, for a recording or a dictation, loaded or not:
    /// Play stays off with the reason until `unhold`.
    func hold(_ reason: String) {
        pause()
        held = reason
    }

    func unhold() {
        held = nil
        refusal = nil
    }

    private func watchTheEnd() {
        stopWatchingTheEnd()
        endWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTheEnd() }
        }
    }

    private func stopWatchingTheEnd() {
        endWatch?.invalidate()
        endWatch = nil
    }

    /// A track failed: both stop, with the reason. The longest track has
    /// played out: the end.
    private func checkTheEnd() {
        guard state == .playing else { return }
        if let failure = tracks.values.lazy.compactMap(\.failure).first {
            stopBoth(failure)
            return
        }
        guard let lead, !lead.isPlaying else { return }
        for track in tracks.values { track.pause() }
        stopWatchingTheEnd()
        resumeAt = duration
        state = .ready
    }
}

#if DEBUG
/// A track that plays nothing on the system clock, for tests and the UI
/// test's probe; `closed` is told when its player lets go of it.
final class SilentTrack: MeetingTrack, @unchecked Sendable {
    let duration: TimeInterval
    var rate: Float = 1
    var volume: Float = 1
    /// Set by a test: why it stopped, as AVFoundation would say.
    var failure: String? {
        didSet { if failure != nil { startedAt = nil } }
    }
    /// Set by a test: `play(atTime:)` answers no.
    var refusesToPlay = false
    private let clock: @Sendable () -> TimeInterval
    private let closed: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    private var startedAt: TimeInterval?
    private var startedFrom: TimeInterval = 0
    private var position: TimeInterval = 0

    init(
        duration: TimeInterval,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        log: @escaping @Sendable (String) -> Void = { _ in },
        closed: @escaping @Sendable () -> Void = {}
    ) {
        self.duration = duration
        self.clock = clock
        self.log = log
        self.closed = closed
    }

    deinit { closed() }

    var deviceCurrentTime: TimeInterval { clock() }

    var isPlaying: Bool {
        guard let startedAt else { return false }
        return clock() >= startedAt && current < duration
    }

    var currentTime: TimeInterval {
        get { current }
        set {
            position = min(max(0, newValue), duration)
            if startedAt != nil { startedAt = clock() }
            startedFrom = position
        }
    }

    private var current: TimeInterval {
        guard let startedAt, clock() >= startedAt else { return position }
        return min(duration, startedFrom + (clock() - startedAt) * TimeInterval(rate))
    }

    func play(atTime time: TimeInterval) -> Bool {
        guard !refusesToPlay else { return false }
        startedFrom = position
        startedAt = time
        log("play \(time) from \(position)")
        return true
    }

    func pause() {
        position = current
        startedAt = nil
        log("pause \(position)")
    }

    func stop() {
        position = current
        startedAt = nil
        log("stop")
    }
}
#endif
