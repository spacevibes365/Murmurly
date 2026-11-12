import Foundation

/// Jumping to a note's moment, from the notepad or the card: opens the
/// meeting on Meetings, shows the main window, and plays once the audio has
/// loaded. Shared by `MeetingLibrary.notepadNotes`/`playNote` (the card) and
/// the notepad.
extension MeetingLibrary {
    /// Shows the main window from outside its scene, as
    /// `AppDelegate.showMainWindow` does; set by the menu bar label's task,
    /// so the notepad and the card share one path. A test sets its own.
    @MainActor static var showMainWindow: (@MainActor () -> Void)?

    /// A thought is written down after it was said.
    nonisolated static let noteLead: TimeInterval = 10

    /// How long the meeting's audio may take to load before giving up.
    @MainActor static var audioWait: Duration = .seconds(10)

    /// Refuses at once, playing nothing, while the player is held (a
    /// recording, its stop included, or a dictation) or the queue works on
    /// the folder; the reason is for the caller (a button) to show. A
    /// meeting not read into a snapshot yet shows no such refusal here —
    /// once the folder loads, the card itself says why nothing plays
    /// (`player.state == .unavailable`). Otherwise opens the meeting at its
    /// address now, shows the main window, and plays from `seconds` once the
    /// player has loaded that folder, as long as the meeting is still
    /// selected when it does.
    @discardableResult
    func openAndPlay(folder: URL, at seconds: Double) -> String? {
        let target = address(of: folder)
        if let held = player.held { return held }
        if let meeting = meeting(at: target), let reason = audioRefusal(for: meeting) { return reason }
        open(target)
        Self.showMainWindow?()
        let seconds = max(0, seconds)
        Task { [weak self] in await self?.playOnceLoaded(target, at: seconds) }
        return nil
    }

    /// Polls for the folder's audio to finish loading, then plays from
    /// `seconds`; gives up after `audioWait`. `@Published` sends its value
    /// before the property it announces changes (`willSet`), so the state is
    /// read fresh on every step rather than trusted from a subscription.
    private func playOnceLoaded(_ target: URL, at seconds: Double) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.audioWait)
        while clock.now < deadline {
            guard selection?.standardizedFileURL.path == target.standardizedFileURL.path else { return }
            if player.folder?.standardizedFileURL.path == target.standardizedFileURL.path {
                switch player.state {
                case .ready, .playing:
                    player.play(from: seconds)
                    return
                case .unavailable:
                    // The card already shows why; nothing more to do here.
                    return
                case .empty, .loading:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        AppLog.info("meeting-library", "\(target.lastPathComponent): audio not loaded in time; not played")
    }

    /// Timed notes by time (ties kept in file order), then the untimed ones
    /// as written. `sorted` is not stable, so ties are broken by the
    /// original index.
    nonisolated static func notesInOrder(_ notes: [MeetingNote]) -> [MeetingNote] {
        notes.enumerated().sorted { a, b in
            switch (a.element.t, b.element.t) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _?): return false
            case (_?, nil): return true
            case (let at?, let bt?): return at != bt ? at < bt : a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The meeting's notepad notes as the card shows them, with changes not
    /// on disk yet.
    func notepadNotes(of meeting: Meeting) -> [MeetingNote] {
        Self.notesInOrder(marks(of: self.meeting(at: meeting.directory) ?? meeting)?.notes ?? [])
    }

    /// From a note's time on the card: `noteLead` seconds earlier, never
    /// before the start; a note with no time does nothing.
    func playNote(_ note: MeetingNote) {
        guard let t = note.t else { return }
        player.play(from: max(0, t - Self.noteLead))
    }
}
