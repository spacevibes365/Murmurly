# CLAUDE.md

What every session needs. The rest loads on demand: what must not be broken in one area is in `.claude/rules/`
and loads by itself when you work on that area's files; how things work is in `reference/`, to open when the task
touches it. Keep this file under 200 lines: a feature's description goes into its rule or its reference.

## Project

A macOS menu bar app for local dictation and meeting recording with on-device speech recognition. Apple silicon
only, macOS 15+. Swift 6, SwiftUI with AppKit where SwiftUI falls short. Speech recognition runs locally;
recordings and transcripts are not uploaded for transcription. Model downloads (Hugging Face) and update checks
use the network. User-selected storage folders may be remote or cloud-synced.

## Commands

The Xcode project is generated from `project.yml` and is not in git: run `xcodegen generate` after any change to
`project.yml` and after adding or removing a file.

```sh
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly -destination 'platform=macOS,arch=arm64' test  # unit + UI
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly -destination 'platform=macOS,arch=arm64' \
  -only-testing:MurmurlyTests test                                   # unit only (what CI runs)
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly analyze
# One test: add -only-testing:MurmurlyTests/<Class>/<testName>

# The stage gate runs the app as shipped: real models, permissions, audio, shortcuts and settings domain.
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tr-stagegate build-for-testing
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tr-stagegate \
  -only-testing:MurmurlyStageGateTests/RealAudioStageGateTests/testProductionColdLaunchIsMenuBarOnly test
```

`scripts/install.sh` builds a Release copy into `~/Applications`. `scripts/release.sh` builds the DMG from a fresh
clone of the committed HEAD and refuses uncommitted changes: `reference/release.md`. The gate's real-audio tests
need models and fixtures that are not in the repository: `reference/test-isolation.md`.

### Traps

- **The `Murmurly` scheme does not build `MurmurlyStageGateTests`.** After touching anything the gate uses, build
  its scheme with `build-for-testing`; a plain `build` does not compile the test target.
- **Build the stage gate into its own `-derivedDataPath`.** Its `.xctest` lands inside the built `.app`, and the
  `Murmurly` scheme then fails on code signing.
- **Exit code 0 does not mean tests ran.** Read the `Executed N tests` lines; a wrong `-only-testing` path exits 0
  with `Executed 0 tests`.
- **XCUITest types through the active keyboard layout.** After touching scenes or the Settings command, run the UI
  tests once on a Latin layout.
- **`Timed out while enabling automation mode`** with no `Executed` line is a hung `testmanagerd`: `kill -9` it.
- **Russian word-form tests skip themselves** on a Mac without macOS's Russian language data (a hosted CI runner).

## Build constraints

- **Warnings are errors** in every target; Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. Keep zero warnings
  in `Sources/` and `Tests/`; third-party packages build with their own settings.
- **Signing goes through `Signing.xcconfig`**: ad-hoc by default, so a fresh clone builds anywhere. To keep
  permissions across rebuilds, name a certificate in a git-ignored `Local.xcconfig`
  (`MURMURLY_CODE_SIGN_IDENTITY = <certificate name>`); never put a certificate name into `project.yml`.
- **Hardened Runtime** is on in Release and off in Debug. `Murmurly.entitlements` carries
  `com.apple.security.cs.disable-library-validation` so a Release build without a Team ID can load Sparkle;
  Release leaves out `get-task-allow`. `scripts/release.sh` refuses the latter and strips the former for
  Developer ID.
- **App Sandbox is off**: the process tap, pasting into other apps and user-chosen meeting folders need their own
  design first. `ARCHS = arm64`: the Core ML models need Apple silicon. `Package.resolved` is not tracked: every
  package is pinned with `exactVersion` in `project.yml`.

Why each of these is so: `reference/release.md`; what was verified on real hardware: `reference/hardware-notes.md`.

## Layout: what is where

Four layers; dependencies point down only (`reference/architecture.md`).

- **Core**: on-disk formats and their readers, no AppKit or SwiftUI, shared with the `murmurly` helper.
- **Services**: what several features use and what knows no feature.
- **Features**: what the user sees as a function of the app.
- **Shell**: launch, object construction, menu, Settings window, updates.

Paths are under `Sources/`. A rule is `.claude/rules/<name>.md`, a reference `reference/<name>.md`.

| Layer | Area | Where | Rule | Reference |
|---|---|---|---|---|
| Core | Disk formats, shared readers | `Archive/` | `core-archive` | `disk-formats` |
| Services | Engines, cache, language, models | `WhisperKitService.swift`, `ModelDownloader.swift`, `Dictation/ParakeetEngine.swift` | `engines-models` | `engines` |
| Services | Speech pipeline, attempt records | `MeetingRecorder/MeetingTranscription.swift` (`MeetingTranscriber`) | `transcription` | `meeting-transcription` |
| Services | System audio capture | `MeetingRecorder/SystemAudioCapture.swift` | `audio-capture` | `meeting-recording` |
| Services | Hotkeys | `Dictation/HotkeyManager.swift`, `HotkeyActivation.swift` | `hotkeys` | `dictation` |
| Services | Dictation archive | `Dictation/DictationHistory*.swift`, `DictationAudioArchive.swift` | `dictation-archive` | `dictation-archive` |
| Services | Personal dictionary, snippets | `PersonalDictionary.swift`, `Settings/DictionarySettingsView.swift` | `dictionary` | `dictionary` |
| Services, Shell | Settings store; Settings window, Storage | `SettingsStore.swift`, `Settings/` | `settings` | `settings` |
| Services | Permissions, login item | `Permissions/`, `LoginItemManager.swift` | `permissions-login` | `app-shell` |
| Features | Dictation | `Dictation/DictationCoordinator.swift`, `MicCapture.swift` | `dictation` | `dictation` |
| Features | Text delivery, last dictation | `Dictation/TextInjector.swift`, `DictationCoordinator.swift` | `text-delivery` | `dictation` |
| Features | Meeting recorder, automatic recording | `MeetingRecorder/MeetingRecorder.swift`, `MeetingWatchdog.swift`, `RecordingsStore.swift` | `meeting-recorder` | `meeting-recording` |
| Features | Live transcript | `MeetingRecorder/LiveTranscript.swift` | `live-transcript` | `live-transcript-and-call-window` |
| Features | Call window reader | `MeetingRecorder/MeetingPageReader.swift` | `call-window` | `live-transcript-and-call-window` |
| Features | Call feed, picked names | `MeetingRecorder/CallFeedWatcher.swift`, `Archive/CallFeed.swift` | `call-feed` | `live-transcript-and-call-window` |
| Features | Transcription queue, compression, move | `MeetingRecorder/MeetingTranscription.swift` (`MeetingTranscriptionQueue`), `MeetingStorage.swift` | `transcription-queue` | `meeting-transcription` |
| Features | Deleting meetings, old audio | `MeetingRecorder/MeetingStorage.swift`, `MeetingLibrary.swift` | `deletion-retention` | `deletion-and-retention` |
| Features | Marks, names, notes (`murmurly.json`) | `MeetingRecorder/MeetingLibrary.swift`, `MeetingLibrary+Notes.swift` | `marks` | `marks-and-notes` |
| Features | Meeting library | `MeetingRecorder/MeetingLibrary*.swift`, `Archive/Meetings.swift` | `meeting-library` | `meetings-window` |
| Features | Transcript: text, search, Save As, player | `MainWindow/TranscriptTextView.swift`, `MeetingPlayer.swift`, `Archive/MeetingText.swift` | `transcript-view` | `meetings-window` |
| Features | Main window | `MainWindow/MainWindow.swift`, `MeetingsView.swift` | `main-window` | `meetings-window` |
| Features | Meeting notepad | `Overlay/Notepad*.swift`, `LiveLinesView.swift`, `NotesInputView.swift` | `notepad` | `notepad` |
| Features | Files section, every open and save panel | `ContentView.swift` (`FilesModel`) | `files-panels` | `files` |
| Shell | Launch, menu, windows, indicator, log | `MurmurlyApp.swift`, `AppLifecycle.swift`, `MenuBar/`, `Overlay/RecordingIndicator.swift` | `app-shell` | `app-shell` |
| Shell | Quit and updates | `AppLifecycle.swift` (`AppDelegate`), `AppUpdater.swift` | `quit-update` | `quit-and-update` |
| Features | The agents' helper | `Helper/`, `Archive/HelperContract.swift` | `agents-helper` | `agents-helper` |
| Features | Connecting agents | `Settings/AgentConnections.swift`, `AgentsSettingsView.swift` | `agent-connections` | `agents-helper` |
| — | Tests, test isolation, probes | `Tests/`, `TestIsolation.swift`, `*Probe.swift` | `tests` | `test-isolation` |
| — | Build and release | `scripts/`, `project.yml`, `.github/` | `release` | `release` |

Cross-cutting references: `architecture` (layers, wiring, owners of the shared rules), `quit-and-update` (every
kind of work and what a quit or an update does with it), `settings` (every key, who writes and who reads it),
`disk-formats` (every file the app writes), `test-isolation`, `release`, `hardware-notes` (verified on real
hardware).

## Rules that hold everywhere

They bind every change. Where today's code falls short of one, that area's reference says so; do not copy it.

- **One microphone.** Dictation and meeting recording refuse to start while the other is busy; nothing else opens
  the microphone. Playback asks before it starts, as `MeetingPlayer` does (`startRefusal`): a sound played during
  a recording lands in its system track.
- **Never lose the user's text or audio silently.** Every ending keeps it somewhere and says where.
- **Never `runModal`, never `.terminateLater`, no nested modal run loop**: both hung quit. Panels are sheets
  through `FilesModel.present` or `begin` (`AppWindowController.chooseFolder`).
- **No stored flag decides whether a window is shown**, and reading a setting never writes one.
- **Tabs and sections are built with their window and only hidden**: `onAppear` runs once. What must happen on a
  switch watches `settings.settingsTab` or `MeetingLibrary.section`; never close a sheet or a panel from there.
- **Unknown is never "none".** A folder, file, record or system answer that cannot be read is reported as unknown;
  only a proven absence is acted on.
- **A meeting folder is told by itself** (`FolderIdentity`), never by its path alone. Whatever moves one or removes
  anything from it takes a `MeetingTranscriptionQueue` operation on the main actor first.
- **No new disk call on the main actor for a path that may be on a network volume**: a serial queue of its own,
  never the cooperative pool.
- **Data the app cannot read as its own version is kept byte for byte**; a known file is changed key by key.
- **A late answer is checked against its token before it touches state**, and a check and the state it guards are
  taken in one main-actor turn. `@Published` emits before the property changes: a sink uses the value it was sent.
- **Work takes a `SettingsSnapshot` when it starts.** A job's own engine or language is laid over it
  (`applying`); nothing writes the settings on a job's behalf.
- **One loaded engine.** Recognition goes through `WhisperKitCache.shared`; work in another engine than a held one
  waits inside its own job, so quit and updates see it.
- **Work that nothing redoes by itself is named to both quit and updates** (`reference/quit-and-update.md`).
- **The dictation shortcut never triggers a permission prompt**: an `.accessory` app cannot present one reliably
  and the hot path may hang. Buttons ask; the Accessibility prompt also appears once per new version at launch.
- **Logs get counts, app names and paths**, never dictated or recognized words or people's names.
- **A test process touches no real service** (only the stage gate does, on purpose), and a new test seam is a
  constructor parameter with a `.live` default, not another `#if DEBUG` branch inside a production function.
- **No new responsibility goes into `MeetingLibrary`**; it comes as its own type.

## Conventions

- Code comments are in English and explain *why*, not *what*.
- Interface text: English is the base language and the catalog key is the English text itself; translations live
  in `Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings`. SwiftUI literals go through
  `LocalizedStringKey`, strings built in code through `String(localized:)`, plurals through the catalog. Russian is
  reviewed (`translated`); a machine translation stays `needs_review` until a native speaker checks it.
- Never translate `UserDefaults` keys, `state` values in `metadata.json`, file names or log messages, and never
  branch on displayed text. UI tests find elements by `accessibilityIdentifier`; both test schemes run in English,
  and `TEST_RUNNER_MURMURLY_UI_LOCALE` runs them against a translated interface.
- Keep it simple: plain code in the existing types; a new type or file only when there is no other way. Remove
  dead code rather than work around it.
- Write tests at the seams where parts meet, not only inside the part you just wrote.
- A bug fix comes with a test that fails without the fix. If a test cannot show the bug, say so and describe how
  it was checked by hand.
- Change behaviour, and you change that area's rule and reference in the same commit. Move a file, and you fix the
  `paths:` of its rule and its row in the map above.
