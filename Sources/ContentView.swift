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
            /// Only picks the file; its run is a Transcribe of its own.
            case file(URL)
            /// The run asked for, with the engine and language it was asked
            /// in: an answer that comes later never reads the menu again.
            case rerun(SettingsSnapshot.Choice?)
        }

        let action: Action
        /// The result the user agreed to drop; a newer one is not theirs to
        /// lose unasked.
        let revision: Int
    }

    /// Where to save a .md, given the name to suggest and the window the
    /// save was asked from; nil when the user cancelled. The real one is a
    /// panel on that window, a stand-in in tests.
    typealias SaveDestination = @MainActor (_ suggestedName: String, _ owner: NSWindow?) async -> URL?

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
    /// The engine and language of the next run; nil runs as the settings
    /// say, chunk by chunk. In memory only and never written to the
    /// settings: kept across runs, files and the window, until the user
    /// picks "As Dictation".
    @Published var choice: SettingsSnapshot.Choice?

    private let makeTranscription: @MainActor (SettingsSnapshot.Choice?) throws -> FileTranscription
    private let saveDestination: SaveDestination
    private let returnDictationEngine: @MainActor () -> Void
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

    /// `transcription` is asked, with the run's choice, as a run is asked
    /// for and again before it starts, before any text is dropped; it throws
    /// when the run cannot start. `returnDictationEngine` comes after a run
    /// with a choice, whatever its end.
    init(
        transcription: @escaping @MainActor (SettingsSnapshot.Choice?) throws -> FileTranscription,
        saveDestination: @escaping SaveDestination = FilesModel.askWhereToSave,
        returnDictationEngine: @escaping @MainActor () -> Void = {}
    ) {
        makeTranscription = transcription
        self.saveDestination = saveDestination
        self.returnDictationEngine = returnDictationEngine
    }

    /// A run refused before it starts: the engine it would use misses a
    /// file, its tokenizer and the VAD included.
    struct ModelMissing: LocalizedError {
        let engine: DictationEngine
        var errorDescription: String? {
            String(localized: "The \(engine.modelName) model is not downloaded. Download it above, or choose another engine.")
        }
    }

    /// The meeting pipeline on one file, so it gets the same model, chunking
    /// and timecodes as a call. A run in another engine than the dictation's
    /// leaves the dictation its engine, as a meeting job does, and gives it
    /// back afterwards. `transcriber` is the test's own, wired the same.
    static func live(
        settings: SettingsStore,
        models: ModelDownloader,
        dictation: DictationCoordinator,
        transcriber: MeetingTranscriber? = nil,
        saveDestination: @escaping SaveDestination = FilesModel.askWhereToSave
    ) -> FilesModel {
        var transcriber = transcriber ?? .live(settings: settings, models: models)
        transcriber.heldByDictation = { await dictation.heldEngine() }
        return FilesModel(transcription: { choice in
            #if DEBUG
            if let probe = FileProbe.transcription(choice: choice) { return probe }
            #endif
            // The same check as the transcriber's when it starts: a refusal
            // here leaves the shown text alone.
            let engine = settings.snapshot.applying(choice).dictationEngine
            guard models.missing(engine).isEmpty else { throw ModelMissing(engine: engine) }
            return Self.transcription(transcriber, choice: choice)
        }, saveDestination: saveDestination, returnDictationEngine: {
            dictation.prepareAfterOtherEngineJob()
        })
    }

    nonisolated static func transcription(
        _ transcriber: MeetingTranscriber,
        choice: SettingsSnapshot.Choice?
    ) -> FileTranscription {
        { url, progress in
            try await transcriber.transcribeFile(url, choice: choice, report: progress).map(TranscriptSegment.init)
        }
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
        // The run's own from here: a change of the menu while the question
        // or the save panel is up is the next run's.
        let choice = choice
        // Before the question: a run that cannot start asks nothing and
        // drops nothing.
        guard let transcribe = readyTranscription(choice) else { return }
        if hasUnsavedText {
            pendingReplacement = Replacement(action: .rerun(choice), revision: resultRevision)
        } else {
            run(transcribe, choice: choice)
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
        case .rerun(let choice):
            // Asked again: the model may have gone while the question or
            // the save panel was up.
            guard !isTranscribing, let transcribe = readyTranscription(choice) else { return }
            run(transcribe, choice: choice)
        }
    }

    /// "Save .md…" in the sheet: the replacement goes ahead only once the very
    /// result it was asked about is on disk. A cancelled panel or a failed
    /// write stops here; a result that landed while the panel was up fails the
    /// revision check in `replace`, and the save, taken before the panel,
    /// holds the agreed result, never the newer one.
    func saveThenReplace(_ replacement: Replacement, owner: NSWindow?) async {
        guard await saveTranscript(owner: owner) else { return }
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

    /// The run's transcription; without one the reason goes over the text,
    /// which stays as it is.
    private func readyTranscription(_ choice: SettingsSnapshot.Choice?) -> FileTranscription? {
        do {
            return try makeTranscription(choice)
        } catch {
            errorText = error.localizedDescription
            AppLog.info("run", "refused: \(error.localizedDescription)")
            return nil
        }
    }

    private func run(_ transcribe: @escaping FileTranscription, choice: SettingsSnapshot.Choice?) {
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
        currentTask = Task {
            await runTranscription(transcribe, url: url, choice: choice, token: token)
            // After the result is shown and apart from it: the dictation's
            // own warm-up, whose failure is the dictation's.
            if choice != nil { returnDictationEngine() }
        }
    }

    private func runTranscription(
        _ transcribe: FileTranscription,
        url: URL,
        choice: SettingsSnapshot.Choice?,
        token: Int
    ) async {
        // The language as a code: what was said never goes to the log.
        AppLog.info("run", "start file=\(url.lastPathComponent) " + (choice.map {
            "engine=\($0.engine.rawValue) language=\($0.language)"
        } ?? "as the settings say"))
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
        case .compressing, .moving, .removingAudio: nil
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

    func pickFile(owner: NSWindow?) async {
        guard !isTranscribing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false
        // A drop still being resolved must not land on top of this explicit
        // choice.
        selectionToken &+= 1
        guard let url = await Self.present(panel, on: owner, as: .fileToTranscribe) else { return }
        AppLog.info("ui", "file picked: \(url.lastPathComponent)")
        select(url)
    }

    /// The real save panel, on the window the save was asked from.
    static func askWhereToSave(_ name: String, _ owner: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = name
        return await present(panel, on: owner, as: .filesTranscript)
    }

    /// What a panel is for: the probe answers by it, and the log names it.
    enum PanelPurpose: String, Sendable {
        case fileToTranscribe = "a file to transcribe"
        case filesTranscript = "a file's transcript"
        case dictionaryImport = "a dictionary to import"
        case dictionaryExport = "the dictionary's export"
        case meetingTranscript = "a meeting's transcript"
    }

    /// The panel's last call, given its window: AppKit's sheet outside tests.
    typealias PanelSheet = @MainActor @Sendable (_ panel: NSSavePanel, _ owner: NSWindow) async -> URL?
    /// Where a panel's answer comes from.
    typealias PanelBackend = @MainActor @Sendable (_ panel: NSSavePanel, _ owner: NSWindow, _ purpose: PanelPurpose) async -> URL?

    /// Every open and save panel of the app's windows: the Files tab's, the
    /// dictionary's and a meeting's Save As. Each is a sheet on the window it
    /// was asked from, taken by the view at the click, never the window
    /// that happens to be key when the panel comes: an owner closed by then
    /// cancels the choice, and no panel goes on another window or on none.
    /// None runs a nested modal loop, and no test process opens one: `sheet`,
    /// AppKit's last call, comes only after this process's rule, which a
    /// test checks with a `sheet` that counts.
    static func present(
        _ panel: NSSavePanel, on owner: NSWindow?, as purpose: PanelPurpose,
        sheet: @escaping PanelSheet = FilesModel.sheet
    ) async -> URL? {
        let backend = panelBackend(
            arguments: ProcessInfo.processInfo.arguments, testProcess: TestIsolation.isTestProcess, sheet: sheet
        )
        return await present(panel, on: owner, as: purpose, backend: backend)
    }

    /// The same, with where the answer comes from given: a test's own.
    /// `probe`: the DEBUG probe's root, which may hold the panel.
    static func present(
        _ panel: NSSavePanel, on owner: NSWindow?, as purpose: PanelPurpose, backend: @escaping PanelBackend,
        probe: URL? = nil
    ) async -> URL? {
        #if DEBUG
        // A UI test holds the panel between the click and its coming.
        let held = await FileProbe.holdPresent(root: probe.flatMap { FileProbe.isTemporary($0) ? $0 : nil } ?? FileProbe.root)
        guard held.comes else { return nil }
        #endif
        guard let owner, owner.isVisible else {
            AppLog.info("ui", "no panel for \(purpose.rawValue): the window it was asked from is gone")
            #if DEBUG
            FileProbe.presented(held.shown, on: nil)
            #endif
            return nil
        }
        #if DEBUG
        FileProbe.presented(held.shown, on: owner)
        #endif
        return await backend(panel, owner, purpose)
    }

    /// The panel outside tests. A test process never opens one, whatever it
    /// was told (the stage gate's opt-out included): a DEBUG test with
    /// `-FileProbeRoot` gets the probe's answer, any other none.
    static func panelBackend(arguments: [String], testProcess: Bool, sheet: @escaping PanelSheet) -> PanelBackend {
        guard testProcess else { return { panel, owner, _ in await sheet(panel, owner) } }
        #if DEBUG
        if let root = FileProbe.root(in: arguments) {
            return { panel, _, purpose in await FileProbe.answer(panel, for: purpose, root: root) }
        }
        #endif
        return { _, _, _ in nil }
    }

    /// AppKit's panel, a sheet on its window.
    static func sheet(_ panel: NSSavePanel, on owner: NSWindow) async -> URL? {
        await panel.beginSheetModal(for: owner) == .OK ? panel.url : nil
    }

    // MARK: - copy and save

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
    }

    /// True when this result's text was written; the name is the result's
    /// file, not whatever is selected now.
    @discardableResult
    func saveTranscript(owner: NSWindow?) async -> Bool {
        guard let request = saveRequest(),
              let url = await saveDestination(request.name, owner) else { return false }
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

/// The window a view is in, read at the moment of an action: the owner of
/// the panel that action shows. A view inside a sheet answers with the
/// window the sheet is on.
@MainActor
final class WindowAnchor {
    fileprivate weak var view: NSView?

    var window: NSWindow? { view?.window.map { $0.sheetParent ?? $0 } }

    /// Put in the view's background: it is in the view's window.
    struct Reader: NSViewRepresentable {
        let anchor: WindowAnchor

        func makeNSView(context: Context) -> NSView {
            let spot = Spot()
            spot.anchor = anchor
            return spot
        }

        func updateNSView(_ view: NSView, context: Context) {}
    }

    /// Marks the anchor as it joins a window and lets go as it leaves, only
    /// if the anchor is still its: as the content changes, SwiftUI brings
    /// the new view in and updates the old one last before taking it away.
    private final class Spot: NSView {
        weak var anchor: WindowAnchor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                anchor?.view = self
            } else if anchor?.view === self {
                anchor?.view = nil
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelDownloader
    @EnvironmentObject var files: FilesModel

    @State private var isTargeted = false
    /// The tab's window, for the panels its actions show.
    @State private var anchor = WindowAnchor()

    var body: some View {
        VStack(spacing: 0) {
            actionRow
            optionsRow
            Divider()
            mainArea
            Divider()
            bottomBar
        }
        // The whole tab takes a drop, not just the zone: once a result is
        // shown the zone is gone, and a new file is dropped onto the text.
        .contentShape(Rectangle())
        .background(WindowAnchor.Reader(anchor: anchor))
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
                // The tab's window, not the question's, which is on its way out.
                let owner = anchor.window
                Task { await files.saveThenReplace(replacement, owner: owner) }
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

    /// The window is taken at the click, before anything waits.
    private func pickFile() {
        let owner = anchor.window
        Task { await files.pickFile(owner: owner) }
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

            Button("Choose File…") { pickFile() }
                .disabled(files.isTranscribing)
                .fixedSize()
                .accessibilityIdentifier("fileChooseButton")
            if files.isTranscribing {
                Button {
                    files.cancel()
                } label: { Label("Cancel", systemImage: "stop.fill") }
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .accessibilityIdentifier("fileCancelButton")
            } else {
                // The tab's main action: named, not a bare waveform
                // nobody takes for the button to press. Fixed so a long file
                // name shrinks instead of this button's own label.
                Button {
                    files.start()
                } label: { Label("Transcribe", systemImage: "waveform") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(files.fileURL == nil)
                    .fixedSize()
                    .accessibilityIdentifier("fileTranscribeButton")
            }
            Button("Copy") { files.copyTranscript() }
                .disabled(files.segments.isEmpty)
                .fixedSize()
                .accessibilityIdentifier("fileCopyButton")
            Button("Save .md") {
                let owner = anchor.window
                Task { await files.saveTranscript(owner: owner) }
            }
                .disabled(files.segments.isEmpty)
                .fixedSize()
                .accessibilityIdentifier("fileSaveButton")
        }
        .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The engine and language of the next run, and whether that model is
    /// there: above the area the text takes over, so they stay at hand to run
    /// a file again. A choice runs nothing and drops nothing.
    private var optionsRow: some View {
        let label = FilesChoiceMenu.label(of: files.choice, settings: settings.snapshot)
        let engine = settings.snapshot.applying(files.choice).dictationEngine
        let missing = models.missing(engine)
        // The model's state takes a line of its own under the menu: beside
        // the menu and the download button there was no room left for it at
        // the window's usual width, least of all in Russian.
        return VStack(alignment: .leading, spacing: 6) {
            Menu {
                FilesChoiceMenu(files: files, settings: settings, models: models)
            } label: {
                Text(label)
            }
            .fixedSize()
            // The run keeps the choice it started with whatever the menu
            // says; off while it runs so the menu never looks like the run's.
            .disabled(files.isTranscribing)
            .accessibilityLabel(Text("Transcription options"))
            .accessibilityValue(Text(label))
            .accessibilityIdentifier("fileChoiceMenu")
            // One download at a time: while any runs, it shows under its own
            // name, never as this engine's.
            if let download = models.download {
                Text("\(download.engine.modelName) · downloading \(download.progressText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !missing.isEmpty {
                HStack(spacing: SettingsChrome.compactSpacing) {
                    Text("\(engine.title) · not downloaded")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fileModelState")
                    Button("Download Model \(engine.modelName) (\(ModelDownloader.sizeText(missing.reduce(0) { $0 + $1.bytes })))…") {
                        models.start(engine)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("fileDownloadButton")
                }
                if let failure = models.failure, failure.engine == engine {
                    Text("Download failed: \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsChrome.contentHorizontalPadding)
        .padding(.bottom, 10)
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
            // The engine is the options row's to say.
            Text(verbatim: "mp3 · m4a · wav · mp4 · mov")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { pickFile() }
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

/// The Files tab's engines and languages: "As Dictation", then each engine
/// with Auto and its languages. A view of its own, so a test sees the items as
/// AppKit gets them (`NSHostingMenu`). Every item sets engine and language
/// together, so there is no draft to keep.
struct FilesChoiceMenu: View {
    @ObservedObject var files: FilesModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var models: ModelDownloader

    var body: some View {
        let dictation = Self.names(of: nil, settings: settings.snapshot)
        Picker("Transcription options", selection: $files.choice) {
            Text("As Dictation (\(dictation.engine) · \(dictation.language))")
                .tag(SettingsSnapshot.Choice?.none)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        ForEach(DictationEngine.allCases, id: \.self) { engine in
            Menu(models.missing(engine).isEmpty ? engine.title : String(localized: "\(engine.title) · not downloaded")) {
                Picker("Language", selection: $files.choice) {
                    Text("Auto").tag(Optional(SettingsSnapshot.Choice(engine: engine, language: "auto")))
                    Divider()
                    ForEach(engine.languageChoices, id: \.code) { language in
                        Text(language.name).tag(Optional(SettingsSnapshot.Choice(engine: engine, language: language.code)))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    /// "As Dictation · Parakeet · Auto" or the choice alone: the two differ
    /// even when they would ask the engine the same, as only the first
    /// follows the settings.
    static func label(of choice: SettingsSnapshot.Choice?, settings: SettingsSnapshot) -> String {
        let names = names(of: choice, settings: settings)
        return choice == nil
            ? String(localized: "As Dictation · \(names.engine) · \(names.language)")
            : "\(names.engine) · \(names.language)"
    }

    /// The engine and language a run would take, the language by the
    /// settings' rule: a code the engine does not know is Auto.
    private static func names(
        of choice: SettingsSnapshot.Choice?,
        settings: SettingsSnapshot
    ) -> (engine: String, language: String) {
        let run = settings.applying(choice)
        let code = run.dictationEngine.language(for: run.dictationLanguage)
        let language = code.flatMap { code in run.dictationEngine.languageChoices.first { $0.code == code }?.name }
        return (run.dictationEngine.title, language ?? String(localized: "Auto"))
    }
}
