# CLAUDE.md

Build, architecture and contribution guidance for this repository.

## Project

A macOS menu bar app for local dictation and meeting recording with on-device
speech recognition. Apple silicon only, macOS 15+. Swift 6, SwiftUI with AppKit
where SwiftUI falls short. Speech recognition runs locally; recordings and
transcripts are not uploaded for transcription. Model downloads (Hugging Face)
and update checks use the network. User-selected storage folders may be remote
or cloud-synced.

## Commands

The Xcode project is generated from `project.yml` and is not in git. Run this
after any change to `project.yml` and after adding or removing a file:

```sh
xcodegen generate
```

Build and test:

```sh
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly \
  -destination 'platform=macOS,arch=arm64' test                     # unit + UI
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MurmurlyTests test                               # unit only (what CI runs)
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly analyze
```

A single test:

```sh
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MurmurlyTests/MeetingWatchdogJointTests/testConfiguredExclusionDoesNotStartAtActivation test
```

The stage gate is a separate scheme that runs the app as shipped: real models,
real permissions, real audio, real global shortcuts and the real settings
domain. It runs the Debug configuration with those real services, so it does
not prove the shipped signature: that is `scripts/release.sh`'s and
notarization's job. It is deliberately not part of the `Murmurly` scheme. Anyone can build
it; the production cold-launch check below runs on any machine. The real-audio
tests also need downloaded models and specific audio fixtures that are not in
the repository (see the `MURMURLY_*` variables in
`RealAudioStageGateTests.swift`); they check that particular material, so
arbitrary recordings are no substitute.

```sh
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/tr-stagegate build-for-testing
xcodebuild -project Murmurly.xcodeproj -scheme MurmurlyStageGate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/tr-stagegate \
  -only-testing:MurmurlyStageGateTests/RealAudioStageGateTests/testProductionColdLaunchIsMenuBarOnly test
```

`scripts/install.sh` builds a Release copy and installs it into `~/Applications`.
`scripts/release.sh` builds the DMG: ad-hoc by default, or signed, notarized and
stapled with `DEVELOPER_ID` and `NOTARY_PROFILE`. It builds from a fresh clone
of the committed HEAD in `/private/tmp`, its build folder there too, and
refuses uncommitted changes: a binary keeps the paths it was compiled at, and a
path in a home folder names its owner (0.2 shipped 721 of them). Every image is
then mounted and each file in it searched for the folder that holds the home
folders; a hit stops the release, and `--check-dmg <image>` runs that search
alone. Its Finder window (the app, an arrow, Applications; the layout is in the
script) is written by dmgbuild (pinned, installed into a throwaway environment;
needs Python 3.10+) with `scripts/dmg/background.tiff`, for the very volume it
creates: a `.DS_Store` copied from another image points the picture at that
image's volume, and another Mac then shows Finder's plain default window. The
bookmark dmgbuild writes beside the picture's alias is turned off: Finder on
macOS 26.5 did not resolve it and showed no picture.

### Traps

- **The `Murmurly` scheme does not build `MurmurlyStageGateTests`.** A
  change that breaks only the stage gate passes a green run unnoticed. If you
  touched anything the gate uses, build its scheme with `build-for-testing`: the
  test target is bound to the `test` action, so a plain `build` does not compile
  it at all.
- **Build the stage gate into its own `-derivedDataPath`.** Its `.xctest` lands
  inside the built `.app`, and the `Murmurly` scheme then fails on code
  signing. `clean` only postpones this; separate folders fix it.
- **Exit code 0 does not mean tests ran.** Read the `Executed N tests` lines. A
  wrong `-only-testing` path exits 0 with `Executed 0 tests`.
- **Keyboard layout.** XCUITest's `typeKey` and `typeText` map characters through
  the active keyboard layout. On a non-Latin layout ⌘, cannot be typed, so
  `testCommandCommaOpensSettingsWithoutExistingWindow` skips itself; other UI
  tests open Settings from the menu bar and type only digits. After touching
  scenes or the Settings command, run the UI tests once on a Latin layout.
- **Russian word forms need macOS's Russian language data.** The dictionary's
  word forms come from `NLTagger`; on a Mac without that data (a fresh hosted
  CI runner) the tests of those forms skip themselves (`MacOSRussianWordForms`)
  and say why. There a skip is expected; on a Mac with Russian set up they run.
- **`Timed out while enabling automation mode`** with no `Executed N tests` line
  at all is a hung `testmanagerd`, not a code problem. It ignores SIGTERM:
  `kill -9` it (launchd restarts it on demand) and check with `ps -p <pid>`.

## Build constraints

- **Warnings are errors** in every target (`SWIFT_TREAT_WARNINGS_AS_ERRORS`,
  `GCC_TREAT_WARNINGS_AS_ERRORS`), Swift 6 with `SWIFT_STRICT_CONCURRENCY:
  complete`. Keep zero warnings in `Sources/` and `Tests/`. Warnings from
  third-party Swift packages are built with their own settings and are not ours
  to fix.
- **Signing goes through `Signing.xcconfig`.** The default is ad-hoc (`-`), so a
  fresh clone builds anywhere, but macOS ties permissions to the exact build,
  so you may need to grant them again after a rebuild. To keep most of them,
  name a certificate from your keychain in a git-ignored `Local.xcconfig`:
  `MURMURLY_CODE_SIGN_IDENTITY = <certificate name>`. `project.yml` reads this
  variable; never put a certificate name into `project.yml`. A self-signed
  certificate has no Team ID, so Accessibility stays tied to the binary's
  CDHash. The app asks for it again only at the first launch of a new
  `CFBundleVersion`; after a rebuild of the same version, use **Grant…** in
  Settings → Permissions. Only Developer ID fixes this for good.
- Hardened Runtime is on in Release and off in Debug: a certificate without a
  Team ID fails library validation when XCTest is injected. For the same reason
  `Murmurly.entitlements` carries `com.apple.security.cs.disable-library-validation`:
  without it, a Release build signed ad-hoc or with a self-signed certificate
  crashes at launch because it cannot load the embedded `Sparkle.framework`
  (`different Team IDs`). A Developer ID build does not need it;
  `scripts/release.sh` removes it when re-signing and fails if it is still
  there. Release builds leave out `get-task-allow`
  (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`): Xcode can inject it during
  ordinary builds when base-entitlement injection is enabled (archiving and
  exporting handle it differently), and notarization refuses it.
  `scripts/release.sh` refuses a release in which any signed part carries it;
  the library-validation check applies to the Developer ID path only.
- App Sandbox is off: the process tap, pasting into other apps and user-chosen
  meeting folders need their own design first.
- `ARCHS = arm64`: the Core ML models need Apple silicon.
- `Package.resolved` is not tracked; every package is pinned with `exactVersion`
  in `project.yml`.

## Architecture

A menu bar resident with no Dock icon. `MurmurlyApp` creates the
`@MainActor ObservableObject`s and passes them down: `SettingsStore`,
`RecordingIndicator`, `DictationCoordinator`, `MeetingRecorder`,
`MeetingTranscriptionQueue`, `MeetingLibrary`, `FilesModel`, `ModelDownloader`,
`PermissionManager`, `LoginItemManager`. Shortcuts and background services start
from the `.task` of `MenuBarLabel`, on the label's first render, not when a
window opens: dictation and the meeting watchdog live with all windows closed.
There are two windows. The main window, "Murmurly" (`Window(id: "main")`,
`MainWindow`, at least `MainWindow.minWidth` wide: the 200 pt sidebar, the
divider, the list and the card at their least), shows the meetings; the menu's
first item, "Open Murmurly", opens it, and so does opening the app again while
it runs (`AppDelegate.applicationShouldHandleReopen` → `showMainWindow`, a
bridge set in `MenuBarLabel.task`, whatever else is on screen). Its sidebar
holds Meetings, Starred (the same list, filtered), Dictations, Dictionary and
Files (`MainSection`), each a layer built with the window (`mainContent.*`;
Meetings and Starred one), so each keeps its state and a sheet or a panel up
over one stays through a change of section. The sidebar is a plain stack, not
`NavigationSplitView`, folded by its own toolbar button (in memory), so AppKit
keeps no layout of it in the app's preferences. The section lives in
`MeetingLibrary.section`, in memory: a command from the menu given with the
window closed is there for its first appearance, and Open Murmurly shows the
last one. "Open Full History…" and "Transcribe a File…" open the main window on
their section; "More Languages…", "Download Model…" and an unreachable meetings
folder open Settings, which holds only settings (`SettingsTab`: Getting
Started, Dictation, Meetings, Storage, Agents, Permissions; a stored tab of the three
that left reads as the default). The scene hands the main window the app's
own `FilesModel` and `DictationCoordinator`. The views follow the main
window's section, never Settings' tab: the history's sound stops when
Dictations is left, its error waits for Dictations and once up stays until OK,
and any change of section drops a dictionary file being read. Both scenes are
`.defaultLaunchBehavior(.suppressed)` and `.restorationBehavior(.disabled)`: no
launch shows or restores a window, which the stage gate's cold launch checks.
`AppWindowController.show(_:with:)` opens or raises either. There is no help book,
so the Help menu has no help item (`CommandGroup(replacing: .help) {}`). Open at
login is on by default: the first launch from `/Applications` or
`~/Applications` registers the login item and macOS announces it with "Login
Item Added", so Getting Started shows the same switch as Permissions, next to
automatic recording. Getting Started numbers its five cards as README numbers
the steps; only the model's step gets a check, from `ModelRow.isReady`, the
same answer as the row's green dot. Each permission shows its own mark, and
trying dictation, automatic recording and Open at login are not tasks to tick.
Every tab and section is built with its window and only hidden, so its
`onAppear` runs once, when the window opens; what must happen on a switch
watches `settings.settingsTab` or `MeetingLibrary.section` (the scroll bar's
flash, for one, `SettingsChrome.scrolling`). The Dictionary section's open and
save panels, its import question and the entry sheet (the one opened from
Dictations or a transcript included) stay over a changed section until the
user answers them: SwiftUI runs the update that changes the section inside the
window's layout, and closing a panel or the import question from it ran the
sheet's close animation in a nested run loop there, which re-entered AppKit's
update cycle and crashed (macOS 26.5).

**Two mutually exclusive recording modes.** `DictationCoordinator` (⌥Space) and
`MeetingRecorder` (⌥⇧R) hold weak references to each other
(`dictation.meetingPeer` is set in `MeetingRecorder.activate`) and refuse to
start while the other is busy. Both need the microphone. The refusal shows even
with the recording indicator turned off: `RecordingIndicator.visibleState` then
keeps failures and conflict notices and hides only the plain ones.

**Dictation flow:** `MicCapture` (an actor around `AVAudioEngine`, so
`engine.start()` never blocks the main actor) → temporary CAF → engine →
personal dictionary → history → `TextInjector`. The history is written before delivery: audio and the
JSONL line are one store operation (`saveDictation`), so clearing the history
sees a dictation whole or not at all. If the history write fails, the text is
still delivered as usual and stays in the menu's unsaved dictations until quit; the
temporary CAF is kept. If the recording breaks off (device change, write error),
`MicCapture.stop` returns what was recorded as a `PartialRecording`: it is
recognized and saved as raw CAF marked `interrupted` (and `recognition_failed`
if recognition failed), but never pasted by the dictation itself (⌃⌘V may paste
it, below). A full recording that fails recognition takes the same path: a
history line marked `recognition_failed` with the source CAF byte for byte
(saved even with dictation audio off), or the menu's unsaved dictations if
that save fails; the indicator says where the
audio is, and if the model never became `.ready`, the reason goes to
`modelFailure`. The text is trimmed of leading and trailing spaces and line
breaks after the dictionary, before the history and the paste. With
Accessibility, the previous front app is activated and receives ⌘V. The
dictated text goes on the clipboard for this Mac only (`.currentHostOnly`) and
carries `org.nspasteboard.TransientType` and `.AutoGeneratedType`, so clipboard
histories that honor them skip it. The previous clipboard is then restored,
again for this Mac only, unless `changeCount` (read after the text and its
marks are written) shows someone else changed it: a normal write would make
Universal Clipboard announce the old contents as the newest copy, and a phone
would take them over its own. The cost: what was copied on this Mac before a
dictation no longer reaches other devices after it. The snapshot skips a type
without data and never carries `com.apple.is-remote-clipboard`; an item with no
readable type at all (another device's copy it never handed over) cannot be
kept and is gone from this Mac after the dictation. Without Accessibility the
text stays on the clipboard. Nothing goes into a field macOS itself calls a
password field (`AccessibilityAuthorization.focusedFieldIsSecure`: the focused
element's subrole is `AXSecureTextField`), checked before any clipboard write
or activation and again once the target is in front: the text is neither
pasted nor put on the clipboard, and the banner says where it is. No answer (no
trust, no focused element, an error, the 0.25 s messaging timeout that keeps a
hung app from holding the paste) pastes as before; `IsSecureEventInputEnabled`
is never asked, as Terminal's Secure Keyboard Entry or a password manager turn
it on for every field. With `dictation.autoPaste` off (taken with
`recordingSnapshot`, so a change applies to the next dictation), delivery
neither pastes nor touches the clipboard and the text stays in the history or
the unsaved list: a saved one gets a notice naming ⌃⌘V's shortcut when one is
set, one stopped at the limit an error-style banner, and a failed history write
its usual banner. Never lose text silently. The start is guarded by an attempt
token (`startAttempt`) and an 8 s watchdog: a late success of a
cancelled attempt is wound down instead of changing state. A dictation lasts at
most 5 minutes (`maxRecordingSeconds`); the indicator counts down the last
30 s, and a dictation stopped at the limit is recognized and delivered as usual,
then an error-style banner (shown even with the indicator off) names the limit
and the menu keeps saying so until the next dictation (`lastDictationHitLimit`,
in memory).

**The last dictation again.** ⌃⌘V pastes the last dictation where the cursor
is now and ⌃⌘C puts it on the ordinary clipboard
(`KeyboardShortcuts.Name.pasteLastDictation` / `.copyLastDictation`, set in
Settings → Dictation → Pasting next to `dictation.autoPaste`, which they
ignore). The last one is read fresh at the press, never from the menu's list:
the newest of `historyStore.recent(limit: 1)` and the first of
`unsavedDictations`, the history winning a tie; a history that cannot be read
refuses rather than guess. One without text says where its audio is; an
interrupted one with text is pasted, as the press is the user's own act. The
target is the app in front at key-down; the paste starts at key-up, once
⌃⌥⇧⌘ are all released (a ⌘V posted with ⌃ still down would arrive as ⌃⌘V;
polled every 20 ms, given up after 1.5 s), and a press while one runs is
skipped. A dictation under way refuses both. The paste (`runPasteLast`)
follows `deliver`'s rules: the password-field check, the Accessibility/clipboard
fallback and the feedback. Every
refusal shows with the indicator off; the copy's count is an
`IndicatorState.notice`, which the indicator turned off hides like other
notices.

**Dictation readiness.** One function,
`DictationCoordinator.readiness(modelDownloaded:microphoneGranted:modelState:modelFailure:)`,
answers "will dictation work" for the menu's Dictation line and the Settings
footer (`SettingsWindow.footerText` / `footerColor`, exhaustive `switch`es), in
this order: model downloaded, then preparation failure, then microphone, then model
state; only `.ready` is ready, and Accessibility is not part of it. A failed
warm-up sets `modelFailure`, in memory only and guarded by the engine selection's
generation; `retryModelPreparation()` is both "Try Again" and the path after a
download.

Hotkeys use KeyboardShortcuts (Carbon). The alternative double-press of a
modifier uses `NSEvent` monitors, which need Accessibility but not Input
Monitoring. The third activation, Hold (`HotkeyActivation.hold`), records while
the dictation shortcut is down (`KeyboardShortcuts.onKeyUp`, no monitors): key
repeats and presses while busy are ignored, and only the release of the start
attempt the hold began counts (`DictationCoordinator.holdEnded`). A release
after `minimumHold` (0.5 s) stops as a press would; a shorter one is a slip,
and its recording is stopped and deleted, nothing recognized, saved or pasted;
a release while the microphone is still starting abandons the attempt. An
abandoned start (that release, or Esc) keeps the coordinator busy until both of
its stops are over, its own and the one a late success makes in
`captureDidStart` (`releasedStartAttempt`), deleting their audio, so a new
start cannot reach the capture first and be ended by their late `stop`.

**Esc cancels the paste.** Esc while the microphone starts abandons the start;
while recording it stops the dictation, and while it is recognized it marks
the job (`DictationJob.skipsDelivery`): the text is recognized and saved as
usual but never delivered, and a notice says where it is, naming ⌃⌘V's
shortcut when one is set. Nothing else sets the mark (not a press, a hold's
release or the limit), and a job quit has claimed or whose delivery has begun
ignores Esc. A registered Esc is taken from every app, so it is registered
only while it can still change something (`escapeCancels`, recomputed on every
change of `state`, `job` or `hold`): starting, recording, and recognizing a
dictation that will be pasted. It goes back the moment a cancel is accepted,
an abandoned start or a short hold winds down, or recording stops with
auto-paste off, though the coordinator stays busy until the microphone is done;
`beginTermination` and the coordinator's `deinit` close it too. While a Hold
shortcut is down, Esc is also registered with that
shortcut's modifiers (`HotkeyManager.escapeChord(holding:)`: ⌥Esc for ⌥Space,
fn dropped as Carbon has no such modifier), since that is what the keys send,
and that registration ends with the hold.

**Quitting.** Every path — the Quit item, ⌘Q, logout and SIGTERM (the app turns
the signal into `NSApp.terminate`) — reaches
`AppDelegate.applicationShouldTerminate`. While recording, quitting has two
phases: the first request gets `.terminateCancel`, recordings finish in the
normal event loop, and after a confirmed save the app calls `NSApp.terminate`
again (`.terminateNow`); without confirmation it keeps running and says why.
`.terminateLater` is not used: AppKit would wait in a nested modal run loop
inside `terminate`, and a call from a main-queue block (a main-actor task, the
SIGTERM handler) keeps that loop from draining the main queue, so quit hung
forever. The cost: logout or restart during a recording is cancelled by the
first phase. The 20 s deadline is a separate timer, and on expiry quit is
cancelled, not forced. Quit does not wait for the model: a dictation has a
`DictationJob` with an ownership token; quit takes it, cancels recognition and
saves the raw CAF itself (`recognition_skipped`), and the late pipeline neither
saves a duplicate nor pastes nor deletes the source. Recognize Again (in
Dictations) and a ⌃⌘V being delivered count in `hasUnfinishedWork`. Both are
taken over in the very turn quit is accepted (`claimForTermination` in
`beginTermination`, or `prepareForImmediateQuit` before a `.terminateNow`): a
recognition is cancelled and its late result writes nothing, a save of it
already begun is waited for (its failure is logged and does not refuse quit:
the line and its audio stay), a ⌃⌘V not delivered yet is dropped, and one
already delivering (`pasteDelivering`) is waited for until the clipboard is
restored, never cancelled. What could not be saved stays in `pendingSaves` /
`unconfirmedRecording`, blocks the next quit and is cleared only by success or
by an explicit "Remove" / "Allow Quitting Without Confirmation" in the menu.
Crashes, SIGKILL and power loss are not covered. The DEBUG probe mode
`-QuitProbe` (`Sources/QuitProbe.swift`) and `MurmurlyUITests/QuitProbeTests`
test this in a live process.

A quit by the user (the Quit item, ⌘Q, the Dock, and Sparkle's quit after
"Install and Relaunch") that would end work nothing redoes is cancelled with a
banner that names it (`AppDelegate.QuitLoss`: a meeting transcription running
or queued; the copy of a finished transcript into the chosen folder
(`.transcriptCopy`: a transcribing `activeJob` with `isTranscribing` already
false, no compression or move step yet and a copy folder set), which the
launch-time scan never makes again; a meeting being recorded with "transcribe
after stop", which quit saves but does not queue; a Files run; unsaved Files
text; a meeting's marks not on disk yet, `.unsavedMeetingMark`, and a
transcript being written to the file chosen for it, `.transcriptFile`, both
from `MeetingLibrary.quitLosses` through `AppDelegate.meetingLosses`; a
dictation being recognized again, `.recognizeAgain`, while it recognizes and
its save has not begun, `DictationCoordinator.recognizeAgainWouldBeLost`). The
same quit repeated within 10 s, with nothing new to lose, goes the usual way.
Logout, restart, shutdown (`kAEQuitReason`) and SIGTERM do not wait for a
person: they only log the loss. The route is
`AppDelegate.route(quitReason:signalled:)`; the two Files cases come from
`FilesModel.quitLosses` (`.fileTranscription` while a
run goes, `.unsavedFileText` while `hasUnsavedText`), which `MenuBarLabel` sets
as `AppDelegate.fileLosses` right after `attach`.

**Meeting recording:** the recorder makes the session's folder
(`RecordingsStore.createSession`, on the main actor, before the start is
awaited) and hands it to the capture (`start(in:)`), which removes it on any
failed or cancelled start. `MeetingRecorder.currentSession` holds the folder,
the folder itself (`identity`, so marks and deletions refuse it by any
address), the start time and the trigger from the first moment of starting until the
stop's result is published, the queue's job included: a folder without
`metadata.json` is the recording under way, not one that broke off. The stop
writes `trigger` into `metadata.json`: the automatic recording's app, or
`manual` (`recordingTrigger` stays nil for a manual one; the watchdog tells the
two apart by it). `SystemAudioCapture` (an actor) creates a Core Audio
process tap (`AudioHardwareCreateProcessTap` plus a private aggregate device),
so no Screen Recording permission is needed. The microphone is the aggregate's
input device and the clock source, and one IOProc writes both tracks, so they
share one clock; `MicCapture` is not involved. Output: `system.caf`,
`microphone.caf` and an atomically written `metadata.json` in
`~/Library/Application Support/Murmurly/Meetings/<yyyy-MM-dd HH-mm-ss> Meeting/`.
**Separate tracks are the key design choice:** they give the recording source
and the order of utterances (not speaker identity: the system track mixes
everyone on the call, and the microphone may hear more than one person). A
partial failure never discards the recording: the error carries
`savedDirectory` and the user is told it was saved incompletely.
After `stop`, both closed tracks are opened and measured by actual frames (the
`ExtAudioFileWriteAsync` counter only counts what was queued): an unreadable
track or a write/close error → `failed`; frames that differ from the queued
count, tracks of different length, or audio length more than 2 s off the wall
clock → `suspect`, with the reason in `issues`. A cycle in which one stream is
missing or empty, or the two differ in frames (a Bluetooth headset dropping
out), is left out of both tracks, so they stay aligned, and counted instead of
failing the recording: the recording is then `suspect`, with the missing
seconds by the clock, or with where it ended if the skipping lasted to the
stop, and the clock check reports only audio longer than the clock.
`metadata.json` also holds `frames` / `micFrames` (measured; absent means not
measured) and `enqueuedFrames`. The warning stays in the menu, tied to its
folder.

**Automatic recording** (`MeetingWatchdog`, a 2 s tick). A meeting is a foreign
process holding audio input: Core Audio reports
`kAudioProcessPropertyIsRunningInput` per process without any permission or
prompt. The watchdog acts on explicit `MeetingRecorder` events, not on guesses
from state. Only the microphone holders of the session that was stopped are
banned from restarting it (the snapshot is taken as the stop begins, before the
save is awaited; without one, the session's known holders), and only the holders
of a `capture.start` that actually failed — not a refusal because dictation is
busy or permissions are missing. A ban lifts when the process releases the
microphone. An automatic recording stops 30 s after the last holder lets go,
when the Mac sleeps, or after 4 hours; the limit is checked before the snapshot
is read. A manual start takes over the automatic attempt, so neither the 30 s
stop nor the limit applies to it. Exclusions (`meetingExcludedBundleIDs`) keep
an app from starting a recording; the app's own bundle ID is always excluded.
The tap records the whole system mix, so an exclusion never removes sound.
System Settings and its panes (`com.apple.systempreferences*` and
`com.apple.*-Settings.extension`, as each pane runs as an extension process of
its own) are never holders at all (`MeetingWatchdog.holders`), so they neither
start nor prolong an automatic recording: Sound → Input holds the microphone for
its level meter, and checking the microphone would otherwise record an empty
meeting (on a first install, right after macOS's system audio prompt).
The stop at the 4-hour limit reaches the recorder through the watchdog's own
`requestLimitStop` (`stopFromWatchdog(atLimit: true)`); the recorder names the
limit in `recordingWarning.issues` and shows the "saved with a warning" banner.
That stays in memory: `metadata.json` describes the tracks' integrity, and the
limit is not about the tracks.

**The Murmurly window** reads through `MeetingLibrary` (owned by the app,
like `FilesModel`, so a closed window keeps its snapshot and stops nothing). A
meeting is `MeetingStorage.meetingFolders`: a folder named as recordings are,
with `metadata.json` or a track; Storage counts the same. A root that is
itself a link is listed through its target (`MeetingStorage.rootChildNames`),
its meetings keeping the link's path. Its identity is its
path: a name in both roots is two rows. The library reads only while the
window is open, each folder (the local root, the chosen meetings folder, a
meeting outside both opened from the menu) on a serial `DispatchQueue` of its
own, never the cooperative pool, at most one read per folder at a time;
requests made meanwhile are joined. A read is `fresh` only if started for the
latest request of this opening of the window, a text reaches the screen only
for the meeting and version it was read for, and a read longer than 3 s says
the folder is not responding while the local meetings show. A row's state is
three things: the queue's work (`stepLabel`, the menu's words), the last
attempt by number (unreadable → unknown, never the earlier result), and
whether there is text; transcripts from before records have no completeness.
Sizes come from `MeetingStorage.folderSize`, every file counted, unknown when
part of the folder cannot be read (Storage shows what it counted). A
transcript is parsed to lines only when every line is `[m:ss|h:mm:ss]
**label:** text` below a `---`; anything else is shown as written. A row's
check mark ("Fully transcribed") is only for a last record that says
`complete`; a transcript without such proof is "Transcribed, completeness
unknown", one with gaps a warning (`MeetingText.status`, tested as shown). A
fresh read of a meeting's folder reads its shown text again (Refresh shows a
change made outside and retries a failed read); every request marks the shown
snapshots as not fresh; while the window is closed a read under way ends but
nothing new starts. A folder of a meeting's name that cannot be read stays a
meeting, its row saying so. The selection follows the queue's moves, those
made while the window was closed too, and a local path is followed only while
nothing is there (a copy put back is a meeting of its own). "Show Last
Recording…", "Show Transcript" and "Show Meeting Folder…" (a warning, a failed
transcription) open the meeting in the window (`MeetingLibrary.open`), on
Meetings with the search cleared, whatever the window showed; the Transcribe
Again sheet transcribes the meeting it was opened for at its address now, and
the list and the card are a plain stack (`HSplitView` sized its panes by their
widest and pushed the content past the window's edges). The card is shown only
on Meetings and Starred (`isCardShown`): elsewhere the sound stops and its
files close, Play is refused, an outcome that ends meanwhile is the window's
notice, a wish of the search to focus the text is dropped and the hidden text,
list, name and search field give up the keys (a name being typed is saved);
Refresh and ⌘R are the meetings' own. Deletions' report, `markNotice` and
`exportNotice` stand above every section (`MeetingNotices`). As a search ends,
the list made anew scrolls to the card's meeting, or the first of several
selected, once it shows a row.

**Listening and searching** (`MeetingPlayer`, owned by `MeetingLibrary`, which
alone loads and lets go of it). Two `AVAudioPlayer`s (`MeetingTrack`, the
player's seam; `Deck.live` refuses in any test process whatever its
environment, a DEBUG UI test's `-PlayerProbe` gets `SilentTrack`s) start at one
moment of the output's clock; one rate, volume only 1 or 0, never a gain; the
timeline is the longest file's own length. The files the card's meeting plays
(`MeetingStorage.playback(in:)`: the checked m4a, else the CAF) are opened on
the player's own serial queue for the parent folder (apart from the list's
reads), one track after another, each load under a generation of its own:
right before each open the folder at its address (`FolderIdentity`) and the
track itself (`lstat`: a link or anything unknown is not opened) are checked
again, and a load let go of opens nothing more; a late load only closes what it
opened. Loads still opening are counted by the folder itself (`isOpening`,
late ones included): `beginOperations` takes no folder meanwhile (a move waits
for it, a deletion by hand is refused with the reason, old audio waits for the
next pass), and when it takes one (a move's source and destination, a
deletion, old audio's deletion) it calls `releaseAudio` in that turn and the
player closes the files of those folders by identity; while an operation holds
the folder, nothing opens (`audioRefusal`). A track that won't start or stops
on an error (`AudioPlayerTrack` says why) stops both, with the reason. A
recording starting stops the sound in the turn its state changes, a dictation
pauses it, and both hold Play off at once (`held`), loaded or not; every start
asks `startRefusal` again (recording, dictation, the meeting on the card, the
window, operations). Line times (`MeetingTranscript.Timing`) are the attempt record's
while the file matches its fingerprint and line count, else the file's own
timecodes, said to be approximate. `MeetingTranscript.layout` is the shown text
and its parts, one for the view, "Copy Text" and the search; `MeetingSearch` is
the one rule for a match (case and ё/е alike, nothing else folded), over the
lines' words only. The search reads the newest transcript of each meeting in
batches of 20 on each listing's channel, after the card's and the list's reads,
only while the window is open and only from listings read for the latest
request: each request and answer raises the listing's revision, and a search
read started under an earlier one is dropped, as is a count begun before a
request; a listing being read again keeps its last known matches and says it
is updating. Texts are cached by the folder
itself and kept only for the meeting, folder and version they were read for;
`SearchState` names what was not read, could not be read (a transcript, or a
meeting's folder), lives in a folder not read or is being read again or
counted, and "No matches" waits for all of it. A new query clears the last
one's matches. The list is made anew as the search starts or ends (`.id`):
rows brought back otherwise kept the table's own row height, their time,
source and state cut off. The card shows which match of how many, with arrows, by the
text's selection whatever moved it. ⌘G / ⇧⌘G reach `TranscriptNSTextView`
through the Find menu while the find bar is closed.

**A meeting's marks** (its own name, its star and its speakers' names) live in its folder,
`murmurly.json` (`MeetingMarks`, never translated), written by the window
alone. A change sets fields (`MeetingMarks.Change`), never the whole file: the
file is read once, checked, and that very object is changed and written
atomically, so every other key survives; only a file proven to be version 1 is
written over (no version, another type, version 0, a later version, not JSON
or a read that failed are left byte for byte, the controls off with the
reason). Each meeting folder has one writer, by the folder itself
(`FolderIdentity`: its volume and file number, by `lstat`, so a folder reached
through a link in a parent path, or a meetings-folder meeting opened from
outside both roots, is one folder, and a link at the address is none): it
holds the fields the user set that are not on disk yet, writes one at a time,
takes each successful write as what is on disk, so a later failure loses only
its own fields and a read started before a write does not take it back, and
writes only while the address still holds that folder. While the queue works
on the folder (its `operations`: a move, a deletion, a deletion of old audio,
each taken on the main actor before anything is touched) its marks are
refused, the controls off with the step as the reason; nothing is held for
later. The other way round, a move waits while a write of the
folder's marks is under way (`marksBeingWritten`), then reads the folder again:
one that is not the folder it waited for (replaced meanwhile, or unreadable)
is not moved this time, and the next scan finds it as what it is. A folder the queue may move
(its own rule, `isInMeetingsRoot`) is written at once on the main actor; any
other on its parent folder's serial queue. Until a change is on disk its
folder is in `pendingMarks`: the card says "saving", quit warns and Sparkle
waits. A folder of the same name in both roots, one that cannot be read and
the recording under way take no marks. The name changes the title only, never
the folder; an empty name gives the date back; as in Finder, Return, a click
elsewhere or another meeting save the name being typed, for the folder it was
typed on, and a refusal, a failed write at once included, shows on the card
whatever became of the row; a write off the main actor that fails while
another meeting, or none, is on the card, or the card is out of sight, is said above every section until dismissed
(`markNotice`, naming the meeting); Esc drops it. The sidebar's Starred
filters the same list. The queue's move goes through `mover`, so a test holds
it between the copy and the local folder's removal.

**Speakers' names, Save As, a dictionary entry from the transcript.** The
names are `speakers` in `murmurly.json` (`{"microphone": …, "system": …}`; a
key of another kind inside it stays, a name that is not a string makes the
file unreadable), set in the card's Names sheet through the same writer and
rule as the star (`setNames(typedOn:at:…)`, the meeting found by its folder
as a name typed is; one line each, no `*`, which would end a label early in
Markdown; empty gives the label back). Save closes the sheet only once the
names are on disk (`saveNames` waits for the write of a folder elsewhere),
both fields off meanwhile, so nothing typed is lost unwritten; a
refusal, late too, shows in the sheet with what was typed, the fields on again, and a write that
fails keeps what it would have written (`MarkFailure.lost`), so the card's line
and the window's notice name the names when the sheet was closed first.
They take the place of the labels only
in a transcript its attempt record still matches (`timing == .exact`): line i
gets the name of `lines[i].source`, never by the label's text, so a file
written under another language or with one label for both tracks is named
alike (`MeetingTranscript.named`); any other version says why
(`recordRefusal`: no records at all, the fingerprint differs, or no record
matches), and the player's track buttons take the names whatever the version.
Transcripts and their copies never change, and a new transcription takes the
names as they are. `shownTranscript(of:)` is the one text for the card, Copy
Text and Save As: with names, a line "Names: …" after the header. Save As
(Markdown, plain text, SRT) takes that text at the click: Markdown is the file
byte for byte unless names took the labels' place, then its own header bytes,
the names line and only the labels changed; subtitles only from the record's
exact spans, and only times finite, not negative and under 100 hours
(`subtitlesRefusal`: a record edited by hand may say anything, and 1e20 made
into milliseconds stopped the app). The name is the meeting's start to the minute
(`2026-10-15 10-31 Meeting 2.md`, never translated). One save at a time
(`exporting`, from the click): the panel (`Saving.destination`, a sheet through
`FilesModel.present`), then the write on the library's own serial queue
(`Saving.write`), refused inside any meeting's folder by name or by the
folder itself, links followed (`destinationRefusal`); from the panel's answer
to the end of the write it counts for quit and `AppUpdater.busy`. The outcome
shows on the card while that meeting and version are on it; one that came
while they were not, saved or not, is `exportNotice` above every section
until its cross closes it. The panel goes through `FilesModel.present`, on the
window Save As was clicked in; a test process never opens it: a DEBUG test
with `-FileProbeRoot` gets `meeting-export-<n>.<ext>` in that root, with the
name suggested in `meeting-export-<n>.name`. "Add to Dictionary…"
(beside Copy Text, and first in the text's context menu) opens
`DictionaryEntrySheet(transcript:selected:)` with plain text: the words of the
line the selection began in (`Layout.dictionarySource`) and everything
selected as the spelling. `TranscriptTextView` tells a selection only for the
text it was made in (its identity, and a generation of the text view); the
menu takes the view's own selection at the click. The sheets stay up over a
change of section or meeting until their own buttons close them.

**Deleting a meeting or its audio** (a row's menu, the card's Delete menu, the
card of several selected meetings, ⌘⌫ in the list) goes only to the Trash. A
folder on a volume without one (`CocoaError.featureUnsupported`) is not
deleted: the window says so and shows it in Finder, after part of its audio
went too. "Delete Audio…" takes `MeetingStorage.audio(in:requiringMetadata:
true)`: the tracks `metadata.json` names (plain names in the folder itself,
`isPlainTrackName`), each with its CAF/m4a pair and a killed compression's
leftover; a recording without metadata goes only whole. "Delete Meeting…"
takes `manifest(of:)`: every file at the top of the folder by `lstat`, refused
with a folder or a link inside; Finder's own files (`isSystemFile`) are left
out of the comparison, as Finder rewrites them. Every object is read by
`lstat` and an error is "unknown", never "not there". A folder not named as a
meeting's is never deleted, nor one that is the transcripts folder through any
address; the copies in the transcripts folder are never touched. What the
sheet showed is read again on the folder's queue: another folder or other
files there are asked about again (`removalRecheck`). Then, in one turn of the
main actor, `removalRefusal` and `MeetingTranscriptionQueue.reserve` check the
recording (`Session.identity`, so no link reaches it), the queue's
`operations`, the job under way and the transcriptions waiting for the folder,
each by the folder itself (`Job.identity`, read again after the queue's own
move); a waiting transcription whose folder is not known yet
(`untoldTranscription`) refuses every deletion until it is. The reservation is
an operation (`.removing`) until the end: no job is queued for the folder, its
marks and moves are refused, and its waiting upkeep is dropped. Each call goes
through `MeetingStorage.Removal.perform` on the folder's queue: the folder by
its identity, the file or the manifest by `lstat` again, then `stillWanted`
after that last read, then the backend. A meeting deleted whole has the
transcripts folder its setting names resolved first (`Reader.copiesFolder`; a
folder that cannot be told refuses), then that last check, then only whether
the setting is still the one resolved, which waits for no disk; changed, the
whole admission goes again. Only a meetings root proven absent is empty
(`meetingFolders`): one behind a parent that can't be passed throws. `Removal.live` is the disk outside tests; any test
process gets a refusal, except a DEBUG UI test with `-RemovalProbeTrash` and a
seeded `-MeetingsProbeRoot` (never on, inside or around the owner's meetings
folder, `RecordingsStore.ownersMeetingsRoot`), confined to that root.
After a deletion the menu forgets the folder by any address it went by.

**Old meeting audio** (Settings → Meetings, `meeting.audioRetentionDays`,
`MeetingAudioRetention`: keep, the default, or 7, 30 or 90 days after the end
of the first full transcription). A number of days is written only after a
question that counts first what would go at once (`askAudioRetention`, each
root read for at most 3 s, a root not counted said so); keep is written at
once. `MeetingStorage.audioRetention(of:)` reads the facts strictly:
`metadata.json` says `done`, the meeting is not starred, every attempt record
is readable and numbered once, the last attempt is `complete`, the first and
the last complete ones are consistent (`isConsistentComplete`), and the last
transcript is unchanged by size and SHA-256; anything else keeps the audio,
and the card says why. This deletion is for good, file by file, as a job step
(`.removingAudio`, after the transcription and its copy, before compression),
each file admitted again right before it: the facts read again, the rule and
`SettingsStore.retentionGeneration` (raised by a change of the rule or of the
meetings folder) unchanged, no marks being written. The pass runs at
`activate`, after a yes (only on the meetings the question counted) and daily,
over the local root and the chosen meetings folder. The count
(`AudioCount`) names each meeting by its folder itself and is complete only
when everything was read (a root that can't be listed, a meeting whose facts
can't be read, `Retention.unknown`, or no answer in time say so in the
question); the question carries the meetings and the generation it was counted
under, and a count or a yes under another is counted and asked again. The step
deletes only the meeting it counted (`Job.removesAudio`, with the identity),
and goes after every transcription that is or may be of the meeting: the last
of them takes it over.

**Settings → Storage counts in two steps** (`ArchiveSnapshot.refresh`): this
Mac's figures first, then the chosen folders, which may be on a network volume
and are read off the main actor. Each publication checks that its task was not
cancelled, so a late answer from a folder that is no longer chosen overwrites
nothing. Until a folder answers, its previous figures stay, and the view matches
them to the chosen folder by path, so another folder never borrows them. A
failed count (`archiveFailure`) and the retry counter (`archiveRetry`, used by
"Try Again" and "Move Now") live only in the window's state. Each folder has its
own availability, and "Show in Finder" selects exactly the folder in its row.
The window checks the chosen folders again when the app becomes active and when
a volume is mounted or unmounted. Neither the meetings nor the transcripts
folder may be the dictation archive or inside it: `chooseMeetingsFolder` and
`chooseTranscriptsFolder` compare paths after resolving links and refuse with
`.insideDictationArchive`, which Storage shows as a warning line. Storage
also shows the meeting audio's size and how many meetings have none left
(`ArchiveSnapshot.MeetingAudio`).

**Meeting transcription** (`MeetingTranscription.swift`). `MeetingTranscriber`
finds speech with the Silero VAD, cuts each track into chunks, recognizes them
with the selected engine, drops microphone chunks whose words mostly appear in
the system track at the same time (echo; split on spaces, so it does nothing for
languages written without them), interleaves both tracks by time, applies the
personal dictionary to each line, and writes `transcript.md` (never
overwriting an existing one). `MeetingTranscriptionQueue`
then compresses the tracks to 24-bit ALAC `.m4a`, verified sample by sample,
can move finished meetings to a user-chosen folder, and can copy each transcript
into another folder. The queue remembers where its own moves put each folder in
this run (`movedTo`, in memory, published for the window), and `location(of:)` looks
there once the local folder is gone, so "Show Last Recording…" and the menu's
warnings point at the moved meeting even after the folder setting changes. No
job transcribes the folder being recorded (`currentRecording`, set by the
recorder): it has no metadata until its stop, so `Folder.inspect` alone would
take it for one cut off by a crash.

**Attempt records.** Each transcription attempt of a meeting leaves a hidden
`.attempt <number> <UUID>.murmurly.json` in its folder (`MeetingAttempt`),
written by the queue alone, inside the job's task, before `isTranscribing`
goes back: in progress before the work starts, then its result. Only a folder
`Folder.inspect` accepted gets one; one that cannot be recorded does not start.
A cancel removes it; a result that cannot be written leaves it in progress.
Attempts are ordered by their number, never by the clock, so a record that
cannot be read keeps its place. `complete` means not cut short, no failed chunk
and both tracks the metadata names (or the default ones) there; a transcript
with a gap stays `.saved` in the menu but is `incomplete` on disk. The record
holds the engines, languages, both tracks' labels as written, every line's
span and source in the file's order (no text: the n-th line of the record is
the n-th of its transcript while the fingerprint, size and SHA-256 of the
`.md`, matches). Moves carry it; the copy into the transcripts folder takes
only the `.md`. An attempt that left no record (refused before it began) is in
`unrecordedOutcomes`, by the folder's path, carried by the queue's own move and
cleared by the next attempt.

A meeting is transcribed again from the menu: "Transcribe Meeting…", or
"Transcribe Again…" beside the last outcome, which opens inside that meeting
wherever it is now (`lastMeeting`, through `location(of:)`; Transcribe with
nothing selected takes the folder shown). The folder panel
(`AppWindowController.chooseFolder`: asynchronous `begin`, never `runModal`)
carries an accessory view with Engine and Language for this transcription only
(`MeetingTranscriptionQueue.ChoiceDraft`), taken from the settings as the panel
opens and never written back; a language the engine does not know shows Auto,
as in Settings, and comes back with its engine. Both engines stay choosable:
one not downloaded is marked so, with a button that downloads that engine's
model without touching the dictation's, and the panel's delegate
(`panel(_:validate:)`) refuses Transcribe, the panel staying open, while a file
is missing, tokenizer and VAD included; the OK button itself cannot be turned
off. The panel takes the accessory's size once, as it opens, and never
changes it (`choiceAccessory`), so the model's place always keeps the room of
its tallest state, the button over two lines of a failure: a state that comes
later would otherwise be cut off. A longer reason for the failure is the one
exception, accepted as rare: the panel shows two lines of it and the whole in
its tooltip, as the Files section and the Dictation tab show it whole. The job
carries the choice (`Job.choice`); a job without one, after a stop or from a
scan, follows the settings chunk by chunk as before. The choice reaches the
engine and its request, the model check (again as each job starts,
before any audio is read) and the dictionary's word forms, never the settings.
It belongs to the job: after a move of its own the queue gives the meeting's
waiting jobs its new address. `enqueue` queues a folder again only for a
transcription it does not have yet: a scan joins any job of the folder, a
transcription as the settings say joins any transcription of it, and a choice
only the same choice (engine and the code the engine is asked for); a waiting
scan or automatic job takes a choice over, and any other choice is a job of
its own. Each run writes the next free `transcript N.md` and, with a
transcripts folder, `… Meeting N.md`; nothing written before is touched, and a
copy name already taken is refused and shown in Storage while the transcript
stays. The header names the engine and the language actually used; the job's
start is logged with its engine and language code.

The Files section uses `MeetingTranscriber.transcribeFile`: the same pipeline on
one track, with the tab's choice of engine and language where a meeting job
takes its own, and work files only in a temporary folder, so nothing is
created or deleted next to the user's file. A file run that breaks after at least one
recognized line throws `Failure.fileCutShort` with those lines, the position
and the reason, and the tab keeps them under a note; the user's cancel is still
a `CancellationError`.

Progress steps go `.reading` → `.detecting` → `.preparingModel` /
`.waitingForEngine` → `.recognizing(track:done:total:)`, and the per-chunk ones
come from inside the cache operation: the cache's progress callback feeds a
local `AsyncStream` that the operation drains before it takes the result, so
"recognizing" appears only once the engine is ready and no step arrives after
the result. The meeting menu and the Files section name the same steps.

**The Files section's state lives in the app.** `FilesModel` (in `ContentView.swift`)
is created in `MurmurlyApp` with the other objects and handed to the main
window as an environment object, so closing the window neither stops a run nor loses
its text; it is in memory only. `hasUnsavedText` compares `resultRevision`
with `savedRevision` (copying is not saving), and is the one definition for the
note under the text, the replace sheet and the quit warning. A new file or run
over unsaved text only sets `pendingReplacement` and asks ("Save .md…",
"Replace", "Cancel"); a `Replacement` carries the revision the user agreed to
drop, so a newer result is never replaced unasked, and "Save .md…" replaces only
after the write succeeded. A row under the actions holds the engine and
language of the next run (`FilesModel.choice`, in memory only, never written
to the settings): "As Dictation" (nil, the default after every launch) follows
the settings chunk by chunk, a pick by hand holds for every chunk; the label
tells the two apart, and a line of its own under the menu shows whether that
engine's model is there, with a download of that model alone (beside the menu
it did not fit the window's one width). The choice stays across runs, files and
the window until "As Dictation" takes it back; the menu (`FilesChoiceMenu`) is
off while a run goes. `start()` takes the choice at once, and a run asked for
over unsaved text carries it through the question and the save panel
(`Replacement.Action.rerun(Choice?)`; picking a file, `.file`, carries none and
runs nothing). The model is asked for, that engine's with its tokenizer and the
VAD (`FilesModel.ModelMissing`, `MeetingTranscriber`'s own check), before
the question and again before the shown text is dropped, so a run that cannot
start says why over the text and leaves it. Every open and save panel of the
app's windows (Files', the dictionary's export and import, a meeting's Save
As) goes through `FilesModel.present(_:on:as:)`: a sheet on the window of the
view it was asked from (`WindowAnchor`, read at the click, before anything
waits; a view in a sheet answers with the window the sheet is on), never the
window key when the panel comes; an owner closed by then cancels the choice,
with no panel anywhere. Never `runModal`: nested modal loops already hung quit
and this tab once. A test process never opens a panel, whatever it was told
(`panelBackend`; callers give only AppKit's last call, `sheet`, so the rule is
chosen inside), and the folder panel of Transcribe Meeting… and Storage
(`AppWindowController.chooseFolder`, `begin`) keeps the same rule. The DEBUG
probe `-FileProbeRoot <dir>` (`Sources/FileProbe.swift`), only a temporary
folder, every write of it through `FileProbe.writer`, answers every panel by
what it is for and drives Files in UI tests: the n-th panel, while
`present.hold` is there, says `present-<n>.holding` and waits for
`present-<n>.release`, then `present-<n>.owner` (the window's identifier) or
`present-<n>.cancelled`, the number going with its panel; Choose File… takes
the path in `choose-file-<n>.txt`; saving goes through a gate that waits with
`Task.sleep` and never holds the main thread, and the Dictionary's panels are answered at once by
`dictionary-import-<n>.json` / `dictionary-export-<n>.json` there, unless a
test holds an import's panel (`dictionary-import-<n>.hold` until `.chosen`); the
import's read then waits for `dictionary-import-<n>.release` and the export's
write for `dictionary-export-<n>.release` (or `.fail`). A probe run writes the
choice it was started with (`run-<file>.choice`) before it says it started.
The probe also holds a write of a meeting's marks off the main actor when the
test puts `marks-<n>.hold` there (`marks-<n>.writing`, then `.release` or
`.fail`), and every read of a transcript by the window while `text.hold` is
there (`text.reading` names the meeting, `text.released` follows the hold's
removal); in a test process the card's Add to Dictionary says the selection
the card holds, `start+length`, so a test waits for the very selection it made.

**Engines.** Parakeet TDT v3 through FluidAudio (the default) and Whisper
through WhisperKit. `WhisperKitCache` (an actor, despite its name it serves both
engines) keeps exactly one loaded engine per `EngineDescriptor` and serializes
loads and decodes through a cancellation-aware FIFO with generations: changing
the engine or model path is a hard boundary, and the old engine never becomes a
fallback for a failed new load. WhisperKit types never leave the
`WhisperKitEngine` actor; `WhisperEngine` returns only Sendable DTOs. The
Whisper tokenizer is a separate Hugging Face repository; `WhisperTokenizerLocator`
takes it from next to the model (`Models/openai/whisper-large-v3`) and checks it
before WhisperKit would go to the network for it.

The cache holds one engine, so a meeting job or a Files run in another engine
than the dictation's leaves the dictation its own. Right before each chunk's request, a
job whose engine differs from `DictationCoordinator.heldEngine` waits, shows
`.waitingForEngine` and can be stopped: the dictation's engine while it starts,
records or is recognized (from `recordingSnapshot`), and for 30 s after it ends
(from the settings); nothing before the first dictation. The wait is part of
the job, so quit and updates see it; a job in the dictation's engine never
waits. The recorder hands `heldEngine` and the dictation's warm-up to the queue
(`MeetingRecorder.transcripts`), and `FilesModel.live` takes them from the
dictation itself. The cache and its order are unchanged, so what
is left: a dictation started between the check and the request waits for one
chunk or one load, and one started while a job prepares Whisper for the first
time waits for that whole preparation. Once a series of jobs that had a choice
leaves no transcription to run, whatever its last job was, the queue asks the
dictation's own warm-up to take its engine back
(`DictationCoordinator.prepareAfterOtherEngineJob`): nothing while a dictation is
under way, which warms its selection as it ends; only with its model there;
and under the selection's generation, so a change of the settings wins. Its
failure shows as any warm-up's; the meetings' results and copies are in
already. The Files section asks the same after every run that had a choice,
whatever its end, once the result is shown. The Files section and the meeting
queue do not give way to each other: a meeting in one engine and a file in
another at the same time take the cache by turns and load the models again,
and the warm-up after a file may come in the middle of a series of meetings.

Measured on 2026-10-14 (Mac mini M4, 16 GB, by `murmurly.log`): the first
load of Whisper large-v3 turbo after its download took 104 s, as Core ML
builds the model for the device; every later load, after a relaunch too,
2.3 s. Parakeet loads in 0.5 s. A 2-minute meeting (108 s of speech, 14
chunks) took 2.2 s with Parakeet and 13 s with Whisper, its load included. So
in that window a dictation waits for one chunk (under a second) or one load
(2.3 s), and right after Whisper is downloaded for up to about 100 s. The
dictation's own delay during a job was not measured live: a test process has
no global shortcuts.

**Language.** One setting, `dictationLanguage` (`"auto"` or an ISO code), and
one function that builds the engine request, `SettingsSnapshot.decodeRequest`,
for dictation, meetings and files. The pickers list the selected engine's
languages (`DictationEngine.languages`: 25 European ones for Parakeet,
WhisperKit's list for Whisper). A code the current engine does not know acts as
Auto without rewriting the setting. For Parakeet the language is not a hint but
FluidAudio's script filter: `ru` forbids Latin letters, so English terms come
out in Cyrillic; on Auto Parakeet runs without a filter, chosen by measuring a
Russian meeting recording: some English terms then stay in Latin letters while
others still come out in Cyrillic, and a few short replies come out in Latin;
the filter would turn every term into Cyrillic. The personal dictionary fixes
the terms that still come out wrong. In meetings and files
on Auto, Whisper detects the language per chunk until the first recognized
chunk longer than 5 s fixes it for the rest of the job; chunks are processed
track by track, microphone first, so this is no detector of language changes
during a call. Without a filter Parakeet writes `<unk>` for a few characters
(the Russian letter yo, angle quotes); the engine strips that token. Settings
has a search over the picker by name and code (`filteredLanguages`) that never
hides Auto or the current choice; the menu shows Auto, the current language
and "More Languages…". A language the selected engine does not know is
explained under the picker (`fallbackNote`), and the setting stays. A meeting
job or a Files run may carry its own engine and language (`SettingsSnapshot.Choice`, a code
the engine does not know kept as Auto); it is laid over the settings snapshot
(`SettingsSnapshot.applying`) wherever the job reads them, so `decodeRequest`
stays the one function and the settings are never written, not even for a
moment.

**Personal dictionary** (`Sources/PersonalDictionary.swift`, the Dictionary
tab). An entry is a list of spellings an engine writes ("heard") → how to write
it, with its own switch, a stable ID and a kind: a replacement, or a snippet
(see **Snippets**). It lives in `SettingsStore` as one versioned JSON document
(`dictionary.entries`), saved whole and published only after the data is set;
three switches (`dictionary.inDictation`, `.inMeetings`, `.inFiles`) are on
until turned off, and nothing ever writes a dictionary on its own. A key that
does not read as a document of a version this app reads (damaged, or written by
a newer app after going back to an older one) is kept as it is: jobs run
without replacements and editing waits for an explicit "Clear Dictionary…".
Export… writes that same document (`SettingsStore.encodedDictionary`, one
encoder for the settings and the file: indented, keys sorted), atomically and
off the main actor. The file is open to edit by hand, but every entry needs
its `id` and `enabled`. Import… reads and checks the file off the main actor
and refuses it whole, naming the entry, unless it is a dictionary this app
could have saved itself (`importedDictionary(from:)`): a version it reads, at
least one entry, each id once, every entry as the sheet would take it,
switched-off ones included, as a spelling repeated within one entry is a fault
of the entry itself. Only a file that passed is asked about, and an empty
dictionary is not asked at all: Add keeps every entry of yours (the same id with
other content
stays yours, so an old file never undoes a later edit or switch), skips the
identical ones and brings one whose spelling an enabled entry of yours has in
switched off; Replace takes the file as it is. The merge starts from the
dictionary as it is at the answer and saves once
(`importDictionary(_:replacing:)`); until then the section edits nothing. Any
change of the main window's section while the file is read drops the import,
the Dictionary hidden all along included, as nothing of it is on screen; a
panel or a question already up stays over the new section, and its answer
counts as it would there. Settings' tabs, another window's, change nothing. An export holds Export
and Import from its panel to the end of its write, failed or not, so two
writes never race to one file. Where the dictionary applies and the language
stay the receiving Mac's.
One sheet (`DictionaryEntrySheet`) adds and edits entries, from the tab, from
a history row's "Add to Dictionary…" and from a meeting's transcript
(`Source`: plain text, no history line). From the history it shows the dictation as
recognized (`raw_text`, else `text`) in a copy to select in; "Use Selection"
takes the selection as one spelling by the typed list's own rule
(`DictionaryEntry.variant(fromSelection:)`) and refuses a comma, other
punctuation or a line break instead of splitting or cutting it. The clipboard is
not used, and the history line is never touched. While the key is unreadable the
sheet itself takes no entry and leads to the Dictionary section
(`openDictionary`, given by Dictations and the card). A change of section leaves the
sheet up, with its draft, until Cancel or Save. Its preview runs the real
replacer over the whole dictionary with the draft in place and starts again
when any input changes, a language chosen from the menu bar included.
Every job takes one `DictionarySnapshot`: a dictation with `recordingSnapshot`
when recording starts, a meeting or a file as the job starts, before its speech
model loads (`MeetingTranscriber.dictionary`), while the engine is still read
before every chunk. An edit applies to the next job; a written `transcript.md`
is never redone. Dictation replaces right after the segments are joined
(`transcribe(url:snapshot:dictionary:)`), before the history and the paste, so
both get one text; the history line keeps the recognized text in `raw_text`
only when the dictionary changed it, and a retry or a quit-time save writes that
pair as it is. Meetings and files replace after echo removal and merging
(`MeetingTranscriber.finished`), on each final line's text: echo removal counts
words and must see them as recognized, merging lets a phrase split between two
chunks of one speaker be found, and `report.microphone` / `report.system` stay
as recognized. A whole meeting, one cut short, a file, `incompleteFile` and
`fileCutShort` all take that one step; a dictation that was not recognized
and is tried again by dragging its audio into Files follows the Files switch,
and the tab's choice of engine and language. `DictionaryReplacer` makes one pass
left to right over the words `NLTokenizer` finds (split again at hyphens):
longest variant first, an exact spelling before a word form, the text's own
slices with the written form inserted literally. A variant's words may stand
apart by spaces or one hyphen only; case and the Russian yo/ye never tell words
apart; a rule leaves its own written form alone where it already stands. Word
forms come from macOS's `NLTagger` lemma, one lower-case word at a time with
Russian set, and count only for a variant written wholly in Cyrillic whose
written form has no Cyrillic, and only when the job's language is Auto, Russian
or a code the engine does not know (`DictionarySnapshot.matchesWordForms`, the
same answer as the engine request; a meeting or a file with a choice of its own answers
by that choice, its entries and switches staying the settings'); they are
prepared off the main actor, once per job. They do not reach words macOS does
not know (most loanwords: add the forms needed as more spellings), they also
join singular and plural and homonyms, and they depend on the macOS version;
languages written without spaces are not covered. Logs get the number of
replacements, never the words.

**Snippets** (`DictionaryEntry.Kind.snippet`, `kind: snippet` in the
document). A whole dictation becomes a prepared text: when its words, folded
as spellings are (case, yo/ye) and punctuation aside, equal one of a snippet's
phrases, the dictation is the snippet's text as written, line breaks included,
and no replacement touches it; inside a longer dictation it does nothing, and
word forms never count. Snippets are for dictation only
(`replacer(for: .dictation)` alone includes them, so Recognize Again applies
them too), never meetings or Files. The text is stored as typed, but a
dictation's edges are trimmed, so its leading and trailing spaces and line
breaks are not pasted; one with no text is skipped rather than erase a
dictation. Its phrases follow a spelling's rules, a phrase of any other enabled
entry included. Only the Dictionary section's sheet offers the kind (a picker,
fixed once the entry exists; a snippet gets a multi-line text and no preview),
so an entry from Dictations or a transcript is a replacement. The document is
version 1, byte for byte as before, while the dictionary holds no snippet, and
version 2, which adds `kind`, once it holds one, switched off or not; both are
read, and an entry of an unknown kind makes the document unreadable, kept as it
is. Murmurly 0.2 reads version 1 only, so after going back to it a dictionary
with a snippet applies nothing until it is cleared.

**Models are downloaded by the app.** `ModelDownloader`
(`Sources/ModelDownloader.swift`) describes four models as data pinned to
Hugging Face revisions, lists files through the HF API, writes them straight
into `Models/.partial-<UUID>/` (sha256 for LFS files, size for the rest) and
moves each model into place with one `rename(2)`, the tokenizer before Whisper.
Readiness is the presence of the model files (`coremldata.bin`), not a stored
flag. FluidAudio is held in `ModelHub.offlineMode` and WhisperKit loads with
`download: false`, so the downloader is the only code that fetches models.
Without a model, the dictation shortcut does not record but says where to get
one; a meeting is still recorded and explains how to transcribe it later.

**The agents' helper** (`murmurly`, target `MurmurlyHelper`). A separate
command-line program, read-only, embedded at `Contents/Helpers/murmurly` (not
`Contents/MacOS`: on a case-insensitive volume `murmurly` would be the app's own
`Murmurly`). Its entry is `Sources/Helper/`, left out of the app target; the read
layer it shares with the app is `Sources/Archive/`, in both. Four commands —
`meetings`, `transcript <id>`, `search <text>`, `dictations`, each with
`--json` — and `murmurly mcp`, an MCP server over stdio (swift-sdk, pinned)
whose four tools (`HelperContract.Tools`) go through the same `perform`, so the
CLI and an agent never disagree. The contract is `HelperContract`: ids are
`local:` or `chosen:` and the meeting folder's name; exit codes 2 usage, 3
access denied, 4 not found, 5 read error, 6 not responding (the whole call is
cut at 30 s, the chosen meetings folder at 5 s of its own, its availability
check included, and read once at a time per process: while one read hangs, the
next call answers `notResponding` for it at once and still gives the local
meetings); an answer stays under 1 MiB on the command line and 64 KiB over MCP
(`fitItems`, then `truncated`; one that still does not fit is refused with a
read error asking to narrow it); `meetings` comes 50 at a time (`--limit` 1…500, `hasMore`,
`nextUntil`, a page never split inside one second); every tool description and
the first block of every MCP answer say the text is the participants' words,
not instructions. Access is `agents.meetings`, `agents.dictations` and
`agents.periodDays` (0 is all history; the tab offers 30, 90 and 365), read
from the app's domain on every call and again at its end, for every source a
search covered: switched off or changed meanwhile, the call is refused. The
period's bound is taken at the start of a call, so a long read may return an
item seconds past it. A period that does not read as a
non-negative whole number refuses everything (`HelperContract.periodDays(fromStored:)`,
the one rule for the tab and the helper; the tab shows nothing chosen). Links
are refused (`Archive.Links.refuse`, `O_NOFOLLOW`); a folder that cannot be
read is reported (`unread`, `readError`), never taken for one that is not
there, and nothing outside the period is named, not even in `unread`. A
meeting folder swapped for a link between its check and its read is not
caught: only a process of the same account could do that, and such a process
reads the files directly anyway. Speed: a
listing reads attempt records without their lines, `transcript` finds its
folder by id without a listing, and a search reads in full only the
transcripts and history lines that contain the query by a quick check under
the window's own rule. Every call is logged to
`~/Library/Logs/Murmurly/agents.log` without its text. In DEBUG,
`MURMURLY_HELPER_MEETINGS_ROOT`, `_DICTATIONS_ROOT`, `_SETTINGS` and `_LOG` —
all four or none — and `_MAX_BYTES` replace the roots, settings, log and limit
for tests; Release ignores them. Tests run the embedded helper as a process
with all four and a temporary `HOME`, and skip outside DEBUG.
`scripts/release.sh` signs the helper with the hardened runtime before the app
and checks its team.

**Settings → Agents** (`SettingsTab.agents`, `AgentsSettingsView`) holds the two
switches, the period and **Connect** (`AgentConnections`). Connect to Claude
Code / Codex runs the client found in its usual install places (a GUI app's
`PATH` is short; the child gets the program's own folder first, as npm installs
need `node` beside them) with argument arrays, no shell: `mcp remove murmurly`,
`mcp add … murmurly -- <Contents/Helpers/murmurly of the running copy> mcp`
(Claude with `--scope user`), then `mcp get` must name that path; each step has
a timeout. The path that passed is kept (`agents.claudeCode.helperPath`,
`agents.codex.helperPath`); another path is "out of date", and a failed `add`
after a `remove` forgets it. Only a copy in `~/Applications` or
`/Applications` connects (`LoginItemManager.defaultInstalledBundlePaths`).
Install Command in Terminal links `/usr/local/bin/murmurly` to the running
copy's helper through osascript's administrator prompt, the paths passed as
arguments; a file there that is not such a link is never replaced — the
privileged command checks again right before it links — and no command that
would replace it is offered. The link is read again when the tab
is chosen and when the app becomes active. A test process finds no client and
runs nothing.

**Updates.** Sparkle 2.10.0. `AppUpdater` (`Sources/AppUpdater.swift`) is the
only place the app talks to Sparkle: the standard window with release notes and
"Install and Relaunch", a daily check (`SUEnableAutomaticChecks`, so no consent
question, and the first check right after the first launch), the menu item and
the Updates group in the Permissions tab. Whether checks run is Sparkle's own
setting (`automaticallyChecksForUpdates`); the app keeps no flag of its own.
The feed URL, the download base and the public EdDSA key come from
`MURMURLY_SU_*` in `Signing.xcconfig` (`//` starts an xcconfig comment, hence
`https:/$()/…`), so a fork points them to its own releases. The controller is
created with `startingUpdater: false` and `AppUpdater` calls `SPUUpdater.start()`
itself: on failure the controller would show its alert through a nested modal
run loop, so the reason goes to Settings and the log instead. With an empty key
(a fork's, or one emptied in `Local.xcconfig`) the updater is never created, and
a test process (`TestIsolation.isTestProcess`, the stage gate included) never
creates it either: no feed, no windows.
"Install and Relaunch" quits through the ordinary
quit, so while `AppUpdater.busy` is true the delegate refuses the current
attempt (`updaterShouldRelaunchApplication` → `relaunchNow()`): a meeting being
recorded or saved, a dictation, Recognize Again until its save ends
(`dictation.$recognizingAgainID`), a ⌃⌘V from key-up until its clipboard is
restored (`dictation.$isPastingLast`), a meeting transcription queued or under
way, where a job that transcribes (`activeJob`) counts until it ends, its copy into
the transcripts folder included, a Files run (`files.$isTranscribing`; the
`files:` parameter of `busy` is required, so it cannot be forgotten), a
meeting's marks not on disk yet (`library.$pendingMarks`, required the
same way) and a transcript being written to its file (`library.$exporting`).
Compression and moves of their own are not counted (the launch-time scan queues
them again). Refused, Sparkle closes its window and keeps the prepared update:
it installs at the next quit, and "Check for Updates…" or the daily check offer
"Install and Relaunch" / "Install on Quit" again. Why the window closed is said
by "The update will be installed when you quit the app" in the menu and the
Updates group (`installsAtQuit`, in memory; "Install on Quit" in Sparkle's
window keeps it, "Skip" clears it). Unsaved Files text is not in `busy`: it
never ends by itself and would hold the update until saved. The relaunch then
goes ahead, Sparkle's quit takes the user route and is cancelled by the Files
warning, and `updaterWillRelaunchApplication` → `willRelaunch()` has already set
`installsAtQuit`, so the menu and Settings say the update installs at the next
quit. Postponing the relaunch instead (`shouldPostponeRelaunchForUpdate`) would
leave Sparkle's "Ready to Install" window on screen, unclosable and with a dead
button, for the whole call. `busy` reads the `@Published` streams, not the
objects: `@Published` emits before the property changes. The answer is read
when Sparkle asks; the hand-overs between recorder and queue run synchronously
on the main actor, so the question never lands on the brief `false` between
them. The feed is signed (`SURequireSignedFeed`) and the archive is checked
before extraction (`SUVerifyUpdateBeforeExtraction`). `scripts/release.sh` runs
`generate_appcast` on the verified DMG alone, signs with the key from the login
keychain (or `SPARKLE_PRIVATE_KEY_FILE`) and links the DMG by the release tag
`v<MARKETING_VERSION>`; Sparkle compares `CURRENT_PROJECT_VERSION`. How to create
the key is in the script's header. Without Developer ID every update is a new
CDHash, so macOS may ask for the permissions again.

**Cancellation is end to end.** `FilesModel` keeps `runToken` /
`activeRunToken` so a late progress callback cannot overwrite a final status;
only the Cancel button stops a run, closing the window does not. If
cancellation arrives after the transcription returns, the completed result is
kept ("Cancelled — the text so far is above"); cancelling a transcription in
progress does not keep its partial chunks.

**`AppWindowController`** switches the activation policy: `.regular` (Dock
icon) while a real window is open, `.accessory` otherwise. The recording
indicator is an `NSPanel` and deliberately does not count as a real window, or
the app would stick in the Dock for the whole dictation.

**Appearance.** Settings → Permissions → Appearance offers Match System, Light
and Dark (`ui.appearance`; Match System is the default and writes nothing).
`AppDelegate.followAppearance(of:)` sets `NSApp.appearance` from the value the
publisher sends; it is the first call in `MenuBarLabel`'s `.task`, so Getting
Started already opens in the chosen look. Windows, sheets, panels and the menu
follow it; the recording indicator draws fixed colours and stays dark.

**`PermissionManager` polls instead of subscribing.** There is no reliable
public notification for Accessibility trust changes, so it polls every 3 s while
something is missing and refreshes on app activation, assigning only what
changed (`@Published` sends on every assignment, and each poll would redraw
the menu); `com.apple.accessibility.api` is only an extra trigger, never the
source of truth. The native Accessibility prompt never appears at launch on a first
install (Getting Started explains that the permission is optional first). It
appears once at the first launch of a new version (`CFBundleVersion`) if the
grant is missing, because without Developer ID an update loses it; the version
is kept in `permissions.accessibilityPromptedVersion`, a value for the system
prompt, not a window flag. Otherwise only a button in the menu or Settings
asks. The system audio "Check…"
button only creates and destroys a process tap
(`SystemAudioCapture.canCreateProcessTap`): that proves a source can be created,
not that recording is allowed. macOS asks for system audio at the first meeting
recording, so Settings never shows it as granted. Never trigger permission
prompts from the dictation shortcut: an `.accessory` app cannot present them
reliably and the hot path may hang.

**Logs:** `~/Library/Logs/Murmurly/murmurly.log` plus `os.Logger`; one
generation (`.old.log`) is kept, rotated at launch above 5 MB. Log lines contain
file names and paths.

**Test processes are isolated** (`Sources/TestIsolation.swift`). A test process
is one launched with `-UITesting`, `-UITestSettingsStore` or with XCTest
injected. Any test process skips the launch-time permission prompt, model
warm-up, Getting Started and the login item. In DEBUG it is also isolated: no
global shortcuts or `NSEvent` monitors (⌃⌘V and ⌃⌘C have no initial shortcut
and are not registered, and the Esc listener gets stand-in streams), no
Accessibility query for a password field (unknown, so it pastes as before), no
reading of the Core Audio process list (the watchdog starts nothing), and
archives, log and settings in its own `$TMPDIR/Murmurly-test-<UUID>` (settings
in `settings.plist` there, nothing in `~/Library/Preferences`;
`-MeetingsProbeRoot <dir>` moves the meetings root to a folder a UI test seeded
before launch, with `.m4a` tracks so the launch scan
starts no compression); KeyboardShortcuts' initial shortcuts are not written to
the standard domain. The main window has no split view, so no launch keeps
a layout of it in the app's own domain, the owner's for a test copy.
The exception is reading shortcuts: KeyboardShortcuts reads
only `UserDefaults.standard`, which for the unit-test host is the app's own,
live domain, so a test sets a shortcut only in the process's volatile argument
domain (`IndicatorTests.withMeetingShortcut`), never by writing a domain. The
`MurmurlyStageGate` scheme sets `MURMURLY_PRODUCTION_SERVICES=1` to opt
out of the isolation, so its cold launch is the app as shipped. The opt-out
counts only for a hosted test process: a UI test's launch (`-UITesting`,
`-UITestSettingsStore`) is isolated whatever reached its environment
(`TestIsolation.classify`). Release builds have no isolation at all.

## Dictation archive

The root is `~/Library/Application Support/Murmurly/Dictations/`, created
with mode `0700`, files `0600`. `history.jsonl` is JSONL, one
`DictationHistoryEntry` per line: an open format for ordinary scripts. A
dictation only appends; a line changes only by an explicit action (delete,
Clear All, Recognize Again), each rewriting the index through a temporary file
and an atomic rename (`rewriteHistory`). A last line without a trailing newline
is parsed like any other. `raw_text` is there only when the personal
dictionary changed `text`; search and copy use `text`, and old history is
reprocessed only on request. Recognize Again (a Dictations row with audio)
recognizes the saved audio with the dictation's current engine, language and
dictionary and replaces that line's `text`, `raw_text`,
`actual_language` and `engine` in place, lifting `recognition_failed` /
`recognition_skipped` (`DictationHistoryStore.replaceRecognition`); the audio,
`at`, `duration`, the target, `selected_language` and `interrupted` stay, and
every other line is copied byte for byte, an unreadable one included. An entry
deleted or cleared meanwhile is left alone, the index untouched; an empty
result or an error leaves the line as it was and shows as the section's error.
It runs one at a time (`recognizingAgainID`), is refused while a dictation is
under way or quit has begun, moves neither the indicator nor `modelState` /
`modelFailure`, and does not keep a dictation from starting: that one waits
its turn at the engine cache. A user's quit names it, and quit stops it,
waiting only for a save already begun (**Quitting**); an update waits for it
(**Updates**).

After every actual change to the index (line appended, entry deleted, its
recognition replaced, history cleared — even if removing the audio then
failed) the store posts `dictationHistoryDidChange` with itself as the
`object`. Every consumer (the list and search, Settings statistics, the recent
menu) keeps a `DictationHistoryChanges` for that store, created before its
first read, and re-reads on its revision; the menu is replaced with a fresh
snapshot, never
patched by hand. Dictations counts the history itself (`refreshSummary`, lines
and whether Clear All has anything), whatever window shows it, and an older
count says nothing over a newer one. Dictations reports a failed read or count in the section, with "Try
Again" (`DictationHistoryViewModel.readFailure`); sheets are only for actions
(delete, clear, play).

**Clear All removes only what the archive writes**
(`DictationHistoryStore+Mutation.swift`): it empties the index, deletes the
files `ownedFiles(in:)` names — audio at `<yyyy>/<MM>/<UUID>.caf|m4a` (a
four-digit year, a month 01–12) and leftover `.history-<UUID>.tmp` in the root —
and then removes month and year folders only if nothing is left in them.
Ownership is determined by the path and filename, not by the file's origin. A
meeting moved there under an earlier setting, a note or any other file stays;
links to year or month folders are not followed. A folder that cannot be read
fails the clear instead of passing for empty. Dictations' Clear All stays
enabled while the index has lines or the archive has a file of its own
(`DictationHistoryViewModel.Summary.hasFiles`), so a clear that failed halfway
can be finished.

No absolute paths in the JSONL. `audio_path` is empty when audio is not saved;
otherwise it is relative to `Dictations/`, with audio in dated subfolders.
Moving the whole folder to another Mac or disk must be enough, without
rewriting the JSONL.

Saving dictation audio is off by default: the text is indexed with an empty
`audio_path` and the temporary CAF is deleted only after the history write
succeeds. After a recognition failure, a cut-off or a quit, the audio is saved
regardless of the switch. Saved audio is m4a with **mono 24-bit ALAC at the
microphone's own sample rate**, lossless so the archive can be listened to; if
conversion fails, the original CAF is kept. The format is defined in exactly one
place: `DictationHistoryStore.dictationArchiveFormatID` in
`Sources/Dictation/DictationAudioArchive.swift`. Before encoding, every buffer and
channel is checked for Float32 in `[-1, 1]`: a peak outside, a non-numeric sample
or an unverifiable format keeps the file as a byte-for-byte CAF, because 24-bit
ALAC would clip it silently.

## Verified on real hardware

- The microphone starts up to ~2 s after the system tap. That is normal; both
  tracks share one clock, and `metadata.json` marks real mismatches `suspect`.
- A process tap's stream declares the tap's own rate even when the aggregate
  resamples it. With AirPods in headset mode the microphone, the aggregate's
  clock, runs at 24 kHz, and the tap stream still says 48 kHz while 24 kHz
  arrive, 480 frames a cycle on both. Both files therefore take the aggregate's
  nominal rate (`SystemAudioCapture.trackFormats`), and the IOProc's
  equal-frames check guards it while recording. AirPods also have a 48 kHz
  two-way mode, so a meeting with them is recorded at 24 or 48 kHz.
- Whisper produces stock subtitle phrases on silence. Known ones are dropped
  (`WhisperSegmentDTO.removingKnownSubtitleHallucinations`), and WhisperKit runs
  with `chunkingStrategy: .vad`: its default strategy hallucinated a segment and
  silently skipped real speech after it.
- `.defaultLaunchBehavior(.presented)` no longer reliably materializes a window
  under XCUITest on current macOS; UI tests open Settings through the menu bar.
- A plain Esc registered through KeyboardShortcuts (Carbon) is taken from every
  app while it is registered, Terminal included, and reaches them again once
  it is unregistered. Hence `escapeCancels` keeps it only while a cancel can
  still change something.

## Conventions

- Code comments are in English and explain *why*, not *what*.
- Interface text: English is the base language and the catalog key is the
  English text itself; translations live in the String Catalogs
  `Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings`.
  SwiftUI literals go through `LocalizedStringKey`, strings built in code
  through `String(localized:)`, plurals through the catalog. Russian is
  reviewed (`translated`); machine translations stay `needs_review` until a
  native speaker checks them, so mark a new machine translation the same way.
  Never translate `UserDefaults` keys, `state` values in `metadata.json`, file
  names (the folder suffix ` Meeting` and the transcript copy `… Meeting.md`
  included) or log messages, and never branch on displayed text. Both test
  schemes pass `-AppleLanguages (en)` and `-AppleLocale en_US`; UI tests find
  elements by `accessibilityIdentifier`, and `TEST_RUNNER_MURMURLY_UI_LOCALE`
  (for example `de_DE`) runs them against a translated interface.
- **No stored flag decides whether a window is shown.** A persisted "show the
  window" flag once caused an endless open/close loop. Getting Started, for
  example, is shown when the automatic-recording preference does not exist yet,
  and that key is written before the window opens.
- Keep it simple: plain code in the existing types; a new type or file only when
  there is no other way. Remove dead code rather than work around it.
- Write tests at the seams where parts meet (settings → coordinator, recorder →
  watchdog), not only inside the part you just wrote.
- A bug fix comes with a test that fails without the fix. If a test cannot show
  the bug, say so and describe how it was checked by hand.
