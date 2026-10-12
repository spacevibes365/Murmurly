import AppKit
import Foundation
import SwiftUI

struct ArchiveSnapshot: Equatable, Sendable {
    /// The chosen meetings folder and what it holds.
    struct MeetingsFolder: Equatable, Sendable {
        let path: String
        let available: Bool
        let count: Int
        let bytes: Int64
        /// Finished meetings still on this Mac: they move once it is available.
        let waiting: Int
    }

    let dictationCount: Int
    /// The index and the archive's own audio: a meeting or a document in its
    /// folder is not a dictation.
    let dictationBytes: Int64
    let dictationOldest: Date?
    /// Meetings on this Mac.
    let meetingCount: Int
    let meetingBytes: Int64
    let meetingOldest: Date?
    /// Nil when no meetings folder is chosen. Until a refresh hears from the
    /// folder it keeps the last one, which may be another folder's: the view
    /// matches it to the chosen folder by path.
    var meetingsFolder: MeetingsFolder? = nil
    /// The transcripts folder last checked and whether it was there; kept and
    /// matched the same way.
    var transcriptsFolderPath: String? = nil
    var transcriptsFolderAvailable = false

    /// What this Mac holds; the meetings folder is counted on its own.
    var totalCount: Int { dictationCount + meetingCount }
    /// Index lines or audio files of the archive's own, counted off the main
    /// actor; also while a folder of it can't be read. Other files in its
    /// folder (a meeting moved there) do not count.
    var dictationArchiveHasContent = false

    /// Something for Clear All: lines, or the archive's own files that a clear
    /// which failed halfway leaves without lines.
    var hasDictationFiles: Bool { dictationCount > 0 || dictationArchiveHasContent }
    var totalBytes: Int64 { dictationBytes + meetingBytes }
    var oldest: Date? {
        [dictationOldest, meetingOldest].compactMap { $0 }.min()
    }

    /// Publishes this Mac's figures first and the chosen folders' after
    /// them, so a slow or dead network volume never holds back the local
    /// ones. Another folder, a retry or a change cancels this refresh for a
    /// newer one; each publication checks it is still wanted, so a late
    /// answer from an old folder overwrites nothing. The disks are read off
    /// the main actor.
    @MainActor
    static func refresh(
        history: (count: Int, oldest: Date?),
        meetingsFolder: URL?,
        transcriptsFolder: URL?,
        previous: ArchiveSnapshot?,
        dictationsRoot: URL = DictationHistoryStore.defaultRoot(),
        meetingsRoot: URL = RecordingsStore.meetingsRoot(),
        loadFolder: @escaping @Sendable (_ folder: URL, _ meetingsRoot: URL) async -> MeetingsFolder = {
            ArchiveSnapshot.loadMeetingsFolder($0, meetingsRoot: $1)
        },
        publish: (ArchiveSnapshot) -> Void
    ) async {
        var snapshot = await Task.detached(priority: .utility) {
            ArchiveSnapshot.local(
                historyCount: history.count,
                historyOldest: history.oldest,
                dictationsRoot: dictationsRoot,
                meetingsRoot: meetingsRoot
            )
        }.value
        // Until the folders answer, their last figures stay.
        if meetingsFolder != nil { snapshot.meetingsFolder = previous?.meetingsFolder }
        if transcriptsFolder != nil {
            snapshot.transcriptsFolderPath = previous?.transcriptsFolderPath
            snapshot.transcriptsFolderAvailable = previous?.transcriptsFolderAvailable ?? false
        }
        guard !Task.isCancelled else { return }
        publish(snapshot)
        guard meetingsFolder != nil || transcriptsFolder != nil else { return }

        let folders = await Task.detached(priority: .utility) {
            var folder: MeetingsFolder?
            if let meetingsFolder { folder = await loadFolder(meetingsFolder, meetingsRoot) }
            return (folder, transcriptsFolder.map { MeetingStorage.isAvailable($0) } ?? false)
        }.value
        snapshot.meetingsFolder = folders.0
        snapshot.transcriptsFolderPath = transcriptsFolder?.path
        snapshot.transcriptsFolderAvailable = folders.1
        guard !Task.isCancelled else { return }
        publish(snapshot)
    }

    /// What this Mac holds, without the chosen folders.
    static func local(
        historyCount: Int,
        historyOldest: Date?,
        dictationsRoot: URL = DictationHistoryStore.defaultRoot(),
        meetingsRoot: URL = RecordingsStore.meetingsRoot()
    ) -> ArchiveSnapshot {
        let meetings = meetingSummary(at: meetingsRoot)
        let dictations = DictationHistoryStore.contentToClear(in: dictationsRoot)
        return ArchiveSnapshot(
            dictationCount: historyCount,
            dictationBytes: dictations.bytes,
            dictationOldest: historyOldest,
            meetingCount: meetings.count,
            meetingBytes: directorySize(at: meetingsRoot),
            meetingOldest: meetings.oldest,
            dictationArchiveHasContent: dictations.any
        )
    }

    /// The meetings folder may be on a network volume, and touching a dead
    /// one hangs the caller: never on the main actor.
    static func loadMeetingsFolder(_ folder: URL, meetingsRoot: URL) -> MeetingsFolder {
        let available = MeetingStorage.isAvailable(folder)
        let elsewhere = available ? meetingSummary(at: folder) : (count: 0, oldest: nil)
        return MeetingsFolder(
            path: folder.path,
            available: available,
            count: elsewhere.count,
            bytes: available ? directorySize(at: folder) : 0,
            waiting: finishedCount(at: meetingsRoot)
        )
    }

    private static func meetingSummary(at root: URL) -> (count: Int, oldest: Date?) {
        let fileManager = FileManager()
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, nil) }

        let sessionNames = children.compactMap { child -> String? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fileManager.fileExists(
                    atPath: child.appendingPathComponent("metadata.json").path
                  ) else { return nil }
            return child.lastPathComponent
        }
        let oldest = sessionNames.min().flatMap(meetingDate(from:))
        return (sessionNames.count, oldest)
    }

    private static func finishedCount(at root: URL) -> Int {
        let children = (try? FileManager().contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { MeetingStorage.finishedMetadata(in: $0) != nil }.count
    }

    private static func meetingDate(from directoryName: String) -> Date? {
        guard directoryName.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.date(from: String(directoryName.prefix(19)))
    }

    private static func directorySize(at root: URL) -> Int64 {
        let fileManager = FileManager()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

struct StorageSettingsView: View {
    let snapshot: ArchiveSnapshot?
    /// Why the last count failed; any figures shown are from an earlier one.
    let failure: String?
    /// Counts again, the folders' availability included.
    let recount: () -> Void
    @ObservedObject var meetings: MeetingTranscriptionQueue
    @EnvironmentObject private var settings: SettingsStore
    @State private var pickerWarning: String?

    private var archiveRoot: URL {
        DictationHistoryStore.defaultRoot().deletingLastPathComponent()
    }

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            summaryCard
            meetingPlaces
            archiveLocation
        }
    }

    /// The one card without a title: its figure is the heading.
    private var summaryCard: some View {
        SettingsGroup { summary }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.storageSummarySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsChrome.compactSpacing) {
                Text(snapshot.map { Self.byteText($0.totalBytes) } ?? Self.pendingCountText(failed: failure != nil))
                    .font(.system(size: SettingsChrome.storageTotalFontSize, weight: .semibold))
                    .monospacedDigit()
                if let snapshot {
                    Text(summaryDescription(snapshot))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            StorageCompositionBar(
                dictationBytes: snapshot?.dictationBytes ?? 0,
                meetingBytes: snapshot?.meetingBytes ?? 0
            )
            HStack(spacing: SettingsChrome.groupSpacing) {
                legend(
                    color: .blue,
                    title: String(localized: "Dictations"),
                    bytes: snapshot?.dictationBytes,
                    count: snapshot?.dictationCount
                )
                legend(
                    color: .red,
                    title: String(localized: "Meetings on this Mac"),
                    bytes: snapshot?.meetingBytes,
                    count: snapshot?.meetingCount
                )
            }
            if let folderLine = meetingsFolderLine {
                Text(folderLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: SettingsChrome.compactSpacing) {
                    VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                        warning(String(localized: "Couldn’t count the archive: \(failure)"))
                        if snapshot != nil {
                            Text("Figures from the last successful count")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Try Again", action: recount)
                        .accessibilityIdentifier("storageRetry")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }

    private var meetingPlaces: some View {
        SettingsGroup("Meetings") {
            placeRow(
                title: "Meetings folder",
                value: settings.meetingsFolderPath ?? String(localized: "On this Mac (default)"),
                note: settings.meetingsFolderPath == nil
                    ? "A finished meeting — once transcribed and compressed — can move to another folder: an external drive, a network share or an ordinary folder. Recording always happens on this Mac."
                    : "Finished meetings move here whole. While the folder is not available, they wait on this Mac.",
                choose: chooseMeetingsFolder,
                identifier: "meetingsFolder"
            ) {
                if let folder = settings.meetingDestinations.meetings {
                    revealButton(
                        folder,
                        available: checkedMeetingsFolder?.available == true,
                        identifier: "meetingsFolderReveal"
                    )
                    Button("Reset to Default") { settings.meetingsFolderPath = nil }
                        .help("New meetings will stay on this Mac; meetings already moved stay in the old folder")
                        .accessibilityIdentifier("meetingsFolderReset")
                }
            }
            if let waiting = waitingLine {
                Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
                HStack(alignment: .firstTextBaseline, spacing: SettingsChrome.compactSpacing) {
                    VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                        Text(waiting)
                            .font(.caption)
                        Text("They also move by themselves at launch, when a disk is connected, and after each recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Whatever the last check said: the scan checks the folder
                    // again, and so does each move.
                    if meetings.activeFolder == nil {
                        Button("Move Now") {
                            recount()
                            meetings.scanLocalFolders()
                        }
                        .accessibilityIdentifier("meetingsMoveNow")
                    }
                }
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                .padding(.vertical, SettingsChrome.rowVerticalPadding)
            }
            Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
            placeRow(
                title: "Copy transcripts to",
                value: settings.transcriptsFolderPath ?? String(localized: "Don’t copy"),
                note: "Each new transcript is copied there once, right after it is made, as “date time Meeting.md”. The app does not bring back a note you renamed or deleted there.",
                choose: chooseTranscriptsFolder,
                identifier: "transcriptsFolder"
            ) {
                if let folder = settings.meetingDestinations.transcripts {
                    revealButton(
                        folder,
                        available: snapshot?.transcriptsFolderPath == folder.path
                            && snapshot?.transcriptsFolderAvailable == true,
                        identifier: "transcriptsFolderReveal"
                    )
                    Button("Don’t Copy") { settings.transcriptsFolderPath = nil }
                        .accessibilityIdentifier("transcriptsFolderReset")
                }
            }
            Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
            VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                Text("After a recording stops and when the app starts, meeting tracks are compressed without loss — to 24 bits, like dictations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = meetings.statusLabel {
                    Text(status)
                }
                if let pickerWarning {
                    warning(pickerWarning)
                }
                ForEach(issueLines, id: \.self) { warning($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
        }
    }

    private func placeRow<Extra: View>(
        title: LocalizedStringKey,
        value: String,
        note: LocalizedStringKey,
        choose: @escaping () -> Void,
        identifier: String,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsChrome.compactSpacing) {
                Text(title)
                Spacer()
                Button("Choose…", action: choose)
                    .accessibilityIdentifier("\(identifier)Choose")
                extra()
            }
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }

    /// Opens only the folder it names, and only once the last check found it.
    private func revealButton(_ folder: URL, available: Bool, identifier: String) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            .disabled(!available)
            .help(available ? "" : String(localized: "The folder isn’t available right now"))
            .accessibilityIdentifier(identifier)
    }

    private func warning(_ line: String) -> some View {
        HStack(alignment: .top, spacing: SettingsChrome.compactSpacing) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(line).font(.caption)
        }
    }

    /// The snapshot's meetings folder if it is the chosen one.
    private var checkedMeetingsFolder: ArchiveSnapshot.MeetingsFolder? {
        guard let chosen = settings.meetingDestinations.meetings?.path,
              let folder = snapshot?.meetingsFolder, folder.path == chosen else { return nil }
        return folder
    }

    /// No line while no folder is chosen; no "Checking…" after a failed count,
    /// which never got to the folder.
    private var meetingsFolderLine: String? {
        guard settings.meetingDestinations.meetings != nil else { return nil }
        guard let folder = checkedMeetingsFolder else {
            return failure == nil ? String(localized: "Checking the meetings folder…") : nil
        }
        return folder.available
            ? String(localized: "In the meetings folder: \(Self.byteText(folder.bytes))")
                + " · " + String(localized: "\(folder.count) meetings")
            : String(localized: "The meetings folder is not available right now")
    }

    private var waitingLine: String? {
        Self.waitingLine(checkedMeetingsFolder, busy: meetings.activeFolder != nil, issues: meetings.issues)
    }

    /// "N meetings waiting to move: reason" while finished meetings are still here.
    /// A failed move is read from `Issues.move`, never from the issue's text:
    /// that text is shown to the user and changes with the language.
    static func waitingLine(
        _ folder: ArchiveSnapshot.MeetingsFolder?,
        busy: Bool,
        issues: [URL: MeetingTranscriptionQueue.Issues]
    ) -> String? {
        guard let folder, folder.waiting > 0 else { return nil }
        let reason = !folder.available
            ? String(localized: "the folder isn’t available — check the drive or network, then Move Now")
            : busy ? String(localized: "they move one at a time")
            : issues.values.contains { $0.move != nil } ? String(localized: "reasons below")
            : String(localized: "they will move at the next check")
        return String(localized: "\(folder.waiting) meetings waiting to move") + ": " + reason
    }

    /// One line per problem, oldest meeting first.
    private var issueLines: [String] {
        meetings.issues
            .sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
            .flatMap { folder, issues in issues.lines.map { "\(folder.lastPathComponent): \($0)" } }
    }

    private func chooseMeetingsFolder() {
        AppWindowController.chooseFolder(
            message: String(localized: "Where to move finished meetings"),
            prompt: String(localized: "Choose"),
            directory: settings.meetingDestinations.meetings
        ) { url in
            Task {
                let choice = await settings.chooseMeetingsFolder(url)
                guard choice != .superseded else { return }
                pickerWarning = Self.refusal(choice)
                if choice == .applied { meetings.scanLocalFolders() }
            }
        }
    }

    private func chooseTranscriptsFolder() {
        AppWindowController.chooseFolder(
            message: String(localized: "Where to copy meeting transcripts"),
            prompt: String(localized: "Choose"),
            directory: settings.meetingDestinations.transcripts
        ) { url in
            Task {
                let choice = await settings.chooseTranscriptsFolder(url)
                guard choice != .superseded else { return }
                pickerWarning = Self.refusal(choice)
            }
        }
    }

    /// Why a folder was refused; nil once one was taken. A superseded choice
    /// leaves the line as the later decision set it.
    private static func refusal(_ choice: SettingsStore.FolderChoice) -> String? {
        switch choice {
        case .applied, .superseded:
            nil
        case .insideLocalRoot:
            String(localized: "This folder can’t be chosen: meetings are recorded into it. Choose another one.")
        case .insideDictationArchive:
            String(localized: "This folder can’t be chosen: dictations are archived in it. Choose another one.")
        }
    }

    private var archiveLocation: some View {
        SettingsGroup("Where the archive is") {
            HStack(alignment: .top, spacing: SettingsChrome.compactSpacing) {
                Text(archiveRoot.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([archiveRoot])
                }
            }
            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
        }
    }

    private func legend(
        color: Color,
        title: String,
        bytes: Int64?,
        count: Int?
    ) -> some View {
        HStack(spacing: SettingsChrome.compactSpacing) {
            RoundedRectangle(cornerRadius: SettingsChrome.storageLegendCornerRadius)
                .fill(color)
                .frame(
                    width: SettingsChrome.storageLegendMarkerSize,
                    height: SettingsChrome.storageLegendMarkerSize
                )
            Text(verbatim: "\(title) · \(bytes.map(Self.byteText) ?? (failure == nil ? String(localized: "counting…") : "—")) · "
                + (count.map { $0.formatted() } ?? "—"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryDescription(_ snapshot: ArchiveSnapshot) -> String {
        let count = String(localized: "\(snapshot.totalCount) recordings")
        guard let oldest = snapshot.oldest else { return count }
        let date = oldest.formatted(.dateTime.day().month(.wide).year())
        return String(localized: "\(count) · since \(date)")
    }

    /// What stands for a figure not counted yet; after a failed count no
    /// count is running, so it does not say one is.
    static func pendingCountText(failed: Bool) -> String {
        failed ? String(localized: "Couldn’t count") : String(localized: "Counting…")
    }

    /// Decimal units in the interface language, as Finder shows sizes.
    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

private struct StorageCompositionBar: View {
    let dictationBytes: Int64
    let meetingBytes: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(dictationBytes + meetingBytes), 1)
            let hasBoth = dictationBytes > 0 && meetingBytes > 0
            let availableWidth = max(
                geometry.size.width - (hasBoth ? SettingsChrome.storageBarSegmentSpacing : 0),
                0
            )
            let dictationWidth = availableWidth * Double(dictationBytes) / total
            let meetingWidth = availableWidth * Double(meetingBytes) / total
            HStack(spacing: hasBoth ? SettingsChrome.storageBarSegmentSpacing : 0) {
                if dictationBytes > 0 { Color.blue.frame(width: dictationWidth) }
                if meetingBytes > 0 { Color.red.frame(width: meetingWidth) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: SettingsChrome.storageBarHeight)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.storageBarHeight / 2))
    }
}
