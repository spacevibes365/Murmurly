import AppKit
import KeyboardShortcuts
import SwiftUI

struct DictationSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var indicator: RecordingIndicator
    @EnvironmentObject private var permissions: PermissionManager
    @State private var languageQuery = ""

    var body: some View {
        VStack(spacing: SettingsChrome.groupSpacing) {
            hotkeyGroup
            pastingGroup
            recognitionGroup
            feedbackGroup
            SettingsGroup("Archive") {
                SettingsRow("Save dictation audio", subtitle: "Text is saved to the history; if that fails, it stays in the “M” menu until you quit. After a failure, a cut-off or a quit, the audio is saved too.") {
                    Toggle("", isOn: $settings.saveDictationAudio)
                        .labelsHidden()
                        .accessibilityIdentifier("saveDictationAudioToggle")
                }
            }
        }
    }

    private var hotkeyGroup: some View {
        SettingsGroup("Hotkey") {
            // The mode's explanation sits under the title rather than in a row
            // of its own: the tab is already taller than the window.
            SettingsRow(
                "Trigger",
                subtitle: "\(settings.hotkeyActivation.explanation) A dictation stops by itself after 5 minutes."
            ) {
                Picker("", selection: $settings.hotkeyActivation) {
                    Text("Press").tag(HotkeyActivation.press)
                    Text("Hold").tag(HotkeyActivation.hold)
                    Text("Double press").tag(HotkeyActivation.doubleModifier)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("hotkeyActivationPicker")
            }
            // The double press is watched through Accessibility; without it
            // the choice is kept but only the backup shortcut answers.
            if settings.hotkeyActivation == .doubleModifier, !permissions.axTrusted {
                Text("Needs Accessibility — until then only the backup shortcut works")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                    .padding(.bottom, SettingsChrome.rowVerticalPadding)
            }
            if settings.hotkeyActivation == .doubleModifier {
                divider
                SettingsRow("Key") {
                    Picker("", selection: $settings.doubleTapModifier) {
                        ForEach(TapModifier.allCases, id: \.self) { modifier in
                            Text(modifier.title).tag(modifier)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: SettingsChrome.hotkeyModifierPopupMinWidth)
                    .accessibilityIdentifier("doubleTapModifierPicker")
                }
                divider
                SettingsRow("Double-press interval") {
                    HStack(spacing: SettingsChrome.compactSpacing) {
                        Button(String("−")) { adjustDoubleTapThreshold(by: -25) }
                            .disabled(settings.doubleTapThresholdMS <= 150)
                        Text("\(settings.doubleTapThresholdMS) ms")
                            .font(.caption.monospaced())
                            .monospacedDigit()
                            .frame(minWidth: 62)
                            .accessibilityIdentifier("doubleTapThresholdValue")
                        Button(String("+")) { adjustDoubleTapThreshold(by: 25) }
                            .disabled(settings.doubleTapThresholdMS >= 500)
                    }
                    .controlSize(.small)
                }
            }
            divider
            SettingsRow(
                settings.hotkeyActivation == .doubleModifier
                    ? "Backup shortcut"
                    : "Keyboard shortcut",
                subtitle: fallbackShortcutSubtitle
            ) {
                KeyboardShortcuts.Recorder(for: .dictate) { _ in
                    settings.objectWillChange.send()
                }
                .frame(minWidth: SettingsChrome.controlMinWidth)
            }
        }
    }

    private var pastingGroup: some View {
        SettingsGroup("Pasting") {
            SettingsRow(
                "Paste automatically",
                subtitle: "When off, dictations go to Dictations only; paste the last one with the shortcut below."
            ) {
                Toggle("", isOn: $settings.autoPaste)
                    .labelsHidden()
                    .accessibilityIdentifier("autoPasteToggle")
            }
            divider
            SettingsRow("Paste last dictation") {
                KeyboardShortcuts.Recorder(for: .pasteLastDictation) { _ in
                    settings.objectWillChange.send()
                }
                .frame(minWidth: SettingsChrome.controlMinWidth)
                .accessibilityIdentifier("pasteLastShortcutRecorder")
            }
            divider
            SettingsRow("Copy last dictation") {
                KeyboardShortcuts.Recorder(for: .copyLastDictation) { _ in
                    settings.objectWillChange.send()
                }
                .frame(minWidth: SettingsChrome.controlMinWidth)
                .accessibilityIdentifier("copyLastShortcutRecorder")
            }
        }
    }

    private var recognitionGroup: some View {
        SettingsGroup("Recognition") {
            SettingsRow("Engine", subtitle: "Switches on the fly, no restart needed") {
                Picker("", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases, id: \.self) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("dictationEnginePicker")
            }
            divider
            ModelRow()
            divider
            SettingsRow("Language", subtitle: "Parakeet — 25 European languages, Whisper — about a hundred") {
                languagePicker
            }
            if let note = Self.fallbackNote(setting: settings.dictationLanguage, engine: settings.dictationEngine) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                    .padding(.bottom, SettingsChrome.rowVerticalPadding)
            }
        }
    }

    private var languagePicker: some View {
        let choices = Self.filteredLanguages(
            settings.dictationEngine.languageChoices,
            query: languageQuery,
            keeping: settings.pickedLanguage
        )
        let matches = Self.filteredLanguages(
            settings.dictationEngine.languageChoices,
            query: languageQuery,
            keeping: ""
        )
        return VStack(alignment: .trailing, spacing: SettingsChrome.rowContentSpacing) {
            TextField("Search languages", text: $languageQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: SettingsChrome.popupMinWidth)
                .accessibilityIdentifier("languageSearchField")
            if !languageQuery.trimmingCharacters(in: .whitespaces).isEmpty, !matches.isEmpty, matches.count <= 6 {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(matches, id: \.code) { choice in
                        Button(choice.name) {
                            settings.pickedLanguage = choice.code
                            languageQuery = ""
                        }
                        .accessibilityIdentifier("languageMatch.\(choice.code)")
                    }
                }
            }
            Picker("", selection: $settings.pickedLanguage) {
                Text("Auto").tag("auto")
                Divider()
                ForEach(choices, id: \.code) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            .labelsHidden()
            .frame(minWidth: SettingsChrome.popupMinWidth)
            .accessibilityIdentifier("dictationLanguagePicker")
            if choices.isEmpty {
                Text("No languages match").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Matches the name shown in the current locale, ignoring case and
    /// diacritics, or the code. The current choice always stays, so the
    /// picker never shows an empty selection.
    static func filteredLanguages(
        _ choices: [(code: String, name: String)],
        query: String,
        keeping selected: String
    ) -> [(code: String, name: String)] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return choices }
        return choices.filter { choice in
            choice.code == selected
                || choice.code.range(of: query, options: [.caseInsensitive, .anchored]) != nil
                || choice.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Why a chosen language is not used: the engine does not know it, so
    /// recognition runs on Auto. The setting itself is kept. Auto chosen on
    /// purpose needs no explanation.
    static func fallbackNote(setting: String, engine: DictationEngine) -> String? {
        guard setting != "auto", engine.language(for: setting) == nil else { return nil }
        let name = DictationEngine.languageName(setting)
        guard let other = DictationEngine.allCases.first(where: { $0 != engine && $0.language(for: setting) != nil }) else {
            return String(localized: "\(name) isn’t supported by either engine. Auto is used.")
        }
        return String(localized: "\(name) isn’t supported by \(engine.title). Auto is used; your choice is kept for \(other.title).")
    }

    private var feedbackGroup: some View {
        SettingsGroup("Feedback") {
            SettingsRow("Sounds") {
                Toggle("", isOn: soundsEnabledBinding).labelsHidden()
            }
            if settings.soundsEnabled {
                divider
                feedbackCheck("Recording started", binding: $settings.soundOnRecordingStart)
                feedbackCheck("Text pasted", binding: $settings.soundOnInsert)
            }
            divider
            SettingsRow(
                "Show the indicator above windows",
                subtitle: "Drag it with the mouse — its position is remembered. Even when turned off, it shows errors."
            ) {
                Toggle("", isOn: $settings.overlayEnabled).labelsHidden()
            }
            if settings.overlayEnabled {
                divider
                HStack {
                    Text(indicator.compactPositionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { settings.overlayPlacement = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(settings.overlayPlacement == nil)
                }
                .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
                .padding(.vertical, SettingsChrome.rowVerticalPadding)
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, SettingsChrome.dividerLeadingPadding)
    }

    private func feedbackCheck(_ title: LocalizedStringKey, binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.checkbox)
            .padding(.leading, SettingsChrome.nestedControlIndent)
            .padding(.trailing, SettingsChrome.rowHorizontalPadding)
            .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }

    private var soundsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.soundsEnabled },
            set: { settings.soundsEnabled = $0 }
        )
    }

    private var fallbackShortcutSubtitle: LocalizedStringKey? {
        guard settings.hotkeyActivation == .doubleModifier else { return nil }
        return settings.dictationShortcutDescription == nil
            ? "No backup shortcut set"
            : "Stays as a backup"
    }

    private func adjustDoubleTapThreshold(by delta: Int) {
        settings.doubleTapThresholdMS += delta
    }
}

/// The selected engine's model: what is missing and the button to get it,
/// the download while it runs, then how far the model is from use. One view
/// for Recognition and Getting Started, so the two never disagree.
struct ModelRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var dictation: DictationCoordinator
    @EnvironmentObject private var models: ModelDownloader
    /// Bumped to read the disk again: nothing tells the app that the model
    /// folder went to the Trash, so the row checks when the app comes back.
    @State private var diskCheck = 0

    var body: some View {
        let missing = models.missing(settings.dictationEngine)
        // A model sent to the Trash after a failure needs Download, not Try Again.
        let failed = dictation.modelFailure != nil && models.isReady(settings.dictationEngine)
            && models.download == nil
        return VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
            HStack(spacing: SettingsChrome.compactSpacing) {
                SettingsStatusDot(color: modelColor())
                Text(modelLabel(missing: missing)).font(.callout)
                Spacer()
                if let download = models.download {
                    if download.total > 0 {
                        ProgressView(value: Double(download.received), total: Double(download.total))
                            .frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { models.cancel() }
                } else if failed {
                    Button("Try Again") {
                        diskCheck += 1
                        dictation.retryModelPreparation()
                    }
                    .accessibilityIdentifier("modelRetryButton")
                    Button("Show in Finder") { revealModelFolder() }
                        .accessibilityIdentifier("modelRevealButton")
                } else if !missing.isEmpty {
                    Button("Download (\(ModelDownloader.sizeText(missing.reduce(0) { $0 + $1.bytes })))") {
                        models.start(settings.dictationEngine)
                    }
                    .accessibilityIdentifier("modelDownloadButton")
                } else if dictation.modelState == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            if let failure = models.failure, failure.engine == settings.dictationEngine, models.download == nil {
                Text("Download failed: \(failure.message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if failed, let failure = dictation.modelFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If it fails again, the model files may be damaged: move this folder to the Trash, then download the model again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(diskCheck)
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            diskCheck += 1
        }
    }

    private func revealModelFolder() {
        let folder = URL(fileURLWithPath: SettingsStore.modelPath(for: settings.dictationEngine), isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// "Not downloaded" and "downloaded, not yet prepared" are different
    /// things: the first needs the button, the second only time.
    private func modelLabel(missing: [ModelSource]) -> String {
        if let download = models.download {
            return String(localized: "\(download.engine.modelName) · downloading \(download.progressText)")
        }
        let engine = settings.dictationEngine
        let name = engine.modelName
        guard models.isReady(engine) else { return String(localized: "\(name) · not downloaded") }
        guard dictation.modelFailure == nil else {
            return String(localized: "\(name) · couldn’t be prepared")
        }
        guard missing.isEmpty else {
            return String(localized: "\(name) · meetings also need the speech detection model")
        }
        return switch dictation.modelState {
        case .cold: String(localized: "\(name) · downloaded, not prepared yet")
        case .loading: String(localized: "\(name) · preparing (the first time takes up to a few minutes)")
        case .ready: String(localized: "\(name) · ready")
        case .waiting: String(localized: "\(name) · waiting for the engine…")
        }
    }

    /// Green here and done in Getting Started: one answer for both. The
    /// model and the speech detection model are on disk, no download runs,
    /// and the model is prepared without a failure.
    static func isReady(
        _ engine: DictationEngine,
        models: ModelDownloader,
        dictation: DictationCoordinator
    ) -> Bool {
        models.download == nil && models.isReady(engine) && models.missing(engine).isEmpty
            && dictation.modelFailure == nil && dictation.modelState == .ready
    }

    private func modelColor() -> Color {
        let engine = settings.dictationEngine
        if Self.isReady(engine, models: models, dictation: dictation) { return .green }
        guard models.download == nil else { return .orange }
        guard models.isReady(engine), dictation.modelFailure == nil else { return .red }
        // Orange like the footer and the menu: downloaded is not yet ready.
        return .orange
    }
}
