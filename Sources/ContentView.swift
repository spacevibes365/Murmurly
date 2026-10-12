import SwiftUI
import UniformTypeIdentifiers

/// One file through the meeting pipeline; the probe swaps in a stand-in.
typealias FileTranscription = @Sendable (
    URL, _ progress: @escaping @Sendable (MeetingTranscriber.Step) async -> Void
) async throws -> [TranscriptSegment]

/// The Files tab's state, owned by the app rather than its window: closing the
/// window neither stops a run nor loses its text (a design decision). In memory
/// only; quitting is what loses an unsaved result, and the app says so.
@MainActor
final class FilesModel: ObservableObject {
    /// What waits for the user's answer before it may replace unsaved text.
    struct Replacement: Equatable {
        enum Action: Equatable {
            case file(URL)
            case rerun
        }

        let action: Action
        /// The result the user agreed to drop; a newer one is not theirs to
        /// lose unasked.
        let revision: Int
    }

    /// Where to save a .md, given the name to suggest; nil when the user
    /// cancelled. The real one is a panel, a stand-in in tests.
    typealias SaveDestination = @MainActor (_ suggestedName: String) async -> URL?

    /// Text, name and revision taken together before the panel: whatever
    /// lands while it is up, this save belongs to the result shown when asked.
    private struct SaveRequest {
        let markdown: String
        let name: String
        let revision: Int
    }

    @Published private(set) var fileURL: URL?
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var status = ""
    @Published private(set) var errorText: String?
    @Published private(set) var isTranscribing = false
    /// Shown as a sheet until answered; cleared when the window goes.
    @Published var pendingReplacement: Replacement?
    /// Grows with every change of the result; `savedRevision` is the result
    /// last written to a .md. Copying is not saving: the clipboard keeps nothing.
    @Published private(set) var resultRevision = 0
    @Published private(set) var savedRevision = 0
    @Published private(set) var savedName: String?

    private let makeTranscription: @MainActor () -> FileTranscription?
    private let saveDestination: SaveDestination
    private var currentTask: Task<Void, Never>?
    private var runToken = 0
    private var activeRunToken: Int?
    /// Bumped by every new selection and started run: a drop answered after
    /// that is stale and must not touch the tab.
    private var selectionToken = 0
    /// The file the shown transcript was made from; the save name follows it,
    /// not whatever is selected now.
    private var resultURL: URL?
    /// The message of the last save that failed, while it is shown.
    private var saveFailure: String?

    /// `transcription` is asked at the start of every run; nil means the model
    /// is not downloaded.
    init(
        transcription: @escaping @MainActor () -> FileTranscription?,
        saveDestination: @escaping SaveDestination = FilesModel.askWhereToSave
    ) {
        makeTranscription = transcription
        self.saveDestination = saveDestination
    }

    /// The dictation's engine through the meeting pipeline, so a file gets the
    /// same model, chunking and timecodes as a call, and nothing evicts the
    /// model the dictation keeps warm.
    static func live(settings: SettingsStore, models: ModelDownloader) -> FilesModel {
        #if DEBUG
        let saveDestination = FileProbe.saveDestination() ?? askWhereToSave
        #else
        let saveDestination: SaveDestination = askWhereToSave
        #endif
        return FilesModel(transcription: {
            #if DEBUG
            if let probe = FileProbe.transcription() { return probe }
            #endif
            guard models.missing(settings.dictationEngine).isEmpty else { return nil }
            AppLog.info("run", "engine=\(settings.dictationEngine.rawValue)")
            return Self.transcription(MeetingTranscriber.live(settings: settings, models: models))
        }, saveDestination: saveDestination)
    }

    nonisolated static func transcription(_ transcriber: MeetingTranscriber) -> FileTranscription {
        { url, progress in
            try await transcriber.transcribeFile(url, report: progress).map(TranscriptSegment.init)
        }
    }

    static var modelMissingText: String {
        String(localized: "Model not downloaded: “M” menu → “Download Model…”")
    }

    var hasUnsavedText: Bool { !segments.isEmpty && savedRevision != resultRevision }

    /// What quitting now would lose here; the app's quit warns about it.
    var quitLosses: Set<AppDelegate.QuitLoss> {
        var losses: Set<AppDelegate.QuitLoss> = []
        if isTranscribing { losses.insert(.fileTranscription) }
        if hasUnsavedText { losses.insert(.unsavedFileText) }
        return losses
    }

    /// The name of the .md holding exactly the text shown, if there is one.
    var savedAs: String? { !segments.isEmpty && savedRevision == resultRevision ? savedName : nil }

    // MARK: - selection and runs

    func select(_ url: URL) {
        guard !isTranscribing else { return }
        if hasUnsavedText {
            pendingReplacement = Replacement(action: .file(url), revision: resultRevision)
        } else {
            apply(url)
        }
    }

    func start() {
        guard !isTranscribing, fileURL != nil else { return }
        if hasUnsavedText {
            pendingReplacement = Replacement(action: .rerun, revision: resultRevision)
        } else {
            run()
        }
    }

    /// The user agreed, by "Replace" or by saving first. Only for the result
    /// they were asked about: one that landed since is left alone.
    func replace(with replacement: Replacement) {
        if pendingReplacement == replacement { pendingReplacement = nil }
        guard replacement.revision == resultRevision else {
            AppLog.info("ui", "replacement dropped: the result changed since it was asked for")
            return
        }
        switch replacement.action {
        case .file(let url):
            guard !isTranscribing else { return }
            apply(url)
        case .rerun:
            run()
        }
    }

    /// "Save .md…" in the sheet: the replacement goes ahead only once the very
    /// result it was asked about is on disk. A cancelled panel or a failed
    /// write stops here; a result that landed while the panel was up fails the
    /// revision check in `replace`, and the save, taken before the panel,
    /// holds the agreed result, never the newer one.
    func saveThenReplace(_ replacement: Replacement) async {
        guard await saveTranscript() else { return }
        replace(with: replacement)
    }

    func cancel() {
        currentTask?.cancel()
    }

    private func apply(_ url: URL) {
        fileURL = url
        show([], from: nil)
        errorText = nil
        status = ""
    }

    private func run() {
        guard !isTranscribing, let url = fileURL else { return }   // no overlapping runs
        // All before the task starts: a drop answered from here on is stale,
        // and the run keeps the file it was started for.
        selectionToken &+= 1
        isTranscribing = true
        errorText = nil
        show([], from: nil)
        // Covers the speech detection model loading too; the previous run's
        // "Done" would otherwise stay under the new spinner.
        status = String(localized: "Starting…")
        runToken &+= 1
        let token = runToken
        activeRunToken = token
        currentTask = Task { await runTranscription(url: url, token: token) }
    }

    private func runTranscription(url: URL, token: Int) async {
        guard let transcribe = makeTranscription() else {
            finish(token: token, url: url, segments: [], status: "", error: Self.modelMissingText)
            return
        }
        AppLog.info("run", "start file=\(url.lastPathComponent)")
        do {
            let result = try await transcribe(url) { [weak self] step in
                guard let text = Self.statusText(for: step) else { return }
                await self?.show(text, token: token)
            }
            // Engine already produced text. If cancelled now, keep it rather
            // than throwing the completed work away.
            if Task.isCancelled {
                finish(token: token, url: url, segments: result, status: result.isEmpty
                       ? String(localized: "Cancelled.")
                       : String(localized: "Cancelled — the text so far is above"))
                return
            }

            let finalStatus = result.isEmpty
                ? String(localized: "Done — no speech detected.")
                : String(localized: "Done — \(result.count) lines.")
            finish(token: token, url: url, segments: result, status: finalStatus)
            AppLog.info("run", "done: \(result.count) segments")
        } catch let failure as MeetingTranscriber.Failure {
            let lines: [MeetingTranscriber.Utterance]
            let status: String
            switch failure {
            case let .incompleteFile(found, failed, _):
                lines = found
                status = String(localized: "Done with gaps — \(found.count) lines.")
                    + " " + String(localized: "Pieces not recognized: \(failed).")
            case let .fileCutShort(found, _, _):
                lines = found
                status = String(localized: "Stopped partway — \(found.count) lines.")
            default:
                return fail(token: token, url: url, error: failure)
            }
            // Shown and saved with the note on top, so a gap or a missing end
            // is never mistaken for the whole file.
            let note = TranscriptSegment(speaker: "", text: "⚠︎ \(failure.localizedDescription).")
            finish(token: token, url: url, segments: [note] + lines.map(TranscriptSegment.init), status: status)
            AppLog.error("run", "kept with a note: \(failure.localizedDescription)")
        } catch is CancellationError {
            finish(token: token, url: url, segments: [], status: String(localized: "Cancelled."))
            AppLog.info("run", "cancelled")
        } catch {
            fail(token: token, url: url, error: error)
        }
    }

    nonisolated private static func statusText(for step: MeetingTranscriber.Step) -> String? {
        switch step {
        case .reading: String(localized: "Reading the audio…")
        case .detecting: String(localized: "Looking for speech…")
        case .preparingModel: String(localized: "Preparing the model — the first time takes a few minutes")
        case .waitingForEngine: String(localized: "Waiting for the engine…")
        case let .recognizing(_, done, total): String(localized: "Recognizing: \(done) of \(total)")
        case .compressing, .moving: nil
        }
    }

    private func show(_ text: String, token: Int) {
        if activeRunToken == token { status = text }
    }

    private func fail(token: Int, url: URL, error: any Error) {
        if Task.isCancelled {
            finish(token: token, url: url, segments: [], status: String(localized: "Cancelled."))
            AppLog.info("run", "cancelled")
            return
        }
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        finish(token: token, url: url, segments: [], status: "", error: msg)
        AppLog.error("run", "failed: \(msg)")
    }

    private func finish(
        token: Int,
        url: URL,
        segments: [TranscriptSegment],
        status: String,
        error: String? = nil
    ) {
        guard activeRunToken == token else { return }
        // Deactivate first: queued progress callbacks can no longer overwrite
        // the terminal status below.
        activeRunToken = nil
        isTranscribing = false
        currentTask = nil
        show(segments, from: url)
        errorText = error
        self.status = status
    }

    /// Every change of the result is a new revision, so a save of an older one
    /// never vouches for it.
    private func show(_ segments: [TranscriptSegment], from url: URL?) {
        self.segments = segments
        resultURL = segments.isEmpty ? nil : url
        resultRevision &+= 1
    }

    // MARK: - drop and pick

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isTranscribing, let provider = providers.first else { return false }
        #if DEBUG
        let probeID = FileProbe.id(of: provider)
        #endif
        selectionToken &+= 1
        let token = selectionToken
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            Task { @MainActor in
                #if DEBUG
                defer { FileProbe.dropCallbackFinished(probeID) }
                #endif
                // A newer selection or a started run made this drop stale:
                // neither its file nor its error may land now.
                guard token == self.selectionToken else {
                    AppLog.info("ui", "stale drop ignored")
                    return
                }
                guard let url, url.isFileURL else {
                    if error != nil { self.errorText = String(localized: "Couldn’t read the dropped item.") }
                    return
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue else {
                    self.errorText = String(localized: "This is not a file: \(url.lastPathComponent)")
                    return
                }
                // Accept any file the system can read as audio, whatever its
                // UTType says; one it cannot read fails on the run and says so.
                AppLog.info("ui", "file dropped: \(url.lastPathComponent)")
                self.select(url)
            }
        }
        return true
    }

    func pickFile() async {
        guard !isTranscribing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false
        // A drop still being resolved must not land on top of this explicit
        // choice.
        selectionToken &+= 1
        guard let url = await Self.present(panel) else { return }
        AppLog.info("ui", "file picked: \(url.lastPathComponent)")
        select(url)
    }

    /// The real save panel. Neither panel runs a nested modal loop: each is a
    /// sheet on the tab's window (the window itself when nothing is key), and
    /// its answer comes back here.
    static func askWhereToSave(_ name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = name
        return await present(panel)
    }

    private static func present(_ panel: NSSavePanel) async -> URL? {
        #if DEBUG
        if let folder = FileProbe.panelFolder { panel.directoryURL = folder }
        #endif
        // From the replace sheet the key window is that sheet, on its way out.
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow.map({ $0.sheetParent ?? $0 }) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }

    // MARK: - copy and save

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
    }

    /// True when this result's text was written; the name is the result's
    /// file, not whatever is selected now.
    @discardableResult
    func saveTranscript() async -> Bool {
        guard let request = saveRequest(),
              let url = await saveDestination(request.name) else { return false }
        return save(request, to: url)
    }

    private func saveRequest() -> SaveRequest? {
        guard !segments.isEmpty else { return nil }
        return SaveRequest(
            markdown: markdownText(),
            name: (resultURL?.deletingPathExtension().lastPathComponent ?? "transcript") + ".md",
            revision: resultRevision
        )
    }

    /// Only a written file counts, and only for the result it was taken from:
    /// a newer result that landed meanwhile stays unsaved.
    private func save(_ request: SaveRequest, to url: URL) -> Bool {
        do {
            try request.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorText = String(localized: "Couldn’t save the file: \(error.localizedDescription)")
            saveFailure = errorText
            return false
        }
        // A save that worked answers the save that failed, and nothing else:
        // an error that came since stays.
        if errorText != nil, errorText == saveFailure { errorText = nil }
        saveFailure = nil
        if request.revision == resultRevision {
            savedRevision = request.revision
            savedName = url.lastPathComponent
        }
        AppLog.info("ui", "saved: \(url.lastPathComponent)")
        return true
    }

    /// Plain text for the clipboard.
    private func transcriptText() -> String {
        segments.map { seg in
            var prefix = ""
            if let st = seg.start { prefix += "[\(TranscriptSegment.timecode(st))] " }
            if !seg.speaker.isEmpty { prefix += "\(seg.speaker): " }
            return prefix + seg.text
        }.joined(separator: "\n\n")
    }

    /// Real Markdown for the saved .md file.
    private func markdownText() -> String {
        segments.map { seg in
            var header = ""
            if !seg.speaker.isEmpty { header += "**\(seg.speaker)**" }
            if let st = seg.start {
                header += header.isEmpty ? "`[\(TranscriptSegment.timecode(st))]`"
                                         : " `[\(TranscriptSegment.timecode(st))]`"
            }
            return header.isEmpty ? seg.text : "\(header)\n\n\(seg.text)"
        }.joined(separator: "\n\n")
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelDownloader
    @EnvironmentObject var files: FilesModel

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            actionRow
            Divider()
            mainArea
            Divider()
            bottomBar
        }
        // The whole tab takes a drop, not just the zone: once a result is
        // shown the zone is gone, and a new file is dropped onto the text.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            files.handleDrop(providers)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: FileProbe.dropNotification)) { note in
            FileProbe.recordDropResult(note, accepted: files.handleDrop(FileProbe.providers(in: note)))
        }
        #endif
        .confirmationDialog(
            "Replace the unsaved text?",
            isPresented: Binding(
                get: { files.pendingReplacement != nil },
                set: { if !$0 { files.pendingReplacement = nil } }
            ),
            titleVisibility: .visible,
            presenting: files.pendingReplacement
        ) { replacement in
            Button("Save .md…") {
                Task { await files.saveThenReplace(replacement) }
            }
            .accessibilityIdentifier("fileReplaceSave")
            Button("Replace", role: .destructive) { files.replace(with: replacement) }
                .accessibilityIdentifier("fileReplaceConfirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("fileReplaceCancel")
        }
        // A question nobody answered is not asked again when the window reopens.
        .onDisappear { files.pendingReplacement = nil }
    }

    /// Inside the tab rather than in a window toolbar, which made the window
    /// taller on this tab alone. No keyboard shortcuts: the tab stays mounted,
    /// hidden, while another one shows, and a shortcut would fire from there.
    private var actionRow: some View {
        HStack(spacing: SettingsChrome.compactSpacing) {
            Image(systemName: files.fileURL == nil ? "tray.and.arrow.down" : "waveform.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let url = files.fileURL {
                // A Text of its own: the UI tests find the chosen file by name.
                Text(url.lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No file chosen")
                    .fontWeight(.semibold)
            }
            Spacer(minLength: 0)

            Button("Choose File…") { Task { await files.pickFile() } }
                .disabled(files.isTranscribing)
                .accessibilityIdentifier("fileChooseButton")
            if files.isTranscribing {
                Button {
                    files.cancel()
                } label: { Label("Cancel", systemImage: "stop.fill") }
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("fileCancelButton")
            } else {
                // The tab's main action: named, not a bare waveform
                // nobody takes for the button to press.
                Button {
                    files.start()
                } label: { Label("Transcribe", systemImage: "waveform") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.fileURL == nil)
                    .accessibilityIdentifier("fileTranscribeButton")
            }
            Button("Copy") { files.copyTranscript() }
                .disabled(files.segments.isEmpty)
                .accessibilityIdentifier("fileCopyButton")
            Button("Save .md") { Task { await files.saveTranscript() } }
                .disabled(files.segments.isEmpty)
                .accessibilityIdentifier("fileSaveButton")
        }
        .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
        .padding(.vertical, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if files.hasUnsavedText {
                Text("Kept only in this app until you quit — save it as .md")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("fileUnsavedNote")
            } else if let name = files.savedAs {
                Text("Saved as \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("fileSavedNote")
            }

            Spacer()

            if files.isTranscribing { ProgressView().controlSize(.small) }
            if !files.status.isEmpty {
                Text(files.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 27)
    }

    /// The drop zone until there is something to show, then the progress or
    /// the text in its place.
    private var mainArea: some View {
        Group {
            if files.isTranscribing {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(files.status.isEmpty ? String(localized: "Working…") : files.status)
                        .foregroundStyle(.secondary)
                }
            } else if files.segments.isEmpty, files.errorText == nil {
                dropZone
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop audio or video here")
                .font(.headline)
                .accessibilityIdentifier("fileDropZonePrompt")
            // Checked on macOS 26: AVAudioFile opens all five, video included.
            Text("mp3 · m4a · wav · mp4 · mov — same engine as dictation")
                .font(.caption).foregroundStyle(.secondary)
            if !models.missing(settings.dictationEngine).isEmpty {
                Text(FilesModel.modelMissingText)
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Task { await files.pickFile() } }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Above the text, not instead of it: a failed save or
                // drop must not hide a result that exists only here.
                if let errorText = files.errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(files.segments) { seg in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let st = seg.start {
                                Text(TranscriptSegment.timecode(st))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if !seg.speaker.isEmpty {
                                Text(seg.speaker)
                                    .font(.caption).bold()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(seg.text)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
            .padding(.vertical, 16)
        }
    }
}
