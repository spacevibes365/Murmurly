import AppKit
import SwiftUI

/// The Meetings section: the list beside the selected meeting's card. A
/// plain stack, not `HSplitView`: that one sized its panes by their widest
/// and pushed the window's content past both its edges.
struct MeetingsView: View {
    static let listWidth: CGFloat = 330
    static let cardMinWidth: CGFloat = 460
    /// The list, the divider and the card at its least: the window's
    /// least width counts it whole.
    static var minWidth: CGFloat { listWidth + 1 + cardMinWidth }

    @EnvironmentObject private var library: MeetingLibrary
    /// The Starred section: the same list, starred meetings only.
    let onlyStarred: Bool
    /// A deletion asked about: the sheet keeps its own plan, whatever is
    /// selected meanwhile.
    @State private var asked: MeetingLibrary.RemovalPlan?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField()
                MeetingList(onlyStarred: onlyStarred, ask: ask)
            }
            .frame(width: Self.listWidth)
            Divider()
            MeetingCard(ask: ask)
                .frame(minWidth: Self.cardMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $asked) { plan in
            RemovalSheet(plan: plan)
        }
        .sheet(item: Binding(get: { library.removalRecheck }, set: { if $0 == nil { library.dismissRemovalRecheck() } })) { plan in
            RemovalSheet(plan: plan)
        }
    }

    private func ask(_ folders: [URL], _ kind: MeetingLibrary.RemovalKind) {
        guard !folders.isEmpty else { return }
        asked = library.removalPlan(for: folders, kind: kind)
    }
}

/// Asks before anything goes to the Trash: what, how much, what else is in
/// the folders, what cannot go now and why.
private struct RemovalSheet: View {
    @EnvironmentObject private var library: MeetingLibrary
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let plan: MeetingLibrary.RemovalPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MeetingText.removalQuestion(plan))
                .font(.headline)
            if !plan.items.isEmpty {
                Text("Total: \(MeetingText.size(plan.bytes))")
                    .foregroundStyle(.secondary)
            }
            if plan.changed {
                Label("These meetings changed after you confirmed: check them again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !plan.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.items) { item in
                        Text(verbatim: MeetingText.title(item.meeting, marks: library.marks(of: item.meeting))
                            + " · " + MeetingText.size(item.target.bytes))
                        if !item.others.isEmpty {
                            Text("Also deleted: \(ListFormatter.localizedString(byJoining: item.others))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(plan.kind == .audio
                    ? LocalizedStringKey("Transcripts, names and stars stay.")
                    : "Everything in these folders goes to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if plan.kind == .meeting, let copies = settings.transcriptsFolderPath {
                    Text("Copies of transcripts in \(copies) are not touched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !plan.refused.isEmpty {
                Text("Can’t be deleted now:")
                    .font(.callout.weight(.semibold))
                ForEach(Array(plan.refused.enumerated()), id: \.offset) { _, refused in
                    Text(verbatim: MeetingText.title(refused.meeting, marks: library.marks(of: refused.meeting)) + " — " + refused.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("removalCancel")
                Button("Move to Trash") {
                    library.remove(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.items.isEmpty)
                .accessibilityIdentifier("removalConfirm")
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("removalSheet")
    }
}

// MARK: - List

private struct MeetingList: View {
    @EnvironmentObject private var library: MeetingLibrary
    @EnvironmentObject private var meeting: MeetingRecorder
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
    @EnvironmentObject private var settings: SettingsStore
    let onlyStarred: Bool
    let ask: ([URL], MeetingLibrary.RemovalKind) -> Void
    /// The row to bring into view once the list made anew as a search ended
    /// has its rows.
    @State private var scrollTarget: URL?

    private var searching: Bool { !library.searchQuery.isEmpty }

    /// While searching, only the meetings found.
    private func found(_ meetings: [MeetingLibrary.Meeting]) -> [MeetingLibrary.Meeting] {
        searching ? meetings.filter { library.searchMatches[$0.directory] != nil } : meetings
    }

    var body: some View {
        let meetings = found(onlyStarred ? library.starredMeetings : library.meetings)
        let outside = found(library.outsideMeetings)
        ScrollViewReader { proxy in
            List(selection: Binding(get: { library.selectedFolders }, set: { library.select($0) })) {
                folderLines
                if searching { searchLines(nothingFound: meetings.isEmpty && outside.isEmpty) }
                if let session = meeting.currentSession, !onlyStarred, !searching {
                    LiveRow(session: session)
                        .tag(MeetingLibrary.canonical(session.directory))
                }
                if !outside.isEmpty, !onlyStarred {
                    Section("Outside the Meetings Folder") {
                        ForEach(outside) { row($0).onAppear { rowsShown(proxy) } }
                    }
                }
                ForEach(MeetingLibrary.groups(meetings)) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { row($0).onAppear { rowsShown(proxy) } }
                    }
                }
            }
            .listStyle(.inset)
            // Rows the search left out and brought back kept the table's own
            // height of a row, their time, source and state cut off: a new
            // list as the search starts or ends measures every row again.
            .id(searching)
            // The new list starts at its top: once the search ends, the card's
            // meeting, or the first of several selected, is brought back into
            // view once the new list shows a row, so the scroll never comes
            // before the rows it scrolls to.
            .onChange(of: searching) { _, now in
                scrollTarget = now ? nil : firstSelected(in: outside + MeetingLibrary.groups(meetings).flatMap(\.meetings))
            }
            // ⌘⌫ as in Finder; only while the list has the focus, so typing a
            // name never deletes anything.
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers == .command, library.isCardShown, !library.selectedFolders.isEmpty else { return .ignored }
                ask(Array(library.selectedFolders), .meeting)
                return .handled
            }
            .overlay {
                if searching {
                    EmptyView()
                } else if onlyStarred, meetings.isEmpty, isSettled {
                    NoStarredMeetings()
                } else if meetings.isEmpty, meeting.currentSession == nil, library.outsideMeetings.isEmpty, isSettled {
                    EmptyMeetings()
                }
            }
            .accessibilityIdentifier("meetingList")
        }
    }

    /// A row of the list is on screen: the list has its rows, and the one
    /// waited for can be scrolled to, outside the table's own layout.
    private func rowsShown(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        scrollTarget = nil
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
    }

    /// The card's meeting, else the first of the selected in the list's order.
    private func firstSelected(in shown: [MeetingLibrary.Meeting]) -> URL? {
        if let selection = library.selection, shown.contains(where: { $0.directory == selection }) { return selection }
        return shown.first { library.selectedFolders.contains($0.directory) }?.directory
    }

    private func row(_ shown: MeetingLibrary.Meeting) -> some View {
        // The menu acts on the selection when the row is in it.
        let folders = library.selectedFolders.contains(shown.directory) ? Array(library.selectedFolders) : [shown.directory]
        return MeetingRow(meeting: shown)
            .tag(shown.directory)
            .contextMenu {
                Button("Delete Audio…") { ask(folders, .audio) }
                Button("Delete Meeting…") { ask(folders, .meeting) }
            }
    }

    /// What the search could not vouch for, and "no matches" only once
    /// everything was read.
    @ViewBuilder private func searchLines(nothingFound: Bool) -> some View {
        let state = library.searchState
        let lines = MeetingText.searchLines(state)
        if !lines.isEmpty || nothingFound && state.settled {
            Section {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.warning ? "exclamationmark.triangle.fill" : "magnifyingglass")
                            .foregroundStyle(line.warning ? Color.orange : Color.secondary)
                        Text(line.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if line.warning, !state.failed.isEmpty || !state.unreadable.isEmpty {
                            Button("Try Again") { library.retrySearch() }
                                .controlSize(.small)
                        }
                    }
                }
                if nothingFound, state.settled {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meetingSearchNothing")
                }
            }
            .accessibilityIdentifier("meetingSearchStatus")
        }
    }

    /// Nothing is being read and nothing failed: an empty list means no meetings.
    private var isSettled: Bool {
        MeetingText.isSettled(local: library.local, chosen: library.chosen, outside: library.outside)
    }

    /// What the list cannot vouch for: a folder being read again, one that
    /// does not answer or is not there, one that could not be read.
    @ViewBuilder private var folderLines: some View {
        let lines = MeetingText.folderLines(local: library.local, chosen: library.chosen, outside: library.outside)
        if !lines.isEmpty {
            Section {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.warning ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                            .foregroundStyle(line.warning ? Color.orange : Color.secondary)
                        Text(line.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if line.warning {
                            Button("Try Again") { library.refresh() }
                                .controlSize(.small)
                        }
                    }
                    .accessibilityIdentifier("meetingFolderStatus")
                }
            }
        }
    }
}

/// What came of the window's work that may end while the person is in
/// another section, above every section until dismissed: deletions, a
/// change of a meeting's marks that failed to save after it left the card,
/// and a save that ended while its meeting was not on the card.
struct MeetingNotices: View {
    @EnvironmentObject private var library: MeetingLibrary

    var body: some View {
        let any = !library.removalReport.isEmpty || library.markNotice != nil || library.exportNotice != nil
        if any {
            VStack(alignment: .leading, spacing: 6) {
                removalReport
                markNotice
                exportNotice
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    /// What became of the last deletions, until dismissed.
    @ViewBuilder private var removalReport: some View {
        if !library.removalReport.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.removalReport) { line in
                        Label {
                            Text(verbatim: MeetingText.removalLine(line))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: line.outcome == .trashed ? "trash" : "exclamationmark.triangle.fill")
                                .foregroundStyle(line.outcome == .trashed ? Color.secondary : Color.orange)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    library.dismissRemovalReport()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Hide Warning"))
                .accessibilityLabel(Text("Hide Warning"))
                .accessibilityIdentifier("removalReportHide")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("removalReport")
        }
    }

    /// A change of a meeting's marks that failed to save after it left the card.
    @ViewBuilder private var markNotice: some View {
        if let notice = library.markNotice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(MeetingText.markNotice(notice))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    library.dismissMarkNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Hide Warning"))
                .accessibilityLabel(Text("Hide Warning"))
                .accessibilityIdentifier("meetingMarkNoticeHide")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meetingMarkNotice")
        }
    }

    /// A save that ended while its meeting was not on the card.
    @ViewBuilder private var exportNotice: some View {
        if let notice = library.exportNotice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: notice.failure == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.failure == nil ? Color.secondary : Color.orange)
                Text(MeetingText.exportOutcome(notice))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    library.dismissExportNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(notice.failure == nil ? String(localized: "Hide") : String(localized: "Hide Warning"))
                .accessibilityLabel(notice.failure == nil ? Text("Hide") : Text("Hide Warning"))
                .accessibilityIdentifier("meetingExportNoticeHide")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meetingExportNotice")
        }
    }
}

/// A meeting's row: its title from the date, when and how long, where it
/// came from, how its transcription stands, its size.
private struct MeetingRow: View {
    @EnvironmentObject private var library: MeetingLibrary
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
    @EnvironmentObject private var recorder: MeetingRecorder
    let meeting: MeetingLibrary.Meeting

    var body: some View {
        let status = library.status(of: meeting)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(MeetingText.title(meeting, marks: library.marks(of: meeting)))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(MeetingText.size(meeting.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                StarButton(meeting: meeting)
            }
            Text(MeetingText.details(meeting, source: library.sourceName(of: meeting.trigger)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                StatusText(status: status)
                if let match = library.searchMatches[meeting.directory] {
                    Text(MeetingText.found(match))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meetingSearchCount")
                }
                if let audio = MeetingText.audioTag(meeting) {
                    Text(audio)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if library.isInBothPlaces(meeting) {
                    Text("In both places")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("A folder of this name is both on this Mac and in the meetings folder")
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(meeting.isShort ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meetingRow.\(meeting.name)")
    }
}

/// A meeting's star, in its row and on its card. Off with the reason as its
/// tooltip when the marks cannot be changed now.
private struct StarButton: View {
    @EnvironmentObject private var library: MeetingLibrary
    let meeting: MeetingLibrary.Meeting
    var identifier: String?

    var body: some View {
        let starred = library.marks(of: meeting)?.starred == true
        let refusal = library.markRefusal(for: meeting)
        Button {
            library.toggleStar(meeting)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(refusal != nil)
        .help(refusal ?? (starred ? String(localized: "Remove the star") : String(localized: "Star this meeting")))
        .accessibilityLabel(starred ? Text("Starred") : Text("Not starred"))
        .accessibilityIdentifier(identifier ?? "meetingStar.\(meeting.name)")
    }
}

/// The recording under way: its own row above the list, with its clock.
private struct LiveRow: View {
    @EnvironmentObject private var recorder: MeetingRecorder
    @EnvironmentObject private var library: MeetingLibrary
    let session: MeetingRecorder.Session

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.state == .stopping ? LocalizedStringKey("Saving the recording…") : "Recording now")
                    .fontWeight(.medium)
                // Only this row redraws every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingText.liveDetails(session, now: context.date, source: library.sourceName(of: session.trigger)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if recorder.state == .recording {
                Button("Stop") { recorder.toggle() }
                    .controlSize(.small)
                    .accessibilityIdentifier("meetingLiveStop")
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("meetingLiveRow")
    }
}

/// The Starred section with no star yet.
private struct NoStarredMeetings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No starred meetings")
                .font(.headline)
            Text("Click the star of a meeting to find it here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(24)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingsNoStarred")
    }
}

/// What to do when there is no meeting yet: what records one by itself, and
/// how to start one now.
private struct EmptyMeetings: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var recorder: MeetingRecorder

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No meetings yet")
                .font(.headline)
            Text(settings.autoRecordMeetings
                ? LocalizedStringKey("A meeting is recorded by itself when a call starts using the microphone.")
                : "Automatic recording is off: meetings are recorded only when you start them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let shortcut = settings.meetingShortcutDescription {
                Text("To record one now, press \(shortcut) or click below.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Record Meeting") { recorder.toggle() }
                .disabled(recorder.isBusy)
        }
        .font(.callout)
        .padding(24)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingsEmptyState")
    }
}

/// One line for where a transcription stands: the work under way first,
/// then what the last attempt left, then whether there is text.
private struct StatusText: View {
    let status: MeetingLibrary.Status

    var body: some View {
        let (text, symbol, color) = MeetingText.status(status)
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Card

private struct TranscribeTarget: Identifiable {
    let id: URL
}

/// A name being typed, for the meeting it was started on: its folder, and
/// the path it showed then.
private struct TitleEdit: Equatable {
    let identity: FolderIdentity?
    let path: String
    var text: String
}

/// The speakers' names being typed, for the meeting the sheet was opened
/// on: its folder, the path it showed then, and the labels its transcript
/// wrote, shown as placeholders.
private struct NamesEdit: Identifiable {
    let id = UUID()
    let identity: FolderIdentity?
    let path: String
    let labels: [MeetingAttempt.Source: String]
    let names: [MeetingAttempt.Source: String]
}

/// A new dictionary entry from the transcript: the text and the selection
/// taken together, as they were when it was asked for.
private struct DictionaryDraft: Identifiable {
    let id = UUID()
    let text: String
    let selected: String?
}

/// The selected meeting: what it is, what can be done with it, what went
/// wrong, and its transcript.
private struct MeetingCard: View {
    @EnvironmentObject private var library: MeetingLibrary
    @EnvironmentObject private var recorder: MeetingRecorder
    @EnvironmentObject private var meetingTranscripts: MeetingTranscriptionQueue
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelDownloader
    @State private var transcribeAgain: TranscribeTarget?
    @State private var titleEdit: TitleEdit?
    /// The names sheet: it stays over a change of section or meeting until
    /// its own buttons close it.
    @State private var namesEdit: NamesEdit?
    /// What the transcript has selected, for the text it was selected in.
    @State private var transcriptSelection: TranscriptTextView.Selection?
    /// The entry sheet from the transcript: like the names sheet, only its
    /// own buttons close it.
    @State private var dictionaryDraft: DictionaryDraft?
    /// Why the last name typed was not taken; shown until the next name or meeting.
    @State private var titleRefusal: String?
    @FocusState private var titleFocused: Bool
    /// The card itself, for Space; not the name being typed.
    @FocusState private var cardFocused: Bool
    /// The card's window, for Save As's panel.
    @State private var anchor = WindowAnchor()
    let ask: ([URL], MeetingLibrary.RemovalKind) -> Void

    var body: some View {
        Group {
            if library.selection == nil, library.selectedFolders.count > 1 {
                batchCard(Array(library.selectedFolders))
            } else if let selection = library.selection {
                if recorder.currentSession.map({ MeetingLibrary.canonical($0.directory) }) == selection,
                   let session = recorder.currentSession {
                    liveCard(session)
                } else if let meeting = library.meeting(at: selection) {
                    card(meeting)
                } else {
                    missing(MeetingText.missingMeeting(library.outside.first { $0.folder.path == selection.path }))
                }
            } else {
                placeholder(String(localized: "Select a meeting"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAnchor.Reader(anchor: anchor))
        .sheet(item: $transcribeAgain) { target in
            TranscribeAgainSheet(folder: target.id, settings: settings.snapshot, models: models)
        }
        .sheet(item: $namesEdit) { edit in
            NamesSheet(edit: edit)
        }
        .sheet(item: $dictionaryDraft) { draft in
            DictionaryEntrySheet(transcript: draft.text, selected: draft.selected) { library.section = .dictionary }
        }
        // As in Finder: Return, a click elsewhere or another meeting save the
        // name being typed; only Esc drops it.
        .onChange(of: library.selection) {
            titleRefusal = nil
            saveTitle()
        }
        // Another section: the hidden card gives up the focus, and the name
        // being typed is saved as by a click elsewhere.
        .onChange(of: library.isCardShown) { _, shown in
            guard !shown else { return }
            titleFocused = false
            cardFocused = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingCard")
    }

    /// A meeting the window could not read: what happened, where, and a retry.
    private func missing(_ line: MeetingText.StatusLine) -> some View {
        VStack(spacing: 10) {
            Text(line.text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if line.warning {
                Button("Try Again") { library.refresh() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingMissing")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveCard(_ session: MeetingRecorder.Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recorder.state == .stopping ? LocalizedStringKey("Saving the recording…") : "Recording now")
                .font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MeetingText.liveDetails(session, now: context.date, source: library.sourceName(of: session.trigger)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if recorder.state == .recording {
                Button("Stop Recording Meeting") { recorder.toggle() }
            }
            Text("The transcript appears here once the recording is saved and transcribed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    /// The name typed goes to the meeting it was typed on, whatever is
    /// selected now, before the draft is dropped; a refusal is shown.
    private func saveTitle() {
        guard let edit = titleEdit else { return }
        let refusal = library.rename(typedOn: edit.identity, at: edit.path, to: edit.text)
        titleEdit = nil
        titleRefusal = refusal.map { String(localized: "The name “\(edit.text)” wasn’t saved. \($0)") }
    }

    private func card(_ meeting: MeetingLibrary.Meeting) -> some View {
        let status = library.status(of: meeting)
        return VStack(alignment: .leading, spacing: 12) {
            header(meeting)
            actions(meeting, status: status)
            notes(meeting, status: status)
            transcript(meeting)
            if !meeting.otherFiles.isEmpty {
                Text("Also in this folder: \(ListFormatter.localizedString(byJoining: meeting.otherFiles))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("meetingOtherFiles")
            }
            PlayerBar(player: library.player, labels: library.trackLabels(of: meeting), approximate: approximateTimes)
        }
        .padding(20)
        // A click on the card's empty part ends the typing of a name, as a
        // click on anything that takes the focus does, and gives Space to
        // the player.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    titleFocused = false
                    cardFocused = true
                }
        }
        .focusable()
        .focused($cardFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard !titleFocused, library.isCardShown, library.player.isLoaded else { return .ignored }
            library.player.toggle()
            return .handled
        }
    }

    private var approximateTimes: Bool {
        if case .loaded(let transcript) = library.text, case .approximate = transcript.timing { return true }
        return false
    }

    private func header(_ meeting: MeetingLibrary.Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let edit = titleEdit, edit.path == meeting.directory.path {
                    TextField("Name", text: Binding(get: { edit.text }, set: { titleEdit?.text = $0 }))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($titleFocused)
                        .onSubmit { saveTitle() }
                        .onExitCommand { titleEdit = nil }
                        .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
                        .accessibilityIdentifier("meetingTitleField")
                } else {
                    Text(MeetingText.title(meeting, marks: library.marks(of: meeting)))
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Button {
                        titleRefusal = nil
                        titleEdit = TitleEdit(
                            identity: meeting.identity, path: meeting.directory.path, text: library.marks(of: meeting)?.title ?? ""
                        )
                        // Once the field exists, if the card is still shown.
                        DispatchQueue.main.async { if library.isCardShown { titleFocused = true } }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.markRefusal(for: meeting) != nil)
                    .help(library.markRefusal(for: meeting) ?? String(localized: "Rename — an empty name shows the date again"))
                    .accessibilityLabel(Text("Rename"))
                    .accessibilityIdentifier("meetingRename")
                }
                StarButton(meeting: meeting, identifier: "meetingCardStar")
                    .font(.title3)
                if !meeting.versions.isEmpty { namesButton(meeting) }
            }
            Text([MeetingText.details(meeting, source: library.sourceName(of: meeting.trigger)), MeetingText.size(meeting.bytes)]
                .joined(separator: " · "))
                .foregroundStyle(.secondary)
            Text(MeetingText.place(meeting))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(meeting.directory.path)
        }
    }

    /// The speakers' names, for a transcript whose record says which track
    /// each line came from; off with the reason otherwise.
    private func namesButton(_ meeting: MeetingLibrary.Meeting) -> some View {
        let refusal = library.markRefusal(for: meeting) ?? library.recordRefusal(for: meeting)
        return Button {
            let marks = library.marks(of: meeting)
            namesEdit = NamesEdit(
                identity: meeting.identity, path: meeting.directory.path,
                labels: library.writtenLabels(of: meeting), names: marks?.speakers ?? [:]
            )
        } label: {
            Image(systemName: "person.2")
        }
        .buttonStyle(.borderless)
        .disabled(refusal != nil)
        .help(refusal ?? String(localized: "Name the speakers"))
        .accessibilityLabel(Text("Speaker Names"))
        .accessibilityIdentifier("meetingNames")
    }

    /// Several meetings selected: how many, how much, and what can be done
    /// with all of them at once.
    private func batchCard(_ folders: [URL]) -> some View {
        let meetings = folders.compactMap { library.meeting(at: $0) }
        let bytes = meetings.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(meetings.count) meetings selected")
                .font(.title2.weight(.semibold))
            Text(MeetingText.size(bytes))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Delete Audio…") { ask(folders, .audio) }
                    .accessibilityIdentifier("batchDeleteAudio")
                Button("Delete Meetings…") { ask(folders, .meeting) }
                    .accessibilityIdentifier("batchDeleteMeetings")
            }
        }
        .padding(20)
    }

    @ViewBuilder private func actions(_ meeting: MeetingLibrary.Meeting, status: MeetingLibrary.Status) -> some View {
        let refusal = library.transcriptionRefusal(for: meeting.directory)
        let busy = status.operation != nil
        // One row while it fits; a long translation puts Transcribe under.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                folderActions(meeting)
                transcribeButton(meeting, status: status, off: refusal != nil || busy)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { folderActions(meeting) }
                transcribeButton(meeting, status: status, off: refusal != nil || busy)
            }
        }
        if let refusal, !busy {
            Text(refusal)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func folderActions(_ meeting: MeetingLibrary.Meeting) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([library.address(of: meeting.directory)])
        }
        .fixedSize()
        Menu {
            Button("Delete Audio…") { ask([meeting.directory], .audio) }
                .accessibilityIdentifier("meetingDeleteAudio")
            Button("Delete Meeting…") { ask([meeting.directory], .meeting) }
                .accessibilityIdentifier("meetingDeleteMeeting")
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .fixedSize()
        .accessibilityIdentifier("meetingDeleteMenu")
    }

    @ViewBuilder private func transcribeButton(_ meeting: MeetingLibrary.Meeting, status: MeetingLibrary.Status, off: Bool) -> some View {
        if status.hasTranscript || !models.missing(settings.dictationEngine).isEmpty {
            // With a transcript, or without the model to make one as
            // the settings say: engine and language first.
            Button(status.hasTranscript ? LocalizedStringKey("Transcribe Again…") : "Transcribe…") {
                transcribeAgain = TranscribeTarget(id: meeting.directory)
            }
            .fixedSize()
            .disabled(off)
            .accessibilityIdentifier("meetingTranscribeAgain")
        } else {
            Button("Transcribe") { library.transcribe(meeting.directory) }
                .fixedSize()
                .disabled(off)
                .accessibilityIdentifier("meetingTranscribe")
        }
    }

    /// The work under way, what the last attempt left, the recording's and
    /// the queue's warnings.
    @ViewBuilder private func notes(_ meeting: MeetingLibrary.Meeting, status: MeetingLibrary.Status) -> some View {
        let audio: [(String, Bool)] = (MeetingText.audioNote(meeting).map { [($0, false)] } ?? [])
            + (MeetingText.retentionNote(meeting, days: settings.meetingAudioRetention.rawValue).map { [($0, false)] } ?? [])
        let lines = MeetingText.notes(status) + audio + library.warnings(of: meeting).map { ($0, true) } + markNotes(meeting)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line.0)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: line.1 ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(line.1 ? Color.orange : Color.secondary)
                    }
                    .font(.callout)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meetingNotes")
        }
    }

    /// The meeting's marks: a name typed and not taken, being saved, not
    /// saved, or why they cannot be changed. True marks a warning.
    private func markNotes(_ meeting: MeetingLibrary.Meeting) -> [(String, Bool)] {
        if let titleRefusal { return [(titleRefusal, true)] }
        if library.isSavingMarks(meeting) {
            return [(String(localized: "Saving changes to this meeting…"), false)]
        }
        if let failure = library.markFailure(of: meeting) {
            return [(MeetingText.marksNotSaved(failure.lost, reason: failure.reason, meeting: nil), true)]
        }
        if case .read = meeting.marks { return [] }
        if case .none = meeting.marks { return [] }
        return library.markRefusal(for: meeting).map { [($0, true)] } ?? []
    }

    @ViewBuilder private func transcript(_ meeting: MeetingLibrary.Meeting) -> some View {
        if meeting.versions.isEmpty {
            Text(meeting.state == nil
                ? LocalizedStringKey("No transcript: the recording broke off before it was saved.") : "No transcript yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                versionLine(meeting)
                exportLine(meeting)
                textNotes(meeting)
                switch library.text {
                case .none, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let reason):
                    Text("Couldn’t read the transcript: \(reason)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .loaded(let transcript):
                    let shown = library.shownTranscript(of: meeting) ?? transcript
                    CardText(
                        player: library.player,
                        transcript: shown,
                        identity: textIdentity(meeting, shown),
                        query: library.searchQuery,
                        focusMatch: library.searchFocus == meeting.directory,
                        active: library.isCardShown,
                        didFocus: { library.searchFocused() },
                        onSelection: { transcriptSelection = $0 },
                        addToDictionary: { addToDictionary($0, of: meeting) }
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }
            }
        }
    }

    /// Which version, and what can be done with its text. On one row while
    /// it fits; the actions go under the version where a translation is
    /// too long for the card's width.
    @ViewBuilder private func versionLine(_ meeting: MeetingLibrary.Meeting) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                versionLabel(meeting)
                Spacer(minLength: 8)
                textActions(meeting)
            }
            VStack(alignment: .leading, spacing: 6) {
                versionLabel(meeting)
                HStack(spacing: 8) { textActions(meeting) }
            }
            VStack(alignment: .leading, spacing: 6) {
                versionLabel(meeting)
                HStack(spacing: 8) { textActions(meeting, dictionary: false) }
                dictionaryButton(meeting)
            }
        }
    }

    @ViewBuilder private func versionLabel(_ meeting: MeetingLibrary.Meeting) -> some View {
        if meeting.versions.count > 1 {
            Picker("Transcript", selection: Binding(
                get: { library.version ?? meeting.versions.last?.name ?? "" },
                set: { library.pick(version: $0) }
            )) {
                ForEach(meeting.versions.reversed()) { version in
                    Text(MeetingLibrary.label(of: version)).tag(version.name)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("meetingVersionPicker")
        } else if let version = meeting.versions.first {
            Text(MeetingLibrary.label(of: version))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The meeting, version and content shown; the names are part of the
    /// text: another name is another text.
    private func textIdentity(_ meeting: MeetingLibrary.Meeting, _ shown: MeetingTranscript) -> String {
        "\(meeting.directory.path)/\(library.version ?? "")/\(shown.raw.hashValue)/\(shown.namesNote ?? "")"
    }

    /// The selection, only while the text it was made in is the one shown
    /// and it holds words an entry could be made from.
    private func currentSelection(of meeting: MeetingLibrary.Meeting) -> TranscriptTextView.Selection? {
        guard let shown = library.shownTranscript(of: meeting), let selection = transcriptSelection,
              selection.identity == textIdentity(meeting, shown),
              shown.layout.dictionarySource(for: selection.ranges) != nil else { return nil }
        return selection
    }

    /// The text and the selection go to the sheet together, taken now; a
    /// selection made in another text than the one shown takes nothing.
    private func addToDictionary(_ selection: TranscriptTextView.Selection, of meeting: MeetingLibrary.Meeting) {
        guard let shown = library.shownTranscript(of: meeting), selection.identity == textIdentity(meeting, shown),
              let source = shown.layout.dictionarySource(for: selection.ranges) else { return }
        dictionaryDraft = DictionaryDraft(text: source.text, selected: source.selected)
    }

    /// What is done with the text shown: the user's names in it.
    @ViewBuilder private func textActions(_ meeting: MeetingLibrary.Meeting, dictionary: Bool = true) -> some View {
        if let shown = library.shownTranscript(of: meeting) {
            if dictionary { dictionaryButton(meeting) }
            Button("Copy Text") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(TranscriptTextView.attributed(shown).string, forType: .string)
            }
            .fixedSize()
            .accessibilityIdentifier("meetingCopyText")
            saveMenu(meeting)
        }
    }

    @ViewBuilder private func dictionaryButton(_ meeting: MeetingLibrary.Meeting) -> some View {
        if library.shownTranscript(of: meeting) != nil {
            let selection = currentSelection(of: meeting)
            Button("Add to Dictionary…") {
                if let selection { addToDictionary(selection, of: meeting) }
            }
            .fixedSize()
            .disabled(selection == nil)
            .help(selection == nil
                ? String(localized: "Select the words the engine got wrong first")
                : String(localized: "Add the selected words to the dictionary"))
            // A test sees which selection the card holds, so it checks the
            // button only once the card has taken the very selection made.
            .accessibilityValue(Text(verbatim: TestIsolation.isEnabled
                ? (transcriptSelection?.ranges ?? []).map { "\($0.location)+\($0.length)" }.joined(separator: ",") : ""))
            .accessibilityIdentifier("meetingAddToDictionary")
        }
    }

    /// Markdown and text always; subtitles only from the record's exact
    /// spans, and the reason in the menu otherwise, as a disabled item
    /// shows no help.
    private func saveMenu(_ meeting: MeetingLibrary.Meeting) -> some View {
        let refusal = library.subtitlesRefusal(for: meeting)
        return Menu {
            Button("Markdown…") { library.export(meeting, as: .markdown, from: anchor.window) }
                .accessibilityIdentifier("meetingSaveMarkdown")
            Button("Plain Text…") { library.export(meeting, as: .text, from: anchor.window) }
                .accessibilityIdentifier("meetingSaveText")
            Button("SRT Subtitles…") { library.export(meeting, as: .subtitles, from: anchor.window) }
                .disabled(refusal != nil)
                .accessibilityIdentifier("meetingSaveSubtitles")
            if let refusal {
                Text("Subtitles need exact line times: \(refusal)")
            }
        } label: {
            Text("Save As")
        }
        .fixedSize()
        .disabled(library.exporting != nil)
        .help(library.exporting != nil ? String(localized: "A transcript is being saved already.") : String(localized: "Save the transcript as a file"))
        .accessibilityIdentifier("meetingSaveAs")
    }

    /// The save under way, or what became of the last one, for the meeting
    /// and version shown.
    @ViewBuilder private func exportLine(_ meeting: MeetingLibrary.Meeting) -> some View {
        if let job = library.exporting, job.meeting == meeting.directory, job.version == library.version {
            Text("Saving “\(job.file)”…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meetingExportLine")
        } else if let outcome = library.exportOutcome, outcome.meeting == meeting.directory, outcome.version == library.version {
            Label {
                Text(MeetingText.exportOutcome(outcome))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: outcome.failure == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.failure == nil ? Color.secondary : Color.orange)
            }
            .font(.caption)
            .accessibilityIdentifier("meetingExportLine")
        }
    }

    /// Names kept for the meeting that the shown text cannot take, and why.
    @ViewBuilder private func textNotes(_ meeting: MeetingLibrary.Meeting) -> some View {
        if case .loaded = library.text, library.marks(of: meeting)?.speakers.isEmpty == false,
           let refusal = library.recordRefusal(for: meeting) {
            Label {
                Text("Speaker names aren’t shown in this transcript: \(refusal)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("meetingNamesNotShown")
        }
    }
}

/// The transcript with the player: the line being said lit while it
/// plays, and its timecodes playing from their line.
private struct CardText: View {
    @ObservedObject var player: MeetingPlayer
    let transcript: MeetingTranscript
    let identity: String
    let query: String
    let focusMatch: Bool
    let active: Bool
    let didFocus: () -> Void
    let onSelection: (TranscriptTextView.Selection) -> Void
    let addToDictionary: (TranscriptTextView.Selection) -> Void
    @State private var step = TranscriptTextView.MatchStep(id: 0, direction: 1)
    @State private var position = TranscriptTextView.MatchPosition()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !query.isEmpty, position.total > 0 {
                matchBar
            }
            text
        }
    }

    /// Which match is selected of how many, and the way to the next.
    private var matchBar: some View {
        HStack(spacing: 6) {
            Text(MeetingText.matchPosition(position.index, of: position.total))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meetingMatchPosition")
            Button { step = .init(id: step.id + 1, direction: -1) } label: { Image(systemName: "chevron.left") }
                .help(String(localized: "Previous match"))
                .accessibilityIdentifier("meetingMatchPrevious")
            Button { step = .init(id: step.id + 1, direction: 1) } label: { Image(systemName: "chevron.right") }
                .help(String(localized: "Next match"))
                .accessibilityIdentifier("meetingMatchNext")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var text: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: player.state != .playing)) { _ in
            let playable = player.isLoaded && transcript.timing != .untimed
            TranscriptTextView(
                transcript: transcript,
                identity: identity,
                currentLine: player.isLoaded ? transcript.timing.line(at: player.position) : nil,
                playLine: playable ? { index in
                    let starts = transcript.timing.starts
                    if starts.indices.contains(index) { player.play(from: starts[index]) }
                } : nil,
                togglePlayer: player.isLoaded ? { player.toggle() } : nil,
                query: query,
                focusMatch: focusMatch,
                didFocus: didFocus,
                active: active,
                step: step,
                onMatches: { position = $0 },
                onSelection: onSelection,
                addToDictionary: addToDictionary
            )
        }
    }
}

/// Above the list: searches the names and the newest transcripts of all
/// meetings; Return goes to the first match.
private struct SearchField: View {
    @EnvironmentObject private var library: MeetingLibrary
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search All Meetings", text: $library.searchQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { library.searchSubmitted() }
                // Hidden with its section, it takes no more typing.
                .onChange(of: library.isCardShown) { _, shown in if !shown { focused = false } }
                .accessibilityIdentifier("meetingSearchField")
            if !library.searchQuery.isEmpty {
                Button {
                    library.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Clear the search"))
                .accessibilityIdentifier("meetingSearchClear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        .padding(10)
    }
}

/// The meeting's audio: play and pause, 15 seconds back and on, where it
/// is, how fast, either side muted; why not, when it cannot play.
private struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer
    let labels: [MeetingAttempt.Source: String]
    let approximate: Bool
    /// Where the slider is held while it is dragged.
    @State private var scrub: TimeInterval?

    var body: some View {
        switch player.state {
        case .empty:
            EmptyView()
        case .unavailable(let reason):
            Label(reason, systemImage: "speaker.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meetingPlayerUnavailable")
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Opening the audio…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready, .playing:
            VStack(alignment: .leading, spacing: 4) {
                controls
                if let reason = player.held ?? player.refusal {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("meetingPlayerRefusal")
                }
                if approximate {
                    Text("Line times are approximate: they come from the transcript’s timecodes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meetingPlayer")
        }
    }

    /// One row while it fits, a slider wide enough to use included; long
    /// names of the speakers put speed and the tracks on a row of their own.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                transport
                rateAndTracks
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { transport }
                HStack(spacing: 10) { rateAndTracks }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var transport: some View {
        Button {
            player.toggle()
        } label: {
            Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                .frame(width: 16)
        }
        .help(player.state == .playing ? String(localized: "Pause") : String(localized: "Play"))
        .accessibilityLabel(player.state == .playing ? Text("Pause") : Text("Play"))
        .accessibilityValue(player.state == .playing ? Text(verbatim: "playing") : Text(verbatim: "paused"))
        // Off at once while a recording or a dictation holds it.
        .disabled(player.held != nil && player.state != .playing)
        .accessibilityIdentifier("meetingPlay")
        Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
            .help(String(localized: "Back 15 seconds"))
            .accessibilityIdentifier("meetingBack")
        Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15") }
            .help(String(localized: "Forward 15 seconds"))
            .accessibilityIdentifier("meetingOn")
        TimelineView(.animation(minimumInterval: 0.25, paused: player.state != .playing)) { _ in
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                    in: 0...max(player.duration, 1)
                ) { editing in
                    if !editing, let scrub {
                        player.seek(to: scrub)
                        self.scrub = nil
                    }
                }
                .frame(minWidth: 80)
                .accessibilityIdentifier("meetingPlayerPosition")
                Text(verbatim: MeetingText.clock(scrub ?? player.position) + " / " + MeetingText.clock(player.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meetingPlayerTime")
            }
        }
    }

    @ViewBuilder private var rateAndTracks: some View {
        Menu {
            ForEach(MeetingPlayer.rates, id: \.self) { rate in
                Button(MeetingText.rate(rate)) { player.setRate(rate) }
            }
        } label: {
            Text(verbatim: MeetingText.rate(player.rate))
        }
        .fixedSize()
        .help(String(localized: "Speed"))
        .accessibilityIdentifier("meetingPlayerRate")
        ForEach(player.sources.count > 1 ? player.sources : [], id: \.self) { source in
            Toggle(isOn: Binding(get: { !player.muted.contains(source) }, set: { _ in player.toggleMute(source) })) {
                // A name of the user's may be long: cut, whole in the help.
                // As wide as it is measured: a width the label took only
                // when offered more had the one-row player pass for fitting
                // a card it then went past.
                Text(verbatim: labels[source] ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 90)
            }
            .toggleStyle(.button)
            .help(String(localized: "Mute or unmute \(labels[source] ?? "")"))
            .accessibilityIdentifier("meetingPlayerTrack.\(source.rawValue)")
        }
    }
}

/// Engine and language for one transcription of the meeting the sheet was
/// opened for, from the settings as it opened; Transcribe waits for the
/// chosen engine's model, which it offers to download.
private struct TranscribeAgainSheet: View {
    @EnvironmentObject private var library: MeetingLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: MeetingTranscriptionQueue.ChoiceDraft
    @ObservedObject private var models: ModelDownloader
    /// Fixed as the sheet opens: whatever is selected later, this meeting.
    let folder: URL
    @State private var refusal: String?

    init(folder: URL, settings: SettingsSnapshot, models: ModelDownloader) {
        self.folder = folder
        self.models = models
        _draft = StateObject(wrappedValue: MeetingTranscriptionQueue.ChoiceDraft(settings, models: models))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcribe Again")
                .font(.headline)
                .padding([.top, .horizontal], 20)
            TranscriptionChoiceView(draft: draft, models: models)
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe") {
                    if library.transcribe(folder, choice: draft.choice) {
                        dismiss()
                    } else {
                        refusal = library.transcriptionRefusal(for: folder)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!models.missing(draft.engine).isEmpty)
                .accessibilityIdentifier("meetingSheetTranscribe")
            }
            .padding([.bottom, .horizontal], 20)
        }
        .frame(width: 460)
    }
}

/// Who speaks on each track of the meeting the sheet was opened on. The
/// transcripts keep their labels; the names are the meeting's own, in its
/// murmurly.json. A refusal stays in the sheet with what was typed.
private struct NamesSheet: View {
    @EnvironmentObject private var library: MeetingLibrary
    @Environment(\.dismiss) private var dismiss
    let edit: NamesEdit
    @State private var microphone: String
    @State private var system: String
    @State private var refusal: String?
    /// The write of a folder elsewhere, until it ends: the sheet stays with
    /// what was typed, its fields off so nothing typed meanwhile is lost
    /// unwritten, and a late refusal shows here with them on again.
    @State private var saving: Task<Void, Never>?

    init(edit: NamesEdit) {
        self.edit = edit
        _microphone = State(initialValue: edit.names[.microphone] ?? "")
        _system = State(initialValue: edit.names[.system] ?? "")
    }

    /// What no name may hold, said before Save is pressed.
    private var problem: String? {
        MeetingLibrary.speakerNameRefusal(microphone) ?? MeetingLibrary.speakerNameRefusal(system)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speaker Names")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Microphone")
                    TextField("", text: $microphone, prompt: Text(verbatim: edit.labels[.microphone] ?? ""))
                        .disabled(saving != nil)
                        .accessibilityLabel(Text("Microphone"))
                        .accessibilityIdentifier("meetingNamesMicrophone")
                }
                GridRow {
                    Text("System audio")
                    TextField("", text: $system, prompt: Text(verbatim: edit.labels[.system] ?? ""))
                        .disabled(saving != nil)
                        .accessibilityLabel(Text("System audio"))
                        .accessibilityIdentifier("meetingNamesSystem")
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("meetingNamesProblem")
            }
            Text("Shown in the window, in Copy Text and in saved files; the transcript files don’t change. An empty name shows the label again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meetingNamesRefusal")
            }
            HStack {
                if saving != nil {
                    ProgressView().controlSize(.small)
                    Text("Saving changes to this meeting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Closing it does not stop a write under way: a refusal then
                // shows on the card, or above the list, with the names.
                Button("Cancel") {
                    saving?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("meetingNamesCancel")
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || saving != nil)
                    .accessibilityIdentifier("meetingNamesSave")
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: microphone) { refusal = nil }
        .onChange(of: system) { refusal = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingNamesSheet")
    }

    /// Closes only once the names are on disk; a refusal, at once or late,
    /// stays here with the names as typed.
    private func save() {
        refusal = nil
        saving = Task {
            let answer = await library.saveNames(typedOn: edit.identity, at: edit.path, microphone: microphone, system: system)
            guard !Task.isCancelled else { return }
            saving = nil
            if let answer { refusal = answer } else { dismiss() }
        }
    }
}

// MARK: - Words

/// How a meeting is put into words, for its row and its card alike.
enum MeetingText {
    /// One line of what the list cannot vouch for; a warning offers Try Again.
    struct StatusLine: Hashable {
        let text: String
        let warning: Bool
    }

    /// Nothing is being read and nothing failed: an empty list means no meetings.
    /// Only once every folder it needs was read: a meetings folder or a
    /// meeting asked for outside both that is away, failed or still being
    /// read leaves the list's emptiness unproven.
    static func isSettled(
        local: MeetingLibrary.Listing, chosen: MeetingLibrary.Listing?, outside: [MeetingLibrary.Listing]
    ) -> Bool {
        ([local] + [chosen].compactMap { $0 } + outside).allSatisfy { $0.state == .read && !$0.reading }
    }

    /// The card of a selected meeting the list does not hold (yet): read on
    /// its own, it says what became of that read, with its address.
    static func missingMeeting(_ listing: MeetingLibrary.Listing?) -> StatusLine {
        guard let listing, !listing.reading || listing.notResponding else {
            return StatusLine(text: String(localized: "Reading the meeting…"), warning: false)
        }
        return outsideLine(listing)
            ?? StatusLine(text: String(localized: "The meeting folder isn’t available: \(listing.folder.path)"), warning: true)
    }

    /// A meeting read on its own that did not answer, is not there or failed.
    private static func outsideLine(_ listing: MeetingLibrary.Listing) -> StatusLine? {
        let path = listing.folder.path
        if listing.notResponding {
            return StatusLine(text: String(localized: "The meeting folder isn’t responding: \(path)"), warning: true)
        }
        switch listing.state {
        case .unavailable:
            return StatusLine(text: String(localized: "The meeting folder isn’t available: \(path)"), warning: true)
        case .failed(let reason):
            return StatusLine(text: String(localized: "Couldn’t read the meeting folder \(path): \(reason)"), warning: true)
        case .read, .notRead:
            return nil
        }
    }

    static func folderLines(
        local: MeetingLibrary.Listing, chosen: MeetingLibrary.Listing?, outside: [MeetingLibrary.Listing]
    ) -> [StatusLine] {
        var lines: [StatusLine] = []
        if case .failed(let reason) = local.state {
            lines.append(StatusLine(text: String(localized: "Couldn’t read the meetings on this Mac: \(reason)"), warning: true))
        }
        if let chosen = chosen {
            let path = chosen.folder.path
            if chosen.notResponding {
                lines.append(StatusLine(text: String(localized: "The meetings folder isn’t responding: \(path)"), warning: true))
            } else if chosen.state == .unavailable {
                lines.append(StatusLine(text: String(localized: "The meetings folder isn’t available: \(path)"), warning: true))
            } else if case .failed(let reason) = chosen.state {
                lines.append(StatusLine(text: String(localized: "Couldn’t read the meetings folder: \(reason)"), warning: true))
            }
        }
        lines += outside.compactMap(outsideLine)
        let listings = [local] + [chosen].compactMap { $0 }
        if lines.isEmpty, listings.contains(where: { $0.reading && !$0.fresh }) {
            lines.append(StatusLine(text: String(localized: "Updating…"), warning: false))
        }
        return lines
    }

    /// What the search could not vouch for.
    static func searchLines(_ state: MeetingLibrary.SearchState) -> [StatusLine] {
        var lines: [StatusLine] = []
        if state.waiting > 0 {
            lines.append(StatusLine(text: String(localized: "Searching: \(state.waiting) transcripts left to read…"), warning: false))
        }
        if !state.failed.isEmpty {
            lines.append(StatusLine(
                text: String(localized: "Not searched, the transcript can’t be read: \(ListFormatter.localizedString(byJoining: state.failed))"),
                warning: true
            ))
        }
        if !state.unreadable.isEmpty {
            lines.append(StatusLine(
                text: String(localized: "Not searched, the meeting’s folder can’t be read: \(ListFormatter.localizedString(byJoining: state.unreadable))"),
                warning: true
            ))
        }
        for folder in state.unknownFolders {
            lines.append(StatusLine(text: String(localized: "Not searched, the folder wasn’t read: \(folder)"), warning: true))
        }
        if state.updating, lines.isEmpty {
            lines.append(StatusLine(text: String(localized: "Updating…"), warning: false))
        }
        return lines
    }

    /// "2 of 7"; "7 matches" while none is selected.
    static func matchPosition(_ index: Int?, of total: Int) -> String {
        guard let index else { return String(localized: "\(total) matches") }
        return String(localized: "\(index + 1) of \(total)", comment: "A search match selected in a transcript, of how many")
    }

    /// A meeting found: how often in its text, or in its name.
    static func found(_ match: MeetingLibrary.SearchMatch) -> String {
        match.count > 0 ? String(localized: "\(match.count) matches") : String(localized: "In the name")
    }

    /// The row's word about the audio when it is not all there.
    static func audioTag(_ meeting: MeetingLibrary.Meeting) -> String? {
        switch meeting.audio {
        case .known(let files, _) where files.isEmpty: String(localized: "No audio")
        case .known(_, let missing) where !missing.isEmpty: String(localized: "Audio incomplete")
        case .known: nil
        case .unknown: meeting.readable ? String(localized: "Audio unknown") : nil
        }
    }

    /// The card's line about the audio when it is not all there.
    static func audioNote(_ meeting: MeetingLibrary.Meeting) -> String? {
        switch meeting.audio {
        case .known(let files, _) where files.isEmpty:
            String(localized: "The audio was deleted; the transcripts stay.")
        case .known(_, let missing) where !missing.isEmpty:
            String(localized: "Part of the audio is gone: \(ListFormatter.localizedString(byJoining: missing)).")
        case .known: nil
        case .unknown(let reason): meeting.readable && !reason.isEmpty ? String(localized: "The audio can’t be told: \(reason)") : nil
        }
    }

    /// What the audio rule will do with the meeting, while there is a rule
    /// and audio: when its audio goes, or why it stays.
    static func retentionNote(_ meeting: MeetingLibrary.Meeting, days: Int, now: Date = Date()) -> String? {
        guard days > 0, let files = meeting.audio.files, !files.isEmpty else { return nil }
        switch meeting.retention {
        case .eligible(let since, _):
            let when = since.addingTimeInterval(TimeInterval(days) * 86_400)
            return when <= now
                ? String(localized: "The audio is deleted at the next check.")
                : String(localized: "The audio will be deleted on \(when.formatted(date: .abbreviated, time: .omitted)).")
        case .kept(let reason), .unknown(let reason):
            return reason.isEmpty ? nil : String(localized: "The audio is kept: \(reason)")
        }
    }

    /// The question of a deletion sheet.
    static func removalQuestion(_ plan: MeetingLibrary.RemovalPlan) -> String {
        switch plan.kind {
        case .audio: String(localized: "Move the audio of \(plan.items.count) meetings to the Trash?")
        case .meeting: String(localized: "Move \(plan.items.count) meetings to the Trash?")
        }
    }

    /// One line of what became of a deletion.
    static func removalLine(_ line: MeetingLibrary.RemovalLine) -> String {
        let name = line.folder.lastPathComponent
        switch line.outcome {
        case .trashed:
            return line.kind == .audio
                ? String(localized: "\(name): the audio is in the Trash") : String(localized: "\(name): in the Trash")
        case .noTrash:
            return name + ": " + MeetingStorage.Removal.Failure.noTrash.localizedDescription
        case .stopped(let reason, let trashed, let left, _):
            return String(localized: "\(name): stopped — \(reason). In the Trash: \(trashed.count); left: \(ListFormatter.localizedString(byJoining: left))")
        case .refused(let reason):
            return String(localized: "\(name): not deleted — \(reason)")
        }
    }

    /// A transcript saved as a file, or not and why.
    static func exportOutcome(_ outcome: MeetingLibrary.ExportOutcome) -> String {
        guard let failure = outcome.failure else { return String(localized: "Saved “\(outcome.file)”.") }
        return String(localized: "“\(outcome.file)” wasn’t saved: \(failure)")
    }

    /// The window's line for a name or star whose save failed off screen.
    static func markNotice(_ notice: MeetingLibrary.MarkNotice) -> String {
        marksNotSaved(notice.lost, reason: notice.reason, meeting: notice.meeting)
    }

    /// Marks that did not reach murmurly.json, and why, naming what was
    /// typed. `meeting`: its title, when the line is not on its card.
    static func marksNotSaved(_ lost: MeetingMarks.Change, reason: String, meeting: String?) -> String {
        let names = [MeetingAttempt.Source.microphone, .system].compactMap { lost.speakers[$0] ?? nil }
        if names.count == 2 { return String(localized: "The names “\(names[0])” and “\(names[1])” weren’t saved: \(reason)") }
        if let name = names.first { return String(localized: "The speaker’s name “\(name)” wasn’t saved: \(reason)") }
        if let title = lost.title ?? nil, !title.isEmpty { return String(localized: "The name “\(title)” wasn’t saved. \(reason)") }
        if let meeting { return String(localized: "Changes to “\(meeting)” weren’t saved: \(reason)") }
        return String(localized: "Changes to this meeting weren’t saved: \(reason)")
    }

    /// A title starts with a capital, as the group above it does: Russian
    /// writes the weekday in lower case.
    /// The user's own name for the meeting, else the date it started: the
    /// date is never saved as a name.
    static func title(_ meeting: MeetingLibrary.Meeting, marks: MeetingMarks?) -> String {
        if let title = marks?.title { return title }
        guard let date = meeting.startedAt else { return meeting.name }
        let title = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Time · length · who started it.
    static func details(_ meeting: MeetingLibrary.Meeting, source: String?) -> String {
        [
            meeting.startedAt?.formatted(date: .omitted, time: .shortened),
            meeting.duration.map(length) ?? "—",
            source ?? "—",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func liveDetails(_ session: MeetingRecorder.Session, now: Date, source: String?) -> String {
        [
            session.startedAt.map { $0.formatted(date: .omitted, time: .shortened) },
            session.startedAt.map { length(max(0, now.timeIntervalSince($0))) },
            source,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// A place on the player's timeline: `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// "1×", "1.25×", "0.75×", in the reader's numbers.
    static func rate(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func length(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    /// Unknown when part of the folder could not be read: never a guess.
    static func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "size unknown")
    }

    static func place(_ meeting: MeetingLibrary.Meeting) -> String {
        switch meeting.place {
        case .local: String(localized: "On this Mac")
        case .chosen: String(localized: "In the meetings folder")
        case .outside: String(localized: "Outside the meetings folder: \(meeting.directory.path)")
        }
    }

    /// The row's one line. The check mark only for a transcript its record
    /// proves complete; text without such proof says completeness is unknown,
    /// one with gaps warns.
    static func status(_ status: MeetingLibrary.Status) -> (String, String, Color) {
        switch status.operation {
        case .starting?: return (String(localized: "Starting…"), "record.circle", .red)
        case .recording?: return (String(localized: "Recording now"), "record.circle.fill", .red)
        case .saving?: return (String(localized: "Saving the recording…"), "hourglass", .secondary)
        case .queued?: return (String(localized: "Waiting to be transcribed"), "clock", .secondary)
        case .working(let step)?: return (step, "gearshape", .blue)
        case nil: break
        }
        if status.unreadable { return (String(localized: "Folder can’t be read"), "exclamationmark.triangle.fill", .orange) }
        switch status.outcome {
        case .incomplete(let cutShort, _, let missing)?:
            if cutShort { return (String(localized: "Transcript cut short"), "exclamationmark.triangle.fill", .orange) }
            if !missing.isEmpty { return (String(localized: "Transcript without one track"), "exclamationmark.triangle.fill", .orange) }
            return (String(localized: "Transcript with gaps"), "exclamationmark.triangle.fill", .orange)
        case .noSpeech?: return (String(localized: "No speech found"), "speaker.slash", .secondary)
        case .failed?:
            return (String(localized: "Transcription failed"), "exclamationmark.triangle.fill", .orange)
        case .interrupted?:
            return (String(localized: "Transcription did not finish"), "exclamationmark.triangle.fill", .orange)
        case .complete?:
            if status.hasTranscript { return (String(localized: "Fully transcribed"), "checkmark.circle", .green) }
        case .unknown?, nil: break
        }
        // A transcript with no record of its attempt, or with one that can't
        // be read: there is text, but nothing proves it covers the meeting.
        if status.hasTranscript { return (String(localized: "Transcribed, completeness unknown"), "doc.text", .secondary) }
        if status.brokenOff { return (String(localized: "Recording broke off"), "exclamationmark.triangle.fill", .orange) }
        return (String(localized: "Not transcribed"), "circle", .secondary)
    }

    /// The card's lines on the work under way and the last attempt; true marks a warning.
    static func notes(_ status: MeetingLibrary.Status) -> [(String, Bool)] {
        var lines: [(String, Bool)] = []
        switch status.operation {
        case .queued?: lines.append((String(localized: "Waiting to be transcribed"), false))
        case .working(let step)?: lines.append((step, false))
        case .saving?: lines.append((String(localized: "Saving the recording…"), false))
        case .starting?, .recording?, nil: break
        }
        switch status.outcome {
        case .incomplete(let cutShort, let failed, let missing)?:
            if cutShort { lines.append((String(localized: "The last transcription broke off; its header says where."), true)) }
            if failed > 0 { lines.append((String(localized: "\(failed) pieces of the last transcription weren’t recognized."), true)) }
            for track in missing {
                lines.append((track == .microphone
                    ? String(localized: "The last transcription had no microphone track.")
                    : String(localized: "The last transcription had no system audio track."), true))
            }
        case .noSpeech?: lines.append((String(localized: "The last transcription found no speech."), false))
        case .failed(let reason)?: lines.append((String(localized: "The last transcription failed: \(reason)"), true))
        case .interrupted?:
            lines.append((String(localized: "The last transcription did not finish: the app quit or its result could not be saved."), true))
        case .unknown?: lines.append((String(localized: "The record of the last transcription can’t be read."), true))
        case nil where status.hasTranscript:
            lines.append((String(localized: "Transcribed before Murmurly kept a record of its transcriptions: whether the text covers the whole meeting is not known."), false))
        case .complete?, nil: break
        }
        if status.brokenOff {
            lines.append((String(localized: "The recording broke off before it was saved; what was recorded is in the folder."), true))
        }
        if status.unreadable {
            lines.append((String(localized: "The meeting’s folder can’t be read: check its permissions, or the disk it is on."), true))
        }
        return lines
    }
}
