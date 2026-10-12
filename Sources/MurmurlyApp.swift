import SwiftUI

@main
struct MurmurlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var indicator: RecordingIndicator
    @StateObject private var dictation: DictationCoordinator
    @StateObject private var meeting: MeetingRecorder
    @StateObject private var meetingTranscripts: MeetingTranscriptionQueue
    @StateObject private var models: ModelDownloader
    @StateObject private var files: FilesModel
    @StateObject private var permissions = PermissionManager()
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var updater: AppUpdater

    init() {
        let settings = SettingsStore()
        #if DEBUG
        SystemAudioCheckSeed.apply(to: settings)
        #endif
        let models = ModelDownloader()
        let levelMeter = MicrophoneLevelMeter()
        let indicator = RecordingIndicator(settings: settings, levelMeter: levelMeter)
        _settings = StateObject(wrappedValue: settings)
        _indicator = StateObject(wrappedValue: indicator)
        let transcripts = MeetingTranscriptionQueue(
            transcriber: .live(settings: settings, models: models),
            destinations: { settings.meetingDestinations }
        )
        let recorders = Self.makeRecorders(
            settings: settings,
            indicator: indicator,
            levelMeter: levelMeter,
            transcripts: transcripts,
            models: models
        )
        _models = StateObject(wrappedValue: models)
        // Here rather than in the window, so a Files run and its unsaved text
        // outlive the window.
        let files = FilesModel.live(settings: settings, models: models)
        _files = StateObject(wrappedValue: files)
        _dictation = StateObject(wrappedValue: recorders.dictation)
        _meeting = StateObject(wrappedValue: recorders.meeting)
        _meetingTranscripts = StateObject(wrappedValue: transcripts)
        AppLog.rotateIfNeeded()
        // An isolated launch keeps its log, archives and settings in one
        // folder and names it, so the runner removes exactly what it created.
        AppLog.info(
            "app",
            TestIsolation.isEnabled
                ? "launch; test isolation; root → \(TestIsolation.root.path)"
                : "launch; log → \(AppLog.fileURL.path)"
        )
        // StateObject would defer an inline AppUpdater() to first use; built
        // here, the updater starts and schedules its daily check at launch.
        let updater = AppUpdater(busy: AppUpdater.busy(
            meeting: recorders.meeting, dictation: recorders.dictation, transcripts: transcripts, files: files
        ))
        _updater = StateObject(wrappedValue: updater)
    }

    private static func makeRecorders(
        settings: SettingsStore,
        indicator: RecordingIndicator,
        levelMeter: MicrophoneLevelMeter,
        transcripts: MeetingTranscriptionQueue,
        models: ModelDownloader
    ) -> (dictation: DictationCoordinator, meeting: MeetingRecorder) {
        #if DEBUG
        HistoryProbe.startIfRequested()
        FileProbe.startIfRequested()
        if let probe = QuitProbe.fromLaunchArguments(settings: settings, indicator: indicator) {
            return (probe.dictation, probe.meeting)
        }
        #endif
        let meeting = MeetingRecorder(capture: SystemAudioCapture(), indicator: indicator)
        meeting.transcripts = transcripts
        return (
            DictationCoordinator(mic: MicCapture(levelMeter: levelMeter), indicator: indicator, models: models),
            meeting
        )
    }

    var body: some Scene {
        // Menu-bar resident: always present, so the hotkey (registered in the
        // label's .task) is live even when no window is open. Icon = "M", red +
        // dot when a permission is missing.
        MenuBarExtra {
            DictationMenuView(
                dictation: dictation,
                meeting: meeting,
                meetingTranscripts: meetingTranscripts,
                permissions: permissions,
                settings: settings,
                models: models,
                updater: updater
            )
        } label: {
            MenuBarLabel(
                dictation: dictation,
                meeting: meeting,
                permissions: permissions,
                settings: settings,
                loginItem: loginItem,
                files: files,
                appDelegate: appDelegate
            )
        }
        .menuBarExtraStyle(.menu)
        .commands { SettingsCommands() }

        // A regular, single-instance window avoids the special Settings scene's
        // activation race when opened from a menu-bar-only app.
        Window("Settings", id: "settings") {
            SettingsWindow()
                .environmentObject(settings)
                .environmentObject(indicator)
                .environmentObject(permissions)
                .environmentObject(loginItem)
                .environmentObject(dictation)
                .environmentObject(meeting)
                .environmentObject(meetingTranscripts)
                .environmentObject(models)
                .environmentObject(updater)
                .environmentObject(files)
                .onAppear { AppWindowController.enterRegular() }      // Dock icon while Settings open
                .onDisappear { AppWindowController.windowDidClose() } // back to accessory when closed
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                AppWindowController.enterRegular()
                openWindow(id: "settings")
            }
                .keyboardShortcut(",", modifiers: .command)
        }
        // No help book: the standard item would only say "Help isn't available".
        CommandGroup(replacing: .help) {}
    }
}
