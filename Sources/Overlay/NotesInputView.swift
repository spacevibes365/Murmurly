import Combine
import KeyboardShortcuts
import ObjectiveC
import SwiftUI

/// What the notepad needs from the recorder and the library, read or called
/// by `notepad.meeting` at the time, never bound to one meeting ahead of
/// time: wired once by `NotepadNotes.attach`.
struct NotepadNoteServices {
    var recordingSeconds: () async -> Double?
    var addNote: (MeetingNote) -> String?
    var editNote: (_ id: UUID, _ text: String) -> String?
    var deleteNote: (_ id: UUID) -> String?
    /// Whether this id's last add attempt has not yet been confirmed
    /// written (never attempted is also "not landed" — false only once an
    /// add has actually landed clean). Backs `editNote`'s resend-as-add
    /// decision: a past edit or delete failure must never trigger this.
    var addHasNotLanded: (_ id: UUID) -> Bool
    /// ★ and ⌥⇧M: marks a moment of the recording under way, whatever
    /// meeting the notepad shows. The argument is the line selection to use,
    /// if any — `NotepadModel.markMoment(usingSelection:)` has already
    /// decided whether one applies. Wired by `NotepadNotes.installServices`,
    /// which alone has the recorder's and the library's own addresses.
    var markMoment: (NotepadLineSelection?) -> Void = { _ in }
}

private let meetingFolderUnavailable = String(localized: "The meeting folder isn’t available.")

/// A plain class box so a struct or a `Set` can hang off an associated
/// object, which only accepts `AnyObject`.
private final class AssociatedBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Backs `NotepadModel.noteServices` and `.localNoteFailureIDs` as
/// associated objects, not a stored property, so the wiring stays tied to
/// the exact model instance it was set on and is torn down with it; a plain
/// dictionary keyed by `ObjectIdentifier` was tried first and read a stale
/// entry back for a brand new model once an earlier one's address was
/// reused after deallocation (caught by `NotesInputViewTests`, which makes
/// many).
// Only their address is ever used (as an associated-object key), never
// their value, so the two are safe despite being mutable global state.
nonisolated(unsafe) private var noteServicesAssociationKey: UInt8 = 0
nonisolated(unsafe) private var localNoteFailureIDsAssociationKey: UInt8 = 0

extension NotepadModel {
    /// What the notepad needs from the recorder and the library — reading
    /// the recording's own clock, and adding/editing/deleting a note —
    /// wired once by `NotepadNotes.attach`, from `MurmurlyApp`. nil before
    /// `attach` runs (a UI probe that never calls it): `NotesInputView`
    /// still keeps what was typed, with a stated refusal, rather than lose
    /// it.
    var noteServices: NotepadNoteServices? {
        get { (objc_getAssociatedObject(self, &noteServicesAssociationKey) as? AssociatedBox<NotepadNoteServices>)?.value }
        set {
            let box = newValue.map(AssociatedBox.init)
            objc_setAssociatedObject(self, &noteServicesAssociationKey, box, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// Ids whose last add/edit/delete never reached `MeetingLibrary` at all
    /// (no `noteServices`, or no meeting at the time it was called): the
    /// library's own `pendingNotes`/`noteFailures`, which never saw such an
    /// id, must never clear a refusal it did not make. Lives here, keyed by
    /// the model itself, so it survives a late `NotepadNotes.attach`: a
    /// failure recorded before attach must not be wiped by the first
    /// reconcile tick right after. Cleared the moment a later call for the
    /// same id does reach the library, which then becomes authoritative for
    /// it again.
    var localNoteFailureIDs: Set<UUID> {
        get { (objc_getAssociatedObject(self, &localNoteFailureIDsAssociationKey) as? AssociatedBox<Set<UUID>>)?.value ?? [] }
        set {
            objc_setAssociatedObject(self, &localNoteFailureIDsAssociationKey, AssociatedBox(newValue), .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// Return on a non-empty field: shown in the feed at once, "Saving…"
    /// until the library's own write settles (`NotepadNotes`'s reconcile,
    /// driven by `MeetingLibrary.pendingNotes`/`noteFailures`). Empty text
    /// does nothing — `NotesInputView` already checks, this guards
    /// `markMoment`'s own call too, which never sends empty text here.
    @discardableResult
    func submitNote(text: String, t: Double?, kind: MeetingNote.Kind = .note) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = MeetingNote(id: UUID(), t: t, kind: kind, text: trimmed)
        notes.append(note)
        guard let services = noteServices else {
            noteFailures[note.id] = meetingFolderUnavailable
            localNoteFailureIDs.insert(note.id)
            return note.id
        }
        if let refusal = services.addNote(note) {
            noteFailures[note.id] = refusal
        }
        return note.id
    }

    /// Return while editing: an emptied text deletes instead. Shown with the
    /// new text at once, the same "Saving…"/refusal path as `submitNote`.
    /// Refuses outright, without calling the library at all, while the id
    /// has an unfinished write of its own (`pendingNoteIDs`): its add, edit
    /// or delete was already accepted but is not yet on disk, so a second
    /// write racing it is the one thing that tangled with the queue and
    /// produced a clean-looking outcome with the old text still on disk.
    /// While the note's own add has not yet landed on disk because it was
    /// refused or failed (`addHasNotLanded`, set only by an actual add
    /// refusal — never by a past edit or delete failure of an
    /// already-written note), this resends as another add of the same id
    /// with the new text rather than an edit: the writer has nothing
    /// written to edit against yet.
    @discardableResult
    func editNote(id: UUID, text: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        guard !pendingNoteIDs.contains(id) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return requestDelete(id: id) }
        notes[index].text = trimmed
        guard let services = noteServices else {
            noteFailures[id] = meetingFolderUnavailable
            localNoteFailureIDs.insert(id)
            return true
        }
        let addHasNotLanded = services.addHasNotLanded(id)
        let refusal = addHasNotLanded ? services.addNote(notes[index]) : services.editNote(id, trimmed)
        if let refusal {
            noteFailures[id] = refusal
        }
        return true
    }

    /// "Delete Note", or an edit emptied: the row leaves the feed only once
    /// `NotepadNotes`'s reconcile sees the library settle this id with no
    /// failure and nothing still pending — never here, before that call's
    /// own outcome (sync or not) has actually reached `MeetingLibrary`.
    /// Refuses outright, without calling the library, while the id already
    /// has an unfinished write of its own (`pendingNoteIDs`) — the same gate
    /// `editNote` applies.
    @discardableResult
    func requestDelete(id: UUID) -> Bool {
        guard notes.contains(where: { $0.id == id }) else { return false }
        guard !pendingNoteIDs.contains(id) else { return false }
        guard let services = noteServices else {
            noteFailures[id] = meetingFolderUnavailable
            localNoteFailureIDs.insert(id)
            return true
        }
        if let refusal = services.deleteNote(id) {
            noteFailures[id] = refusal
        }
        return true
    }

    /// ★ or ⌥⇧M: marks a moment of the recording under way, never of
    /// whatever meeting the notepad happens to show. `usingSelection` is
    /// false for ⌥⇧M (pressed from the call; a selection left in the feed
    /// may be stale) and true for ★: a selection in a line of the feed is
    /// taken only while this notepad shows the recording itself — never a
    /// selection left over from a stopped meeting shown while another
    /// recording runs. The selection is consumed either way: a moment is a
    /// one-time action, and a used or bypassed selection must not linger.
    /// The actual work is `NotepadNotes.installServices`'s own closure,
    /// which alone has the recorder's and the library's addresses.
    func markMoment(usingSelection: Bool = true) {
        let selection = (usingSelection && meeting?.isRecording == true) ? lineSelection : nil
        lineSelection = nil
        noteServices?.markMoment(selection)
    }
}

/// Captures a note's time on its first character, kept until Return (or a
/// stop) rather than read again at Enter: `stamp()`
/// starts one read of `recordingSeconds()` in a `Task` (the main actor's next
/// turn) and does nothing on a later call; `value` awaits that same read, so
/// it keeps answering what it first captured however the clock moves after.
@MainActor
final class NoteDraftStamp {
    private let recordingSeconds: () async -> Double?
    private var task: Task<Double?, Never>?

    init(recordingSeconds: @escaping () async -> Double?) {
        self.recordingSeconds = recordingSeconds
    }

    func stamp() {
        guard task == nil else { return }
        let recordingSeconds = recordingSeconds
        task = Task { await recordingSeconds() }
    }

    var value: Double? {
        get async {
            guard let task else { return nil }
            return await task.value
        }
    }
}

/// The note field's own rule, apart from the view: the time is captured on
/// the first character (`NoteDraftStamp`), cleared the moment the field goes
/// back to empty, so a new first character after that starts a new stamp —
/// the view only forwards text changes and Return to this.
@MainActor
final class NoteDraftController: ObservableObject {
    @Published var text = ""
    private weak var notepad: NotepadModel?
    private var stamp: NoteDraftStamp?
    private var meetingChangeCancellable: AnyCancellable?

    init(notepad: NotepadModel) {
        self.notepad = notepad
        // A genuinely new meeting (`resetForMeeting`) drops this draft: a
        // note begun on the meeting just left must never be delivered to
        // the one that replaces it. `live → stopped` of the same meeting
        // does not bump the generation, so a draft started during a
        // recording survives its own stop.
        meetingChangeCancellable = notepad.$meetingGeneration.dropFirst().sink { [weak self] _ in
            self?.text = ""
            self?.stamp = nil
        }
    }

    func textDidChange() {
        guard !text.isEmpty else {
            stamp = nil
            return
        }
        guard stamp == nil else { return }
        // A draft takes the recording's time only while the notepad is on
        // the recording itself: a note started on a stopped meeting must
        // never take the time of a recording under way elsewhere.
        let isOnRecording = notepad?.meeting?.isRecording == true
        let recordingSeconds = isOnRecording ? (notepad?.noteServices?.recordingSeconds ?? { nil }) : { nil }
        let newStamp = NoteDraftStamp(recordingSeconds: recordingSeconds)
        newStamp.stamp()
        stamp = newStamp
    }

    func submit() {
        let text = self.text
        let capturedStamp = stamp
        self.text = ""
        stamp = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { [weak notepad] in
            let t = await capturedStamp?.value
            notepad?.submitNote(text: text, t: t)
        }
    }

    #if DEBUG
    var hasStampForTesting: Bool { stamp != nil }
    #endif
}

/// ⌥⇧M, registered only for the span of a recording: the same open/closed
/// stream shape as the dictation's Esc listener. Owns a `HotkeyManager` of
/// its own — unrelated to dictation's — so a change here never touches
/// `DictationCoordinator`'s registrations.
@MainActor
final class MarkMomentHotkey {
    var onMarkMoment: () -> Void = {}
    private let manager: HotkeyManager
    private var cancellable: AnyCancellable?

    init(manager: HotkeyManager = HotkeyManager(), recorder: MeetingRecorder) {
        self.manager = manager
        cancellable = recorder.$state.sink { [weak self] state in
            self?.apply(isRecording: state == .recording)
        }
    }

    private func apply(isRecording: Bool) {
        guard isRecording else {
            manager.listenForMarkMoment(nil) {}
            return
        }
        let shortcut = KeyboardShortcuts.Name.markMoment.shortcut
        manager.listenForMarkMoment(shortcut) { [weak self] in self?.onMarkMoment() }
    }

    #if DEBUG
    var managerForTesting: HotkeyManager { manager }
    #endif
}

/// Ties the notepad to the recorder and the library: submitting/editing/
/// deleting notes through `noteServices`, and reconciling the library's own
/// `pendingNotes`/`noteFailures` into the notepad's feed. Which meeting the
/// notepad is open on (`notepad.meeting`) is set by `NotepadWindow`, never
/// here. A type of its own, not an extension, because the notepad's slots
/// are handed only the model (`NotepadView.swift`): this is what wires the
/// writer, from `MurmurlyApp`.
@MainActor
final class NotepadNotes {
    private weak var notepad: NotepadModel?
    private weak var recorder: MeetingRecorder?
    private weak var library: MeetingLibrary?
    private var cancellables: Set<AnyCancellable> = []
    private var hotkey: MarkMomentHotkey?
    /// Notes a delete was asked for, and the library actually accepted the
    /// request (its own call returned no refusal): tells `reconcile` that a
    /// clean, non-pending outcome for this id means the row goes, not that
    /// an add or an edit landed. Never set on a delete the library refused
    /// outright — that must leave the row and its reason exactly as any
    /// other failure does. Cleared the moment `reconcile` sees this id
    /// settle with a failure too: a delete that did not land is not still
    /// "deleting", and some later, unrelated clean outcome for the id must
    /// never remove the row out from under a refusal still being shown.
    private var deletingNoteIDs: Set<UUID> = []
    /// Ids whose last `addNote` call is still in flight (accepted, not yet
    /// settled): backs `addFailedIDs`'s own bookkeeping in `reconcile`, so a
    /// failure or a clean settle is only ever attributed to an id whose last
    /// write was actually an add — never to an edit or a delete that
    /// happened to fail or land afterwards. `editNote`/`requestDelete`
    /// already refuse to run at all while an id is in `pendingNoteIDs`, so
    /// this never races a second write for the same id.
    private var awaitingAddConfirmation: Set<UUID> = []
    /// Ids whose last *add* attempt ended in a refusal or a failure, with
    /// nothing landed since: backs `NotepadNoteServices.addHasNotLanded`,
    /// read by `editNote` to decide whether to resend as another add.
    /// Never set by an edit or a delete failure of an already-written note.
    private var addFailedIDs: Set<UUID> = []
    /// The library's own `dismissNoteFailure` (at the top of `changeNotes`)
    /// clears a failure synchronously before a new write even starts, so two
    /// Combine ticks can land in one synchronous call: a refused delete
    /// right after a refused edit first clears, then re-sets, the same id.
    /// Reconciling on the first tick would remove the row on that transient
    /// "clean" moment. Deferred to the next turn and
    /// coalesced, the same throttle `MeetingLibrary.scheduleMarksResume`
    /// uses, so only the batch's final values are ever applied.
    private var pendingReconcile: (pending: Set<UUID>, failures: [UUID: MeetingLibrary.MarkFailure])?
    private var reconcileScheduled = false

    /// How far behind the recording's clock the newest live line may end and
    /// still be what ★/⌥⇧M point at without a selection. The live text lags a
    /// phrase by about 0.7 s and an unfinished line's end keeps moving while
    /// it is still spoken, so a line within this window is "what is being
    /// said now"; a reaction takes a few seconds, which this margin covers.
    /// Past it (a pause, a lagging queue, or the pipeline stopped) the moment
    /// takes the clock instead, with no text, as it does with no lines at all.
    static let momentLineFreshness: Double = 10

    /// The newest non-empty line of `model`, if the live text is still
    /// running and that line ended at most `momentLineFreshness` seconds
    /// before `seconds` — else nil (no lines, the pipeline stopped or has no
    /// model, or the newest line is stale).
    static func freshMomentLine(in model: LiveTranscriptModel?, at seconds: Double) -> LiveLine? {
        guard let model else { return nil }
        switch model.state {
        case .stopped, .noModel:
            return nil
        default:
            break
        }
        guard let line = model.lines.last(where: {
            !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        guard seconds - line.end <= momentLineFreshness else { return nil }
        return line
    }

    private init(notepad: NotepadModel, recorder: MeetingRecorder, library: MeetingLibrary) {
        self.notepad = notepad
        self.recorder = recorder
        self.library = library
    }

    @discardableResult
    static func attach(
        notepad: NotepadModel, recorder: MeetingRecorder, library: MeetingLibrary
    ) -> NotepadNotes {
        let notes = NotepadNotes(notepad: notepad, recorder: recorder, library: library)
        notes.installServices()
        notes.observeLibrary()
        let hotkey = MarkMomentHotkey(recorder: recorder)
        hotkey.onMarkMoment = { [weak notepad] in notepad?.markMoment(usingSelection: false) }
        notes.hotkey = hotkey
        return notes
    }

    private func installServices() {
        notepad?.noteServices = NotepadNoteServices(
            recordingSeconds: { [weak recorder] in await recorder?.recordingSeconds() },
            addNote: { [weak self, weak notepad, weak library] note in
                guard let notepad, let library, let meeting = notepad.meeting else {
                    self?.addFailedIDs.insert(note.id)
                    notepad?.localNoteFailureIDs.insert(note.id)
                    return meetingFolderUnavailable
                }
                notepad.localNoteFailureIDs.remove(note.id)
                self?.awaitingAddConfirmation.insert(note.id)
                let refusal = library.addNote(note, identity: meeting.identity, folder: meeting.folder)
                // A write in the meetings root runs synchronously, so right
                // here `library`'s own `pendingNotes`/`noteFailures` already
                // hold the final outcome — reading them now, rather than
                // waiting for `reconcile`'s deferred tick, means a landed
                // add is known landed before the very next call for this id
                // (an edit right after, with no run-loop turn in between).
                // A write still pending (an async channel) is left in
                // `awaitingAddConfirmation`; `reconcile` settles it once
                // that write actually finishes.
                if refusal != nil {
                    self?.addFailedIDs.insert(note.id)
                    self?.awaitingAddConfirmation.remove(note.id)
                } else if !library.pendingNotes.contains(note.id) {
                    self?.addFailedIDs.remove(note.id)
                    self?.awaitingAddConfirmation.remove(note.id)
                }
                return refusal
            },
            editNote: { [weak notepad, weak library] id, text in
                guard let notepad, let library, let meeting = notepad.meeting else {
                    notepad?.localNoteFailureIDs.insert(id)
                    return meetingFolderUnavailable
                }
                notepad.localNoteFailureIDs.remove(id)
                return library.editNote(id: id, text: text, identity: meeting.identity, folder: meeting.folder)
            },
            deleteNote: { [weak self, weak notepad, weak library] id in
                // The note's own add never reached the disk (refused or
                // failed): there is nothing to delete there, so the row
                // just leaves the feed and the library's failure for it.
                if self?.addFailedIDs.contains(id) == true {
                    library?.dismissNoteFailure(id)
                    self?.addFailedIDs.remove(id)
                    self?.awaitingAddConfirmation.remove(id)
                    notepad?.localNoteFailureIDs.remove(id)
                    notepad?.notes.removeAll { $0.id == id }
                    notepad?.noteFailures[id] = nil
                    notepad?.pendingNoteIDs.remove(id)
                    return nil
                }
                guard let notepad, let library, let meeting = notepad.meeting else {
                    notepad?.localNoteFailureIDs.insert(id)
                    return meetingFolderUnavailable
                }
                notepad.localNoteFailureIDs.remove(id)
                let refusal = library.deleteNote(id: id, identity: meeting.identity, folder: meeting.folder)
                if refusal == nil {
                    self?.deletingNoteIDs.insert(id)
                }
                return refusal
            },
            addHasNotLanded: { [weak self] id in
                self?.addFailedIDs.contains(id) ?? false
            },
            markMoment: { [weak notepad, weak recorder, weak library] selection in
                guard let recorder, recorder.state == .recording, let session = recorder.currentSession else { return }
                let showsRecording = notepad?.meeting?.isRecording == true
                    && notepad?.meeting?.folder.standardizedFileURL.path == session.directory.standardizedFileURL.path

                // A line selected in the feed, on this very recording: its
                // own start, and its words if any — else (a selection that
                // never reached past the speaker's name) the line's whole
                // text, read now rather than waiting on the clock.
                var target: (start: Double, text: String, lineID: UUID?)?
                if let selection, showsRecording {
                    let trimmed = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        target = (selection.start, trimmed, selection.lineID)
                    } else if let line = recorder.liveTranscriptModel?.lines.first(where: { $0.id == selection.lineID }) {
                        target = (selection.start, line.displayText.trimmingCharacters(in: .whitespacesAndNewlines), selection.lineID)
                    } else {
                        target = (selection.start, "", selection.lineID)
                    }
                }

                @MainActor func saveMoment(_ note: MeetingNote, lineID: UUID?) {
                    if showsRecording, let notepad {
                        if let lineID {
                            notepad.momentLineIDs[note.id] = lineID
                        }
                        notepad.notes.append(note)
                        if let refusal = notepad.noteServices?.addNote(note) {
                            notepad.noteFailures[note.id] = refusal
                        }
                        return
                    }
                    // The notepad is on another meeting, or none: the moment
                    // still belongs to the recording, not to what is shown.
                    if let refusal = library?.addNote(note, identity: session.identity, folder: session.directory) {
                        AppLog.error("notepad", "moment not saved: \(refusal)")
                    }
                }

                if let target {
                    let note = MeetingNote(id: UUID(), t: target.start, kind: .moment, text: target.text)
                    saveMoment(note, lineID: target.lineID)
                    return
                }

                // No selection on this recording: read the clock first, then
                // take the newest live line only while it is still fresh
                // (`freshMomentLine`); otherwise the clock, with no text, as
                // before when there were no lines at all.
                Task { [weak notepad, weak recorder, weak library] in
                    guard let t = await recorder?.recordingSeconds() else { return }
                    // The recording may have ended, or been replaced by
                    // another one, while the clock was read.
                    guard let recorder, recorder.state == .recording, let now = recorder.currentSession,
                          now.directory.standardizedFileURL.path == session.directory.standardizedFileURL.path
                    else { return }
                    let line = NotepadNotes.freshMomentLine(in: recorder.liveTranscriptModel, at: t)
                    let note = MeetingNote(id: UUID(), t: line?.start ?? t, kind: .moment, text: line?.displayText.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    if let notepad, let shown = notepad.meeting, shown.isRecording,
                       shown.folder.standardizedFileURL.path == now.directory.standardizedFileURL.path {
                        if let line {
                            notepad.momentLineIDs[note.id] = line.id
                        }
                        notepad.notes.append(note)
                        if let refusal = notepad.noteServices?.addNote(note) {
                            notepad.noteFailures[note.id] = refusal
                        }
                        return
                    }
                    // The notepad is on another meeting, or none: the
                    // moment still belongs to the recording, not to what
                    // is shown.
                    if let refusal = library?.addNote(note, identity: now.identity, folder: now.directory) {
                        AppLog.error("notepad", "moment not saved: \(refusal)")
                    }
                }
            }
        )
    }

    /// Projects the library's own `pendingNotes`/`noteFailures` onto the
    /// notepad's feed, by id, for every note this notepad knows of — except
    /// one whose last outcome never reached the library at all
    /// (`notepad.localNoteFailureIDs`), which keeps exactly what it was
    /// given. Removes a row only when it was asked to be deleted
    /// (`deletingNoteIDs`, set only once the library actually accepted that
    /// delete) and the library now shows neither a pending write nor a
    /// failure for it — never while still pending, even with no failure
    /// yet: a write parked behind the queue's own operation is pending with
    /// no failure the whole time it waits. A failure settles
    /// `deletingNoteIDs` too (the delete did not land, so the row is not
    /// "deleting" anymore) and `awaitingAddConfirmation`/`addFailedIDs` for
    /// an id whose in-flight write was an add.
    private func observeLibrary() {
        guard let library else { return }
        Publishers.CombineLatest(library.$pendingNotes, library.$noteFailures)
            .sink { [weak self] pending, failures in
                self?.scheduleReconcile(pending: pending, failures: failures)
            }
            .store(in: &cancellables)
    }

    private func scheduleReconcile(pending: Set<UUID>, failures: [UUID: MeetingLibrary.MarkFailure]) {
        pendingReconcile = (pending, failures)
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileScheduled = false
                guard let snapshot = self.pendingReconcile else { return }
                self.reconcile(pending: snapshot.pending, failures: snapshot.failures)
            }
        }
    }

    private func reconcile(pending: Set<UUID>, failures: [UUID: MeetingLibrary.MarkFailure]) {
        guard let notepad else { return }
        for note in notepad.notes {
            let id = note.id
            guard !notepad.localNoteFailureIDs.contains(id) else { continue }
            let isPending = pending.contains(id)
            if isPending {
                notepad.pendingNoteIDs.insert(id)
            } else {
                notepad.pendingNoteIDs.remove(id)
            }
            if let failure = failures[id] {
                notepad.noteFailures[id] = failure.reason
                deletingNoteIDs.remove(id)
                if awaitingAddConfirmation.contains(id) {
                    addFailedIDs.insert(id)
                    awaitingAddConfirmation.remove(id)
                }
            } else {
                notepad.noteFailures[id] = nil
                if !isPending {
                    if awaitingAddConfirmation.contains(id) {
                        addFailedIDs.remove(id)
                        awaitingAddConfirmation.remove(id)
                    }
                    if deletingNoteIDs.contains(id) {
                        deletingNoteIDs.remove(id)
                        notepad.notes.removeAll { $0.id == id }
                    }
                }
            }
        }
    }
}

/// ★ in the header: marks the words selected in a line, else the newest
/// line, at the recording's own time (see `.help` below). A click
/// activates Murmurly and the notepad panel, like any other click there, and
/// is disabled outside a recording.
struct MarkMomentButton: View {
    @ObservedObject var notepad: NotepadModel

    private var isRecording: Bool { notepad.meeting?.isRecording ?? false }

    var body: some View {
        Button {
            notepad.markMoment()
        } label: {
            Image(systemName: "star")
        }
        .buttonStyle(.plain)
        .disabled(!isRecording)
        .accessibilityIdentifier("markMomentButton")
        .accessibilityLabel(Text("Mark Moment"))
        .help(isRecording ? Text("Mark the selected words, or the newest line") : Text("Available while a meeting is being recorded"))
    }
}

/// The note-typing row under the feed. The time is captured on the first
/// character (`NoteDraftController`/`NoteDraftStamp`), not at Return.
struct NotesInputView: View {
    @ObservedObject var notepad: NotepadModel
    @StateObject private var controller: NoteDraftController

    init(notepad: NotepadModel) {
        self.notepad = notepad
        _controller = StateObject(wrappedValue: NoteDraftController(notepad: notepad))
    }

    var body: some View {
        TextField("Note…", text: $controller.text)
            .textFieldStyle(.plain)
            .onChange(of: controller.text) { _, _ in controller.textDidChange() }
            .onSubmit(controller.submit)
            .accessibilityIdentifier("notepadNoteField")
    }
}

/// One note or marked moment in the feed: its time (or "after the meeting"
/// for one with none), ★ for a moment, its text (or "Marked moment",
/// greyed, for one with none), "Saving…" while pending and a refusal's
/// reason. A double-click edits it in place; "Delete Note" and "Edit Note"
/// are in its context menu. All three are unavailable while the note has an
/// unfinished write of its own (`pendingNoteIDs`) — the row only says
/// "Saving…" until that settles, one way or the other.
struct NoteRow: View {
    let note: MeetingNote
    @ObservedObject var notepad: NotepadModel
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editFieldFocused: Bool

    private var isPending: Bool { notepad.pendingNoteIDs.contains(note.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let t = note.t {
                NotepadTimeButton(seconds: t, notepad: notepad)
            } else {
                Text("after the meeting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notepadNoteAfterMeeting")
            }
            if note.kind == .moment {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityIdentifier("notepadMomentStar")
            }
            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .focused($editFieldFocused)
                    .onSubmit(saveEdit)
                    .onExitCommand { isEditing = false }
                    .accessibilityIdentifier("notepadNoteEditField")
            } else if note.kind == .moment, note.text.isEmpty {
                Text("Marked moment")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notepadNote")
                    .onTapGesture(count: 2, perform: beginEditing)
            } else {
                Text(note.text)
                    .accessibilityIdentifier("notepadNote")
                    .onTapGesture(count: 2, perform: beginEditing)
            }
            if notepad.pendingNoteIDs.contains(note.id) {
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notepadNoteSaving")
            }
            if let reason = notepad.noteFailures[note.id] {
                Text(String(format: String(localized: "Not saved: %@"), reason))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("notepadNoteFailure")
            }
        }
        // Highlights a note found by the notepad's search
        // (`NotepadSearchBar.swift`), by id.
        .background(notepad.highlightedLineID == note.id ? Color.yellow.opacity(0.25) : Color.clear)
        .contextMenu {
            Button("Edit Note", action: beginEditing).disabled(isPending)
            Button("Delete Note", role: .destructive) {
                notepad.requestDelete(id: note.id)
            }
            .disabled(isPending)
        }
    }

    private func beginEditing() {
        guard !isPending else { return }
        editText = note.text
        isEditing = true
        // A double-click already activates the panel like any other click,
        // but "Edit Note" from the context menu reaches here from a
        // secondary click, which does not activate the app on its own, so
        // the panel must be told to take the keyboard itself.
        notepad.requestKeyboard()
        // The field exists only once the view re-renders with `isEditing`
        // true; focus is asked for on the next turn, the same pattern as
        // the meeting title's own rename (`MeetingsView.swift`).
        DispatchQueue.main.async { editFieldFocused = true }
    }

    /// While the note is still pending, Enter sends nothing and the typed
    /// text stays in the field: the write already in flight for this id
    /// must settle, one way or the other, before another one can start.
    private func saveEdit() {
        guard !isPending else { return }
        notepad.editNote(id: note.id, text: editText)
        isEditing = false
    }
}
