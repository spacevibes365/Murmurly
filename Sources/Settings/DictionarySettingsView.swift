import SwiftUI
import UniformTypeIdentifiers

/// The personal dictionary: where it applies, its entries, the sheet that
/// adds or edits one, and its export and import as a file. Every change is
/// checked by `DictionaryEntry.problem(among:)` and stored by
/// `SettingsStore.saveDictionary(_:)`, which publishes only what it stored.
struct DictionarySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    /// The entry in the sheet; a new one has an id the dictionary lacks.
    @State private var editing: DictionaryEntry?
    @State private var pendingDeletion: DictionaryEntry?
    @State private var confirmingClear = false
    @State private var errorMessage: String?
    /// An import from its panel to the answer. Until it ends nothing on the
    /// tab changes the dictionary and no second one starts.
    @State private var importStep: ImportStep?
    /// Bumped by every import and by a change of tab while a file is read: a
    /// file read for an import that was dropped is never offered.
    @State private var importAttempt = 0
    /// From the export's panel to the end of its write. Until then neither
    /// Export nor Import starts: two writes to one file could land in either
    /// order, and a late one would overwrite the outcome of a newer operation.
    @State private var exporting = false
    /// What came of the last export or import.
    @State private var transfer: Transfer?
    /// The tab's window, for its panels.
    @State private var anchor = WindowAnchor()
    /// The main window's section: any change of it drops a file being read.
    let section: MainSection

    init(section: MainSection) {
        self.section = section
    }

    private enum ImportStep: Equatable {
        /// The panel is up. It stays through a change of tab, and its answer
        /// counts.
        case choosing
        /// The file is being read; nothing of it is on screen, so a change of
        /// tab drops it.
        case reading
        /// A file that passed, waiting for the answer.
        case asking([DictionaryEntry])
    }

    private struct Transfer: Equatable {
        let message: String
        let failed: Bool
    }

    /// Nothing edits the dictionary while it can't be read or an import is
    /// under way: the import merges from the dictionary as it is at the answer.
    private var locked: Bool { settings.dictionaryUnreadable || importStep != nil }

    private var pendingImport: [DictionaryEntry]? {
        if case .asking(let entries)? = importStep { entries } else { nil }
    }

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            if settings.dictionaryUnreadable { unreadable }
            SettingsGroup("Where it applies") {
                SettingsRow("Dictation") { use("Dictation", $settings.dictionaryInDictation, id: "dictionaryInDictation") }
                Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
                SettingsRow("Meetings") { use("Meetings", $settings.dictionaryInMeetings, id: "dictionaryInMeetings") }
                Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
                SettingsRow("Files") { use("Files", $settings.dictionaryInFiles, id: "dictionaryInFiles") }
                Text("Applies to new dictations, meetings and files; what is already saved doesn’t change.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                    .padding(.bottom, SettingsChrome.rowVerticalPadding)
            }
            entries
        }
        .background(WindowAnchor.Reader(anchor: anchor))
        .sheet(item: $editing) { entry in
            DictionaryEntrySheet(entry: entry)
        }
        // Sections are only hidden, never closed: a file read meanwhile would
        // ask over another section later, so any change of section drops the
        // read, this one hidden or not. The entry sheet, a panel or a
        // question stays over the new section until the user answers it: it
        // blocks the window, and the answer counts as it would here. This
        // runs inside the window's layout, and a panel or an alert closed
        // from it ran its close animation's nested run loop there, which
        // crashed AppKit (macOS 26.5). Settings' tabs are another window's.
        .onChange(of: section) {
            guard importStep == .reading else { return }
            importAttempt += 1
            importStep = nil
        }
        .confirmationDialog(
            "Import the dictionary?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0, pendingImport != nil { importStep = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingImport
        ) { entries in
            Button("Add to My Dictionary") { finishImport(entries, replacing: false) }
            Button("Replace My Dictionary", role: .destructive) { finishImport(entries, replacing: true) }
            Button("Cancel", role: .cancel) { importStep = nil }
        } message: { entries in
            Text("Entries in the file: \(entries.count). Adding keeps yours and adds the file’s new ones. Replacing deletes yours, \(settings.dictionary.count) in all, and takes the file’s as they are.")
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                save(settings.dictionary.filter { $0.id != entry.id })
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("New dictations, meetings and files will no longer use it.")
        }
        .confirmationDialog("Clear the dictionary?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Dictionary", role: .destructive) { settings.clearDictionary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All of its entries will be deleted for good.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The row shows the title; the hidden label is what VoiceOver says.
    private func use(_ title: LocalizedStringKey, _ isOn: Binding<Bool>, id: String) -> some View {
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .accessibilityIdentifier(id)
    }

    /// Nothing is edited or applied until the user clears it on purpose.
    private var unreadable: some View {
        SettingsGroup("Saved dictionary") {
            VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                Self.unreadableExplanation
                Button("Clear Dictionary…") { confirmingClear = true }
                    .accessibilityIdentifier("dictionaryClear")
                    .padding(.top, SettingsChrome.rowContentSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
        }
    }

    /// Said on the tab and in the sheet, whichever way the sheet was opened.
    fileprivate static var unreadableExplanation: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
            Label("The saved dictionary can’t be read", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("It may have been saved by a newer version of Murmurly. Until it is cleared, the dictionary doesn’t apply and can’t be edited. Clearing deletes its entries for good.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictionaryUnreadableNote")
    }

    private var entries: some View {
        SettingsGroup("Entries") {
            if settings.dictionary.isEmpty {
                VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                    Text("No entries yet")
                    Text(
                        "For example, “cloud code” → “Claude Code”: what the engine writes, and how you want it written.",
                        comment: "Empty dictionary. Give an example of a term the engine mishears in this language, e.g. Russian «клод код» → «Claude Code»"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                .padding(.vertical, SettingsChrome.rowVerticalPadding)
            }
            ForEach(settings.dictionary) { entry in
                row(entry)
                Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
            }
            HStack {
                Button("Export…") { export() }
                    .disabled(locked || exporting || settings.dictionary.isEmpty)
                    .accessibilityIdentifier("dictionaryExport")
                Button("Import…") { startImport() }
                    .disabled(locked || exporting)
                    .accessibilityIdentifier("dictionaryImport")
                Spacer()
                Button("Add…") { editing = DictionaryEntry(heard: [], written: "") }
                    .disabled(locked)
                    .accessibilityIdentifier("dictionaryAdd")
            }
            .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
            if let transfer {
                Text(transfer.message)
                    .font(.caption).foregroundStyle(transfer.failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                    .padding(.bottom, SettingsChrome.rowVerticalPadding)
                    .accessibilityIdentifier(transfer.failed ? "dictionaryTransferError" : "dictionaryTransferNote")
            }
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: SettingsChrome.compactSpacing) {
            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { setEnabled(entry, $0) }))
                .labelsHidden()
                .disabled(locked)
                .accessibilityLabel(Text(verbatim: entry.written))
            // The user's own words: shown as typed, never looked up in the catalog.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.written)
                Text(verbatim: entry.heard.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(entry.isEnabled ? 1 : SettingsChrome.disabledOpacity)
            Spacer()
            Button("Edit…") { editing = entry }
                .disabled(locked)
            Button {
                pendingDeletion = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(locked)
            .accessibilityLabel(Text("Delete"))
        }
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictionaryEntry")
    }

    /// Turning an entry on is checked like saving it: its spelling may have
    /// gone into another entry meanwhile.
    private func setEnabled(_ entry: DictionaryEntry, _ isEnabled: Bool) {
        var changed = entry
        changed.isEnabled = isEnabled
        if let problem = changed.problem(among: settings.dictionary) {
            errorMessage = problem.message
            return
        }
        save(settings.dictionary.map { $0.id == entry.id ? changed : $0 })
    }

    private func save(_ entries: [DictionaryEntry]) {
        do {
            try settings.saveDictionary(entries)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export and import

    private func export() {
        transfer = nil
        exporting = true
        let owner = anchor.window
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        // A file name, like the meeting folders' names: never translated.
        panel.nameFieldStringValue = "Murmurly Dictionary.json"
        Task {
            // Every way out: a cancelled or closed panel, a write done or failed.
            defer { exporting = false }
            guard let url = await FilesModel.present(panel, on: owner, as: .dictionaryExport) else { return }
            #if DEBUG
            let write = FileProbe.dictionaryWrite() ?? SettingsStore.writeWhole
            #else
            let write = SettingsStore.writeWhole
            #endif
            do {
                let count = try await settings.exportDictionary(to: url, write: write)
                transfer = Transfer(
                    message: String(localized: "Exported to “\(url.lastPathComponent)”. Entries: \(count)."),
                    failed: false
                )
            } catch {
                AppLog.error("settings", "dictionary export failed: \(error.localizedDescription)")
                transfer = Transfer(
                    message: String(localized: "Couldn’t export the dictionary: \(error.localizedDescription)"),
                    failed: true
                )
            }
        }
    }

    /// Panel, then the file read and checked off the main actor, then the
    /// question, only about a file that passed. Nothing is saved before the
    /// answer, and the merge starts from the dictionary as it is then.
    private func startImport() {
        transfer = nil
        importAttempt += 1
        let attempt = importAttempt
        importStep = .choosing
        let owner = anchor.window
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        Task {
            let url = await FilesModel.present(panel, on: owner, as: .dictionaryImport)
            #if DEBUG
            defer { if let url { FileProbe.dictionaryImportHandled(url) } }
            let read = FileProbe.dictionaryRead() ?? SettingsStore.readWhole
            #else
            let read = SettingsStore.readWhole
            #endif
            guard let url else {
                importStep = nil
                return
            }
            importStep = .reading
            let result = await SettingsStore.importedDictionary(at: url, read: read)
            // A change of tab while the file was read dropped this import:
            // its answer neither asks nor, into an empty dictionary, saves.
            guard attempt == importAttempt else { return }
            switch result {
            case .failure(let failure):
                importStep = nil
                transfer = Transfer(message: Self.notImported(failure.message), failed: true)
            case .success(let entries) where settings.dictionary.isEmpty:
                // With nothing of yours, adding and replacing come to the same.
                finishImport(entries, replacing: false)
            case .success(let entries):
                importStep = .asking(entries)
            }
        }
    }

    private func finishImport(_ entries: [DictionaryEntry], replacing: Bool) {
        importStep = nil
        do {
            transfer = Transfer(message: try settings.importDictionary(entries, replacing: replacing).summary, failed: false)
        } catch {
            transfer = Transfer(message: Self.notImported(error.localizedDescription), failed: true)
        }
    }

    private static func notImported(_ reason: String) -> String {
        String(localized: "Nothing was imported.") + " " + reason
    }
}

/// Adds or edits one entry. Closing it drops the draft; a refused or failed
/// save keeps it open with the reason. While the dictionary can't be read it
/// takes no entry at all and says why, whichever way it was opened.
struct DictionaryEntrySheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let original: DictionaryEntry
    /// The way to the Dictionary section while the dictionary can't be read;
    /// the section's own sheet never needs it, its Add and Edit wait then.
    private var openDictionary: () -> Void = {}

    /// The text a new entry is made from outside the tab: only its words.
    /// The history line or the transcript it came from is never touched.
    struct Source {
        let text: String
        let heading: LocalizedStringKey
        /// The text is as the engine wrote it, before the dictionary.
        let asRecognized: Bool
    }

    private let source: Source?
    @State private var heard: String
    @State private var written: String
    @State private var example: String
    /// A copy of the source's text to select in. Typing in it is harmless:
    /// the copy goes away with the sheet, and nothing is written back.
    @State private var sourceText: String
    @State private var selection: TextSelection?
    @State private var selectionProblem: String?
    @State private var preview: String?
    @State private var errorMessage: String?

    /// From the Dictionary tab; `example` fills "Try it".
    init(entry: DictionaryEntry, example: String = "") {
        self.init(entry: entry, example: example, source: nil)
    }

    /// A new entry from a dictation in the history. Its text is shown as
    /// recognized, before the dictionary: that is what the engine wrote, and
    /// it fills "Try it", so the preview shows this very dictation.
    init(dictation: DictationHistoryEntry, openDictionary: @escaping () -> Void = {}) {
        let text = dictation.rawText ?? dictation.text
        self.init(
            entry: DictionaryEntry(heard: [], written: ""), example: text,
            source: Source(text: text, heading: "From the dictation", asRecognized: dictation.rawText != nil)
        )
        self.openDictionary = openDictionary
    }

    /// A new entry from a meeting's transcript: `text` is the line the
    /// selection began in, without its time and label, to select in again
    /// and to try the entry on. `selected`, everything selected there, is
    /// taken as one spelling by the rule a selection in the copy follows;
    /// refused (nil for several stretches), the field stays empty and the
    /// reason shows.
    init(transcript text: String, selected: String?, openDictionary: @escaping () -> Void = {}) {
        self.init(
            entry: DictionaryEntry(heard: [], written: ""), example: text,
            source: Source(text: text, heading: "From the transcript", asRecognized: false)
        )
        self.openDictionary = openDictionary
        switch selected.map({ DictionaryEntry.variant(fromSelection: Substring($0)) }) {
        case .success(let variant)?: _heard = State(initialValue: variant)
        case .failure(let problem)?: _selectionProblem = State(initialValue: problem.message)
        case nil: _selectionProblem = State(initialValue: String(localized: "Select one stretch of words: several were selected."))
        }
    }

    private init(entry: DictionaryEntry, example: String, source: Source?) {
        original = entry
        self.source = source
        _heard = State(initialValue: entry.heard.joined(separator: ", "))
        _written = State(initialValue: entry.written)
        _example = State(initialValue: example)
        _sourceText = State(initialValue: source?.text ?? "")
    }

    private var isNew: Bool { !settings.dictionary.contains { $0.id == original.id } }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: original.id,
            heard: DictionaryEntry.variants(fromList: heard),
            written: written.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: isNew || original.isEnabled
        )
    }

    var body: some View {
        Group {
            if settings.dictionaryUnreadable { unreadable } else { form }
        }
        .padding(SettingsChrome.contentHorizontalPadding)
        .frame(width: SettingsChrome.dictionarySheetWidth)
    }

    /// Editing waits for the dictionary to be cleared on its tab, so the
    /// way there is offered, never the clearing itself.
    private var unreadable: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.groupSpacing) {
            DictionarySettingsView.unreadableExplanation
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dictionaryCancel")
                Button("Open Dictionary") {
                    openDictionary()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("dictionaryOpenTab")
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.groupSpacing) {
            (isNew ? Text("Add Entry") : Text("Edit Entry")).font(.headline)
            if let source { sourceField(source) }
            field("Heard as") {
                TextField(
                    "",
                    text: $heard,
                    prompt: Text(
                        "cloud code, clod code",
                        comment: "Placeholder: how an engine may write “Claude Code” in this language, comma-separated"
                    )
                )
                .accessibilityLabel(Text("Heard as"))
                .accessibilityIdentifier("dictionaryHeardField")
                Text("Word forms are recognized with the macOS dictionary. Words it doesn’t know, often English terms, add in the forms you need, separated by commas. A form may also match a similar word.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field("Write as") {
                TextField("", text: $written, prompt: Text(verbatim: "Claude Code"))
                    .accessibilityLabel(Text("Write as"))
                    .accessibilityIdentifier("dictionaryWrittenField")
            }
            field("Try it") {
                TextField("", text: $example, prompt: Text("A sentence the way the engine writes it"))
                    .accessibilityLabel(Text("Try it"))
                    .accessibilityIdentifier("dictionaryExampleField")
                if let preview {
                    Text(verbatim: preview)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dictionaryPreview")
                }
            }
            if source != nil {
                // The history line or the transcript stays as it was saved.
                Text("Applies to new dictations, meetings and files; what is already saved doesn’t change.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dictionaryEntryError")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dictionaryCancel")
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictionarySave")
            }
        }
        .onChange(of: selection) { selectionProblem = nil }
        .onChange(of: heard) { errorMessage = nil }
        .onChange(of: written) { errorMessage = nil }
        // A newer input cancels the older preview, so a late one never
        // overwrites it. The language counts too: it can change from the
        // menu bar while the sheet is open.
        .task(id: previewInput) { [input = previewInput] in await updatePreview(input) }
    }

    private func sourceField(_ source: Source) -> some View {
        field(source.heading) {
            TextEditor(text: $sourceText, selection: $selection)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(SettingsChrome.dictionarySourcePadding)
                .frame(height: SettingsChrome.dictionarySourceHeight)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.chipCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsChrome.chipCornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: SettingsChrome.cardBorderWidth)
                }
                .accessibilityLabel(Text(source.heading))
                .accessibilityIdentifier("dictionarySourceText")
            if source.asRecognized {
                // The history row shows the text after the dictionary.
                Text("As recognized, before the dictionary changed it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: SettingsChrome.compactSpacing) {
                Button("Use Selection") { useSelection() }
                    .disabled(selectedText == nil)
                    .accessibilityIdentifier("dictionaryUseSelection")
                if let selectionProblem {
                    Text(selectionProblem)
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dictionarySelectionError")
                } else {
                    Text("Select the words the engine got wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The one stretch selected in the copy; nil for a caret, several
    /// stretches or only spaces.
    private var selectedText: Substring? {
        guard case .selection(let range)? = selection?.indices,
              range.lowerBound >= sourceText.startIndex, range.upperBound <= sourceText.endIndex else { return nil }
        let text = sourceText[range]
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }

    /// The selection replaces the field as one spelling, or the field stays
    /// as it was and the reason shows under the text. Never the clipboard.
    private func useSelection() {
        guard let selected = selectedText else { return }
        switch DictionaryEntry.variant(fromSelection: selected) {
        case .success(let variant):
            heard = variant
        case .failure(let problem):
            selectionProblem = problem.message
        }
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
            Text(title).fontWeight(.medium)
            content()
        }
    }

    /// Everything one preview reads, taken at once.
    private struct PreviewInput: Equatable {
        var entries: [DictionaryEntry]
        var text: String
        var matchesWordForms: Bool
    }

    /// The whole dictionary with this draft in its place, the language as
    /// the next job would take it: what a dictation would come out as.
    private var previewInput: PreviewInput {
        // What the entry does, even while it is switched off.
        var tried = draft
        tried.isEnabled = true
        var entries = settings.dictionary
        if let index = entries.firstIndex(where: { $0.id == original.id }) {
            entries[index] = tried
        } else {
            entries.append(tried)
        }
        return PreviewInput(
            entries: entries,
            text: example,
            matchesWordForms: settings.dictionarySnapshot.matchesWordForms
        )
    }

    private func updatePreview(_ input: PreviewInput) async {
        guard !input.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            preview = nil
            return
        }
        // The tagger stays off the main actor.
        let result = await Task.detached {
            DictionaryReplacer(entries: input.entries, matchesWordForms: input.matchesWordForms)
                .replacing(in: input.text).text
        }.value
        guard !Task.isCancelled else { return }
        preview = result
    }

    private func save() {
        let entry = draft
        if let problem = entry.problem(among: settings.dictionary) {
            errorMessage = problem.message
            return
        }
        var entries = settings.dictionary
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        do {
            try settings.saveDictionary(entries)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
