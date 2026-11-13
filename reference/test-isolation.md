# Test isolation, probes and the stage gate

What a test copy of the app may touch, every debug launch argument and environment variable, and what the
stage gate runs. Rule: `.claude/rules/tests.md`.

## The three kinds of test run

| Run | What starts | Scheme |
|---|---|---|
| Unit tests (`MurmurlyTests`) | a Debug copy of `Murmurly.app` hosts the tests: the whole app is built, its menu bar item included | `Murmurly` |
| UI tests (`MurmurlyUITests`) | one fresh launch of the app per test, driven from the runner | `Murmurly` |
| Stage gate (`MurmurlyStageGateTests`) | the same hosting as unit tests, with the isolation switched off | `MurmurlyStageGate` |

Both schemes pass `-AppleLanguages (en)` and `-AppleLocale en_US`. A UI test adds its own launch language from
`AppLanguage` (`Tests/MurmurlyUITests/AppLanguage.swift`): English unless the run sets
`TEST_RUNNER_MURMURLY_UI_LOCALE` (for example `de_DE`), which xcodebuild hands to the runner as
`MURMURLY_UI_LOCALE`.

## How a process is classified (`TestIsolation.classify`)

| Value | True when | Configurations |
|---|---|---|
| `isTestProcess` | launched with `-UITesting` or `-UITestSettingsStore`, or XCTest is injected (`XCTestConfigurationFilePath` in the environment) | every one, Release included |
| `isEnabled` (isolated) | a UI launch (either argument); or a hosted test process whose environment does not say `MURMURLY_PRODUCTION_SERVICES=1` | DEBUG only; always false in Release |

The opt-out counts only for a hosted test process: a UI launch is isolated whatever reached its environment,
because a UI test clicks through the app and one click would otherwise change the owner's settings.

`-UITesting` also makes the app a regular (Dock) application from launch, so XCUITest can reach its windows;
`-UITestSettingsStore` alone marks a UI launch that stays a menu bar resident. Neither has anything else to do
with the settings store.

## What an isolated process does not touch

One folder, `TestIsolation.root` = `$TMPDIR/Murmurly-test-<UUID>`, new for every launch and named in the log's
first line. Nothing in the repository removes it.

| Resource | Isolated process gets | Where |
|---|---|---|
| App settings | a suite inside the root (`settings.plist`), nothing in `~/Library/Preferences` | `TestIsolation.settingsDefaults()`, the default of `SettingsStore`, `PermissionManager`, `LoginItemManager`, `AgentConnections` |
| Dictation archive | `<root>/Dictations` | `DictationHistoryStore.defaultRoot()` |
| Meetings root | `<root>/Meetings` | `RecordingsStore.meetingsRoot()` |
| Log | `<root>/murmurly.log` | `AppLog.fileURL` |
| Global shortcuts, `NSEvent` monitors | none registered; the five shortcut names declare no initial shortcut, so nothing is written for them | `HotkeyManager(installsSystemHandlers:)`, `registerMeeting`, `registerLastDictation` |
| Core Audio process list | not read: the snapshot is `nil`, and the watchdog starts nothing | `MeetingWatchdog.readSystemSnapshot` |
| Accessibility query for a password field | not asked: the answer is "unknown", so the paste goes on | `DictationCoordinator` |

## What every test process skips (the stage gate too)

| Skipped | Where |
|---|---|
| The launch-time Accessibility prompt | `PermissionManager.activate` |
| Model warm-up and the preload of recent history | `DictationCoordinator` (`warmsUp`) |
| Getting Started | `SettingsStore.prepareGettingStarted` |
| The login item | `LoginItemManager` |
| Sparkle: no updater, no feed, no windows | `AppUpdater.init` |
| Open and save panels: answered by the file probe, else no answer | `FilesModel.panelBackend(arguments:testProcess:sheet:)` |
| The folder panel | `AppWindowController.folderPanels(testProcess:begin:)` |
| The Trash and deletion: refused unless the removal probe is set | `MeetingStorage.Removal.backend` |
| Meeting playback: refused unless the player probe is set | `MeetingPlayer.Deck.live` |
| Reading a call window through Accessibility | `MeetingPageReader` (`readLive` answers `.notFound`) |
| Agent clients, osascript, the Terminal link, the clipboard of that tab | `AgentConnections.live()` |

These checks are compiled into Release as well: a shipped copy launched with `-UITesting` keeps its real data
and shortcuts but loses updates, panels, deletion and playback.

## What is not isolated

Closed only by what a test passes in, or by a UI test not pressing the button:

- the microphone (`MicCapture`), the system tap (`SystemAudioCapture`), sounds;
- the clipboard and the synthetic ⌘V of text delivery (`TextInjector`); a `DictationCoordinator` built without
  `deliveryOverride` delivers for real;
- the models folder (`ModelDownloader.defaultRoot`) and model downloads: a test gives its own `root` and
  `session`;
- playback of a dictation's audio, Show in Finder;
- the menu bar item, the activation policy and real windows (the recording indicator has `renderingEnabled`);
- keys AppKit and KeyboardShortcuts keep in `UserDefaults.standard` (window frames, panel sizes, shortcuts):
  the test host has the app's bundle identifier, so that is the installed app's own domain. KeyboardShortcuts
  reads shortcuts from there even when isolated; with no handler installed nothing is registered. A test sets
  a shortcut only in the volatile argument domain (`IndicatorTests.withMeetingShortcut`).

## Probes and launch arguments

All but the first two are DEBUG only (those two mark a test process in Release too, see above). "Needs" says
what else must hold for the argument to act.

| Argument | Needs | Stands in for |
|---|---|---|
| `-UITesting` | | marks a UI launch: isolated, Dock application |
| `-UITestSettingsStore` | | marks a UI launch: isolated |
| `-QuitProbe <scenario> -QuitProbeRoot <dir>` `[-QuitProbeTrigger signal]` | both arguments | microphone, engine, dictation archive and meeting backend; drives one recording to a stage, then quits |
| `-FileProbeRoot <dir>` | `<dir>` is a temporary folder | every open and save panel, drops into Files, a Files run, held writes and reads |
| `-HistoryProbeRoot <dir>` | | the dictation archive's root, plus requests served from it |
| `-MeetingsProbeRoot <dir>` | | the meetings root: a folder the test seeded before launch |
| `-RemovalProbeTrash <dir>` | `-MeetingsProbeRoot` | the Trash and deletion, confined to the seeded root |
| `-PlayerProbe` | | meeting playback: silent 90 s tracks on the system clock |
| `-LiveTranscriptProbe` | `-UITesting` | a recording with five made-up live lines, no capture or engine |
| `-LiveTranscriptProbeManyLines` | the line above | 80 filler lines before them, for scrolling |
| `-LiveTranscriptProbeSession` | the same | a session folder, so marking a moment is enabled |
| `-NotepadProbe` | `-UITesting` | a recording for the notepad, with its own made-up lines |
| `-NotepadProbeStartAfter <s>`, `-NotepadProbeStopAfter <s>` | `-NotepadProbe` | when that recording starts and stops |
| `-SeedSystemAudioCheck none\|created\|failed` | an isolated process | the stored result of the system audio check |

A probe holds no product logic. A test acts and waits through files in the probe's root.

### `-QuitProbe` (`Sources/QuitProbe.swift`, `QuitProbeTests`)

Scenarios: `dictation-recording`, `dictation-recognizing`, `meeting-recording`. The probe builds its own
`DictationCoordinator` and `MeetingRecorder` on fakes, with the archive in `<root>/Dictations` and the session
in `<root>/Meetings/probe`, and sets the engine to Whisper and the language to Auto in the settings it was
given. About 1.5 s after launch it drives the scenario, writes `ready.json` (`scenario`, `reached`, the two
states, whether the engine was called) and asks to quit: `NSApp.terminate`, or SIGTERM to itself with
`-QuitProbeTrigger signal`. For `meeting-recording` it quits twice, a second apart, and records the recorder's
state after the first in `meetingStateAfterFirstQuit`.

### `-FileProbeRoot` (`Sources/FileProbe.swift`)

Active only for a root inside the process's temporary folder, `/tmp` or a sandboxed container's `tmp`
(`FileProbe.isTemporary`); any other root leaves it off. Every marker goes through `FileProbe.writer`. A gate
left closed for 30 s leaves `<name>.timeout` and gives no result.

| Step | The test writes | The probe answers |
|---|---|---|
| Any panel, the n-th asked for | `present.hold` to hold it, then `present-<n>.release` | `present-<n>.holding`; then `present-<n>.owner` (the window's identifier) or `present-<n>.cancelled` |
| Choose File… | `choose-file-<n>.txt` with a path; none means cancelled | |
| A drop into Files | `request-<n>.json` (`id`, `action: drop`, `file`, `error`), then `<id>.release` | `<id>.accepted`, `<id>.delivered`, `<id>.callback` |
| A Files run | `run-<file>.release` | `run-<file>.choice` (`engine:code` or `as dictation`), then `run-<file>.started` |
| Save .md… | `save-<n>.release` | `save-<n>.txt` (the suggested name); after the release, the file `saved-<n>.md` |
| Dictionary import | `dictionary-import-<n>.json`; optionally `.hold` then `.chosen`; `dictionary-import-<n>.release` | `.choosing` when held; `.reading`; `.handled` once the section dealt with the answer |
| Dictionary export | `dictionary-export-<n>.release`, or `.fail` | `.writing`; the file `dictionary-export-<n>.json` |
| A meeting's Save As | | `meeting-export-<n>.<ext>` and `meeting-export-<n>.name` |
| A write of a meeting's marks off the main actor | `marks-<n>.hold`, then `marks-<n>.release` or `.fail` | `marks-<n>.writing` |
| A read of a transcript by the window | `text.hold`; remove it to release | `text.reading` (the meeting's folder name), `text.released` |

Without `-FileProbeRoot`, a test process asked for a panel gets no answer at all.

### `-HistoryProbeRoot` (`Sources/HistoryProbe.swift`)

`DictationHistoryStore.defaultRoot()` becomes `<dir>`. For 300 s the probe serves two requests there:
`append-request.json` (`id`, `text`, optionally `raw_text`) appends one dictation through the shared store and
answers `appended-<id>.json`; a file `change-request` makes the store announce a change without making one,
and is removed once announced.

### Meetings: `-MeetingsProbeRoot`, `-RemovalProbeTrash`, `-PlayerProbe`

The seeded root replaces the isolated `Meetings` folder. Tests seed it with `.m4a` tracks, so the launch scan
starts no compression. With `-RemovalProbeTrash <dir>` deletions work, moving into that folder instead of the
Trash, and only inside the seeded root: the backend refuses when the seeded root is the owner's meetings
folder (`RecordingsStore.ownersMeetingsRoot`), inside it or around it, and without `-MeetingsProbeRoot`.

### Live transcript and notepad

`LiveTranscriptProbe` (`Sources/LiveTranscriptProbe.swift`) and `NotepadProbe`
(`Sources/Overlay/NotepadWindow.swift`) publish `.recording` and a filled `LiveTranscriptModel` through the
recorder's `…ForTesting` entry points. Their made-up lines differ on purpose, so the two are never mistaken for
each other on screen. In an isolated process the card's Add to Dictionary button also reports the selection it
holds as its accessibility value (`start+length`), so a UI test waits for the very selection it made.

## The helper's overrides (`HelperEnvironment`, DEBUG only)

| Variable | Replaces |
|---|---|
| `MURMURLY_HELPER_MEETINGS_ROOT`, `_DICTATIONS_ROOT`, `_SETTINGS`, `_LOG` | the local meetings root, the dictation archive, the settings (a plist file in place of the domain) and the log: all four or none; one to three is a usage error, before anything is read |
| `MURMURLY_HELPER_MAX_BYTES` | the size limit of an answer, for the command line and MCP alike |
| `MURMURLY_HELPER_TIMEOUT` | the 30 s limit of one MCP call, in seconds |
| `MURMURLY_HELPER_HOLD` | while the named file exists, `perform` waits before reading anything |
| `MURMURLY_HELPER_HOLD_LOCAL` | the same, before the local root is listed |
| `MURMURLY_HELPER_HOLD_CHOSEN` | the same, inside the chosen folder's read |
| `MURMURLY_HELPER_HOLD_ANSWER` | `requireStillAllowed` creates `<path>.reached` and waits for `<path>` to go, right before its settings read |

A hold is polled every 50 ms and gives up after 60 s. A Release helper reads none of them, so
`HelperCommandTests` and `HelperPerformanceTests` run the embedded helper as a process with all four set and
skip themselves outside DEBUG or when the build has no helper. `MURMURLY_PERF_FULL` only widens the
performance test.

## The stage gate

`MurmurlyStageGate` runs `MurmurlyStageGateTests` with `MURMURLY_PRODUCTION_SERVICES=1`: a hosted test process
that is not isolated, so shortcuts, the process list, the settings domain, both archives and the log are the
real ones. It is the Debug configuration, so it proves nothing about the shipped signature. Everything in
"What every test process skips" still holds in it.

Build it into its own `-derivedDataPath`: its `.xctest` lands inside the built `.app`, and the `Murmurly`
scheme then fails on code signing. The `Murmurly` scheme does not compile the gate's target, and neither does
CI, which runs `-only-testing:MurmurlyTests` only.

| Test | Needs | Touches on the machine |
|---|---|---|
| `testProductionColdLaunchIsMenuBarOnly` | nothing | reads only: accessory policy, no real window, real log and archive paths, a readable process snapshot, at least five shortcut registrations |
| `testRealDictationUsesPersistentModelPath` | Whisper model, the monologue fixture | appends a line to the real dictation history and delivers the text (clipboard or paste) |
| `testLiveMeetingCaptureRecordsKnownSystemSpeech` | microphone grant, system audio, speakers | creates a meeting folder in the real meetings root, plays the fixture aloud |
| `testRecordedMeetingTracksContainRecognizableSpeech` | `MURMURLY_MEETING_SYSTEM_AUDIO` and `MURMURLY_MEETING_MIC_AUDIO`, else the newest folder of the real meetings root | reads those tracks, attaches the recognized text to the result bundle |
| `testCurrentTCCStatusAndAuthorizedMicrophoneCapture` | | records from the microphone when it is granted |
| `testRealWhisper…`, `testFilesTabTranscribesMonologueWithEitherEngine` | models, fixtures | temporary files only |
| `testParakeet…` / `testWhisperTranscribesMeetingFixture`, `testCompressedFixtureIsExactAndTranscribesTheSameChunks` | `MURMURLY_MEETING_FIXTURE`, else skipped | a clone of the fixture |
| `testMeetingWaitsForItsVolumeAndMovesWhenItIsMounted` | `MURMURLY_MOVE_GATE=1`, else skipped | disk images it creates |

Fixtures are not in the repository. `MURMURLY_MODEL_PATH`, `MURMURLY_MONO_AUDIO` and `MURMURLY_DIALOGUE_AUDIO`
override the defaults under `~/Library/Caches/Murmurly/StageGate/`; `MURMURLY_STAGE_GATE_OUTPUT` moves the
results folder. The tests check that particular material, so other recordings are no substitute.

## Commands

```sh
# unit only (what CI runs)
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly \
  -destination 'platform=macOS,arch=arm64' -only-testing:MurmurlyTests test
# the stage gate: compile it, then the check that runs on any machine
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/tr-stagegate build-for-testing
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/tr-stagegate \
  -only-testing:MurmurlyStageGateTests/RealAudioStageGateTests/testProductionColdLaunchIsMenuBarOnly test
```

`-only-testing` takes a class name, not a file name: `ArchiveTests.swift` holds `ArchiveMeetingsTests`,
`ArchiveDictationsTests` and `ArchiveFastPathTests`, and a path that matches nothing exits 0 with
`Executed 0 tests`.

## Skips to expect

| Where | Why |
|---|---|
| UI tests that type ⌘, ⌘R, ⌘F or ⌘G | `typeKey` maps through the active keyboard layout; they check the physical key first and skip on a non-Latin layout |
| `testAClickOnTheNotepadBringsItAndMurmurlyForward` | a raw HID click needs a runner trusted to post events, which a rebuilt runner is not |
| Tests guarded by `MacOSRussianWordForms.require()` | word forms come from `NLTagger`, which needs macOS's Russian language data; a fresh hosted runner has none |
| Helper tests | outside DEBUG, or without an embedded helper |
| Stage gate tests | without their fixture variables |

## Why it is this way

- **A UI launch ignores the opt-out.** The gate's variable could reach a UI test's copy from the environment
  of the run; that copy is clicked through, and one click would set the owner's settings.
- **Settings as a file in the root.** A path as the suite name keeps the plist inside the temporary root
  instead of leaving one more domain in `~/Library/Preferences` for every launch.
- **No initial shortcuts in a test copy.** KeyboardShortcuts writes a name's initial combination into
  `UserDefaults.standard` the first time the name is touched.
- **Probes are files, not timers.** A gate a test opens proves the order of two events; a sleep only makes the
  wrong order less likely. A probe that holds no product logic also builds unchanged on the tree before a fix,
  which is how a test is shown to fail without it.
- **`.defaultLaunchBehavior(.presented)` no longer reliably shows a window under XCUITest** on current macOS,
  so UI tests open the windows through the menu bar.
- **`Timed out while enabling automation mode`** with no `Executed` line is a hung `testmanagerd`, not a code
  problem. It ignores SIGTERM: `kill -9` it (launchd restarts it on demand) and check with `ps -p <pid>`.
