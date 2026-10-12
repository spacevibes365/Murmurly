import AppKit
import AVFoundation
import Foundation

private final class HistoryAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let completion: @Sendable (String?) -> Void

    init(completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completion(flag ? nil : String(localized: "Playback ended with an error"))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        completion(error?.localizedDescription ?? String(localized: "Audio decoding error"))
    }
}

@MainActor
final class DictationHistoryViewModel: ObservableObject {
    @Published var searchText = ""
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var audioEntryIDs: Set<UUID> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var playingEntryID: UUID?
    /// An action's error (delete, clear, playback), shown as an alert.
    @Published var errorMessage: String?
    /// Why the history could not be read; shown in the tab, cleared by the
    /// next successful read.
    @Published private(set) var readFailure: String?

    private let store: DictationHistoryStore
    private let pageSize: Int
    private var cursor: UInt64?
    private var generation = 0
    private var player: AVAudioPlayer?
    private var playerDelegate: HistoryAudioPlayerDelegate?
    private var playbackGeneration = 0
    /// The entry whose audio lookup is still running, so a delete can cancel it.
    private var pendingPlaybackEntryID: UUID?

    #if DEBUG
    /// Test-only: called right before the audio lookup suspends, so a test
    /// knows `play` is waiting there before it stops, clears or plays again.
    var willLookUpAudioForTesting: (@MainActor () -> Void)?
    #endif

    init(store: DictationHistoryStore = .shared, pageSize: Int = 100) {
        self.store = store
        self.pageSize = pageSize
    }

    func reload() async {
        generation &+= 1
        let requestedGeneration = generation
        cursor = nil
        entries = []
        audioEntryIDs = []
        canLoadMore = true
        await loadPage(replacing: true, generation: requestedGeneration)
    }

    func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        await loadPage(replacing: false, generation: generation)
    }

    func delete(_ entry: DictationHistoryEntry) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        // Before the store: a pending lookup must not come back to life.
        if playingEntryID == entry.id || pendingPlaybackEntryID == entry.id { stopAudio() }
        do {
            let deleted = try await store.delete(id: entry.id)
            if deleted {
                await reload()
            }
            return deleted
        } catch {
            report(String(localized: "Couldn’t delete the recording: \(error.localizedDescription)"))
            return false
        }
    }

    func clearAll() async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            stopAudio()
            try await store.clearAll()
            generation &+= 1
            cursor = nil
            entries = []
            audioEntryIDs = []
            isLoading = false
            canLoadMore = false
            return true
        } catch {
            report(String(localized: "Couldn’t clear the history: \(error.localizedDescription)"))
            return false
        }
    }

    func play(_ entry: DictationHistoryEntry) async {
        if playingEntryID == entry.id {
            stopAudio()
            return
        }
        stopAudio()
        // Fixed before the lookup suspends: a stop, tab switch, window close,
        // delete, clear or newer play meanwhile makes this request stale.
        let requestedGeneration = playbackGeneration
        pendingPlaybackEntryID = entry.id
        #if DEBUG
        willLookUpAudioForTesting?()
        #endif
        let lookedUp = await store.audioURL(for: entry)
        // A stale request leaves no trace: no player, no stop of the newer
        // one, no error, also when its lookup found nothing.
        guard requestedGeneration == playbackGeneration, !Task.isCancelled else { return }
        pendingPlaybackEntryID = nil

        do {
            guard let url = lookedUp else {
                audioEntryIDs.remove(entry.id)
                throw CocoaError(.fileNoSuchFile)
            }
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            let delegate = HistoryAudioPlayerDelegate { [weak self] errorDescription in
                Task { @MainActor [weak self] in
                    self?.finishPlayback(
                        generation: requestedGeneration,
                        errorDescription: errorDescription
                    )
                }
            }
            nextPlayer.delegate = delegate
            player = nextPlayer
            playerDelegate = delegate
            guard nextPlayer.prepareToPlay(), nextPlayer.play() else {
                throw CocoaError(.fileReadUnknown)
            }
            playingEntryID = entry.id
        } catch {
            stopAudio()
            report(String(localized: "Couldn’t play the recording: \(error.localizedDescription)"))
        }
    }

    /// The audio file in Finder, for example to drop it into Files.
    func revealAudio(_ entry: DictationHistoryEntry) async {
        guard let url = await store.audioURL(for: entry) else {
            audioEntryIDs.remove(entry.id)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func stopAudio() {
        playbackGeneration &+= 1
        pendingPlaybackEntryID = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        playingEntryID = nil
    }

    private func finishPlayback(generation requestedGeneration: Int, errorDescription: String?) {
        guard requestedGeneration == playbackGeneration else { return }
        playbackGeneration &+= 1
        player?.delegate = nil
        player = nil
        playerDelegate = nil
        playingEntryID = nil
        if let errorDescription {
            report(String(localized: "Couldn’t play the recording: \(errorDescription)"))
        }
    }

    private func loadPage(replacing: Bool, generation requestedGeneration: Int) async {
        isLoading = true
        defer {
            if requestedGeneration == generation { isLoading = false }
        }

        let requestedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let page = try await store.page(
                before: replacing ? nil : cursor,
                limit: pageSize,
                matching: requestedQuery.isEmpty ? nil : requestedQuery
            )
            try Task.checkCancellation()
            let availableAudio = await store.existingAudioIDs(for: page.entries)
            try Task.checkCancellation()
            guard requestedGeneration == generation else { return }

            if replacing {
                entries = page.entries
                audioEntryIDs = availableAudio
            } else {
                let knownIDs = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { !knownIDs.contains($0.id) })
                audioEntryIDs.formUnion(availableAudio)
            }
            cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            readFailure = nil
        } catch is CancellationError {
            // A newer search owns the visible state.
        } catch {
            guard requestedGeneration == generation, !Task.isCancelled else { return }
            readFailure = String(localized: "Couldn’t read the history: \(error.localizedDescription)")
            canLoadMore = false
        }
    }

    private func report(_ message: String) {
        errorMessage = message
    }

    /// A read the view made itself (the search count) failed: shown like a
    /// failed page read, in the tab, and cleared by the next successful read.
    func reportReadFailure(_ message: String) {
        readFailure = message
    }
}
