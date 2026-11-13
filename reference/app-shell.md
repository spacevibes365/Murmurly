# App shell

How the app is put together at launch: which objects exist and who builds them, what starts the services,
the two windows and the Dock icon, the menu, the recording indicator, the look, the log, the permissions and
the login item. Rules: `.claude/rules/app-shell.md`, `.claude/rules/permissions-login.md`. Quit and updates
have their own document, `reference/quit-and-update.md`; the settings keys are in `reference/settings.md`.

## What the shell is

A menu bar resident with no Dock icon. `AppDelegate.applicationWillFinishLaunching` sets the activation policy
to `.accessory`; the scene is a `MenuBarExtra` in `.menu` style whose label is the letter "M" (`MenuBarLabel`)
and whose content is the menu (`DictationMenuView`). Two `Window` scenes exist beside it and neither opens at
launch.

| File | What is in it |
|---|---|
| `Sources/MurmurlyApp.swift` | `MurmurlyApp`: builds the objects, declares the scenes; `SettingsCommands` |
| `Sources/MenuBar/DictationMenuView.swift` | `MenuBarLabel` (the launch task), `DictationMenuView` (the whole menu), `AppWindowController.show(_:with:)` |
| `Sources/AppLifecycle.swift` | `AppDelegate` (quit, reopen, appearance), `AppWindowController` (activation policy, folder panel) |
| `Sources/Logging.swift` | `AppLog` |
| `Sources/Overlay/RecordingIndicator.swift`, `IndicatorView.swift`, `OverlayPlacement.swift` | the recording indicator |
| `Sources/Permissions/`, `Sources/LoginItemManager.swift` | permissions and the login item |

## Objects

`MurmurlyApp.init` builds every long-lived object once and hands them down; all are `@MainActor`
`ObservableObject`s held as `@StateObject`, except `NotepadNotes`, a plain constant. They are built in this
order, because each takes the earlier ones:

| Object | Built from | Notes |
|---|---|---|
| `SettingsStore` | `TestIsolation.settingsDefaults()` | |
| `ModelDownloader` | | |
| `RecordingIndicator` | settings, a `MicrophoneLevelMeter` | one indicator for dictation and meetings |
| `MeetingTranscriptionQueue` | `MeetingTranscriber.live(settings:models:)`, `destinations: { settings.meetingDestinations }` | then `audioRetention` and `writeAudioRetention` are set as closures over the settings |
| `MeetingRecorder`, `DictationCoordinator` | `makeRecorders` | the recorder gets `transcripts = queue` here |
| `LiveTranscriptPanel` | settings, the recorder | the notepad's window |
| `FilesModel` | `FilesModel.live(settings:models:dictation:)` | owned by the app so a run and its text outlive the window |
| `MeetingLibrary` | recorder, queue, settings, `Reader.disk`, dictation | owned by the app so a closed window keeps its snapshot |
| `NotepadNotes` | `NotepadNotes.attach(notepad:recorder:library:)` | ties the notepad to the recorder and the library |
| `AppUpdater` | `AppUpdater.busy(meeting:dictation:transcripts:files:library:)` | built in `init`, not inline, so Sparkle starts at launch |
| `PermissionManager`, `LoginItemManager` | default initializers | declared inline |

`AppLog.rotateIfNeeded()` and the launch line are written in the same `init`, before the updater is built.

## What starts the services

Nothing in `init` registers a shortcut or starts a watcher. That happens in the `.task` of `MenuBarLabel`,
which SwiftUI runs when the label first renders, at launch, with no window open. Its body is synchronous and
runs in this order:

1. `appDelegate.followAppearance(of: settings)`.
2. `permissions.activate()`: the launch-time Accessibility prompt, when one is due.
3. `dictation.activate(settings:permissions:)`: the dictation shortcuts, the history preload, the subscription
   to the engine setting that warms the model.
4. `meeting.notepadLinks = .init(library:)`, then `meeting.activate(...)`: sets `dictation.meetingPeer`, asks
   `settings.prepareGettingStarted()` and opens Getting Started when it says so, registers the meeting
   shortcut, creates and starts `MeetingWatchdog`, and calls `transcripts?.activate()` (the daily audio rule,
   the mount observer, the scan of the local meetings folder).
5. `loginItem.activate(desired: settings.launchAtLogin)`.
6. `appDelegate.attach(dictation:meeting:settings:)`, `fileLosses`, `meetingLosses`, `showMainWindow`, and the
   static `MeetingLibrary.showMainWindow`.

`permissions.activate`, `dictation.activate` and `meeting.activate` each guard themselves with an `activated`
flag, so a second run of the task registers nothing twice.

What holds before the task has run:

| Link | Until it is set |
|---|---|
| `AppDelegate`'s weak `dictation`, `meeting`, `settings` | quit answers `.terminateNow` and saves nothing |
| `AppDelegate.fileLosses`, `meetingLosses` | "nothing to lose" |
| `AppDelegate.showMainWindow` | reopening the app shows nothing |
| `MeetingLibrary.showMainWindow` | `openAndPlay` and the notepad cannot show the main window |
| `DictationCoordinator.meetingPeer` | dictation does not know a meeting is busy |
| `MeetingRecorder.notepadLinks` | the notepad has no library |

Everything that can create work (shortcuts, the watchdog, the scan, both windows) is behind the same task, so
these defaults are not reached with work under way. `AppUpdater.busy`, by contrast, holds its five objects from
`init`.

## Windows

| Scene | Id | Content | Size |
|---|---|---|---|
| "Murmurly" | `main` | `MainWindow`, with the app's own library, settings, recorder, queue, models, `FilesModel` and `DictationCoordinator` in the environment | resizable, at least `MainWindow.minWidth` by 560 pt, 1100 by 720 by default |
| "Settings" | `settings` | `SettingsWindow` | fixed, `SettingsChrome.windowWidth` by `windowHeight` |

Both are `.defaultLaunchBehavior(.suppressed)` and `.restorationBehavior(.disabled)`. Settings is an ordinary
single-instance `Window`, not the `Settings` scene. `SettingsCommands` replaces the app-settings command with
"Settings…" (⌘,) and replaces the Help group with nothing, as there is no help book. `TextEditingCommands`
is there so Find in a transcript goes through the menu's items.

`AppDelegate.applicationShouldHandleReopen` (the app opened again from Finder, Launchpad or the Dock while it
runs) calls `showMainWindow` and returns `false`, so SwiftUI opens nothing of its own: the main window comes
up whatever else is on screen.

Three ways open a window, and all make the app `.regular` first:

- `AppWindowController.show(_:with:)`, from the menu, the other window or a reopen. On the next turn of the
  main queue (after the menu has closed) it sets the policy to `.regular`, activates, calls `openWindow(id:)`,
  and one turn later activates again and brings the window whose identifier is the scene id to the front.
- `SettingsCommands` and the Getting Started closure call `enterRegular()` and `openWindow(id: "settings")`
  directly.
- Each window's root also calls `enterRegular()` in `onAppear` and `windowDidClose()` in `onDisappear`.

## The Dock icon

`AppWindowController` keeps the activation policy by hand. `enterRegular()` sets `.regular` and activates the
app. `windowDidClose()` looks, one turn of the main queue later, at `NSApp.windows` and goes back to
`.accessory` when `visibleRealWindowCount` is zero. A real window is one that is visible, is not an `NSPanel`
(nor a `NotepadNSWindow`, named on its own) and can become main. The recording indicator, the notepad and the
open and save panels are therefore never real windows.

Who makes the app `.regular`, and what takes it back:

| Caller of `enterRegular()` | Paired `windowDidClose()` |
|---|---|
| each window's `onAppear` | its `onDisappear` |
| `SettingsCommands`, the Getting Started closure, `show(_:with:)` (its own two lines) | the window's `onDisappear` |
| `AppWindowController.begin`, the folder panel of Transcribe Meeting… and Storage | the panel's completion, in a `defer` |
| `MeetingRecorder.beginStart` for a manual start (no trigger) | the end of the start task |
| Sparkle, when its install stage brings the app into the Dock | `AppUpdater.standardUserDriverWillFinishUpdateSession` |

So the app is `.regular` not only while a window is open: a recording started by hand makes it regular and
active for the length of its start (the 150 ms `permissionPromptDelay`, `capture.start`, the call-window
watcher and the live transcript's start), and a folder panel does for as long as it is up. The count looks at
`isVisible` only.

`waitUntilPermissionPromptCanBePresented(timeout:)` polls every 50 ms, for 2 s at most, until the app is
active and a real window is visible; the menu awaits it before asking for the microphone.

`chooseFolder(message:prompt:directory:accessory:delegate:begin:show:completion:)` builds an `NSOpenPanel` for
folders on the next turn of the main queue and shows it with `panel.begin`, with no parent window, since the
menu asks with none open. In a test process `folderPanels(testProcess:begin:)` swaps the panel for a log line.

## The menu

`DictationMenuView` observes dictation, the recorder, the queue, permissions, settings, models, the updater and
the notepad's panel, and is rebuilt on any of their publications. Top to bottom:

| Item | What it does |
|---|---|
| Open Murmurly | `show("main")`: the main window on its last section |
| Download Model… / Downloading… / Cancel Download | only while a model is downloading (either engine's, under its own name) or the selected engine's is missing, the VAD included; Download starts it and opens Settings on Dictation |
| the dictation line | `DictationCoordinator.readiness(...)` when idle, the state otherwise |
| Dictation Engine, Dictation Language | pickers bound to the settings; the language menu holds Auto, the current choice and "More Languages…" (Settings, Dictation) |
| Dictation History | the recent dictations (copy on click) and "Open Full History…" (the main window on Dictations) |
| Unsaved Dictations (N) | only when there are some: Copy, Show Audio in Finder, Remove |
| the meeting line and its hint | `MeetingRecorder.state`, `failureHint` |
| Record Meetings Automatically; Exclude … from Auto-Recording | the settings; the second only during an automatic recording of an app not excluded yet |
| Record Meeting / Stop Recording Meeting | `meeting.toggle()`, off while starting or stopping |
| Show Live Transcript | while `liveTranscript.canReopen` |
| Show Last Recording… | opens that meeting in the main window (`library.open`) |
| Show Meetings Folder | the local root, or the chosen folder when reachable (checked off the main actor); unreachable, Settings on Storage |
| the recording warning's submenu | the issues, Show Meeting Folder…, Hide Warning |
| "Quit postponed…", Allow Quitting Without Confirmation | while `meeting.unconfirmedRecording` is set |
| the queue's status, Stop Transcription, Transcribe Meeting…, the last outcome | `MeetingTranscriptionQueue` |
| Allow Microphone Access… / Microphone Access — Open System Settings…; Auto-Paste — Request Access… / Open System Settings… | only while the permission is missing |
| Transcribe a File… | the main window on Files |
| "The update will be installed when you quit the app", Check for Updates… | `AppUpdater` |
| Settings… | `show("settings")` |
| Quit | `NSApp.terminate(nil)`, the ordinary quit |

A menu action that opens a window sets what the window should show first (`settings.settingsTab`,
`library.section`, `library.open`) and then calls `show`. The label is "M", red while the microphone
permission is missing, with a red dot while a meeting is recorded.

## Settings window

`SettingsTab` has six cases: `gettingStarted`, `dictation`, `meetings`, `storage`, `agents`, `permissions`. The
selected tab is `settings.settingsTab`, stored as `ui.settingsTab`; a stored value that is not one of the six
reads as `dictation` and is not rewritten. All six layers are built with the window in one `ZStack` and the
ones not selected are only hidden (`opacity`, `allowsHitTesting`, `accessibilityHidden`), so each tab's
`onAppear` runs once, as the window opens. What must happen on a switch watches `settings.settingsTab`;
`SettingsChrome.scrolling(trigger:content:)` flashes the scroll bar that way. The sidebar filters the tabs by
their title and translated search words. Its footer and the Dictation header read
`DictationCoordinator.readiness(...)`, the same answer as the menu.

The window's own `onAppear` calls `permissions.refresh()` and `loginItem.reconcile(desired:)`.

Getting Started is the same view as Permissions with `gettingStarted: true`. It numbers five cards as the
README numbers its steps: 1 Recognition model, 2 Permissions, 3 Try dictation, 4 automatic recording
(`MeetingsSettingsView(automaticOnly: true, step: 4)`), 5 Startup. Only the first can show as done, from
`ModelRow.isReady`, the same answer as the model row's dot; each permission shows its own mark. It opens by
itself once: `SettingsStore.prepareGettingStarted()` returns true while the `meeting.autoRecord` key does not
exist, and writes the key before the window opens. A test process writes nothing and never sees it.

## Recording indicator

`RecordingIndicator` owns one borderless `NSPanel` (`NonKeyPanel`: never key, never main) at the `.statusBar`
level, on every Space and over full-screen apps, built the first time something is shown. It can be dragged;
its content is `IndicatorView`, a dark pill with fixed colours whatever the app's look.

What is shown is `flash ?? base`:

- `setBase(_:)` sets the durable state of work under way and clears a flash, unless that flash is a conflict
  notice; `clearBase()` ends it without a word.
- `finish(with:)` ends the durable state and shows a terminal one; `showFlash(_:)` shows a terminal one over
  whatever is there. A flash hides itself after `IndicatorState.autoHide` (1.5 s to 6 s by state) and carries
  a generation, so a late expiry never removes a newer flash.

Dictation and meetings share the one base: the two modes exclude each other.

`IndicatorState.visualKind` sorts the states:

| Kind | States |
|---|---|
| `amberBars` | `loadingModel`, `waitingEngine` |
| `blueBars` | `finishingRecording`, `recognizing`, `savingMeeting` |
| `recording` | `recordingDictation`, `recordingMeeting` |
| `success` | `inserted`, `meetingSaved` |
| `failure` | `meetingSavedSuspect`, `meetingSavedPartially`, `clipboardFailed`, `injectionFailed`, `microphoneTimedOut`, `microphoneAccessUndetermined`, `microphoneAccessDenied`, `meetingMicrophoneAccessDenied`, `dictationFailure`, `meetingFailure` |
| `notice` | `noSpeech`, `clipboardFallback`, `busyWithDictation`, `busyWithMeeting`, `notice` |

With `overlay.enabled` off, `visibleState` passes only the `failure` kind and the two conflict flashes
(`busyWithDictation`, `busyWithMeeting`); progress, success and the other notices are hidden, `noSpeech` and
`clipboardFallback` among them. Callers that need a message to show regardless send it as a `failure` state:
the quit warning (`meetingFailure`), "Quit postponed" (`dictationFailure`), the stop at the dictation limit.

Position: with no stored placement the pill is centred from `NSScreen.main` by
`OverlayGeometry.defaultFrame`. A drag is saved 180 ms after the last move as `overlay.placement`
(`OverlayPlacement`: a display and fractions of its visible frame), and `OverlayGeometry.frame(for:...)` puts
the pill back there, falling back to the main display when that one is gone. Settings shows it as
`compactPositionText` and offers a reset.

## Appearance

Settings, Permissions, Appearance offers Match System, Light and Dark, stored as `ui.appearance`.
`AppDelegate.followAppearance(of:)` subscribes to `settings.$appearance` and sets `NSApp.appearance` (nil for
the system's) from the value sent. Windows, sheets, panels and the menu follow it; the indicator does not.
Reading the default writes nothing; choosing Match System after another look writes `system`.

## Log

`AppLog` writes each line twice: to `os.Logger` (subsystem: the bundle identifier, message public) and, on a
serial utility queue, to `~/Library/Logs/Murmurly/murmurly.log` as `<ISO 8601 time> [LEVEL] category:
message`. `rotateIfNeeded()` runs once at launch: a file over 5 MB becomes `murmurly.old.log`, replacing the
previous one, so one earlier generation is kept. Between launches the file is not limited. The file write is
asynchronous and quit does not wait for the queue. "Show Log in Finder" in Permissions selects the file.
Lines contain file names and paths; text that was said or dictated is not logged.

## Permissions

`PermissionManager` publishes `micStatus` (the raw TCC status), `micGranted`, `axTrusted` and
`accessibilityPromptAttempted`. `needsAttention` is `!micGranted` only.

- **Reading.** `refresh()` reads `AVCaptureDevice.authorizationStatus(for: .audio)` and
  `AccessibilityAuthorization.isTrusted` and assigns only what changed. It runs at `init`, on
  `NSApplication.didBecomeActiveNotification`, on the distributed notification `com.apple.accessibility.api`,
  when the Settings window appears, and every 3 s from a timer that runs only while a permission is missing.
  With both granted the timer stops, and a later change is picked up by the two notifications.
- **Microphone.** `requestMicrophone()` activates the app, awaits `AVCaptureDevice.requestAccess`, publishes a
  grant at once and reads the status again 500 ms later; a second call while one is pending returns the
  current answer. It is called from Settings' "Grant…" and from the menu's "Allow Microphone Access…", which
  first opens Settings and waits for it to be in front. A status of denied or restricted leads to System
  Settings instead. The dictation shortcut asks for nothing: without access it calls `refresh()` and shows
  `microphoneAccessUndetermined` or `microphoneAccessDenied`.
- **Accessibility.** `requestOrOpenAccessibility()` shows the system prompt the first time in a launch and
  opens the Privacy pane on later clicks. At launch `activate()` compares
  `permissions.accessibilityPromptedVersion` with `CFBundleVersion`: the same value does nothing; a different
  or missing one is replaced with the current version, and the prompt is shown only if a value was there
  before and trust is missing. So a first launch never prompts, and a new version prompts once. A test process
  skips this.
- **System audio.** There is no status to read. "Check…" runs `SystemAudioCapture.canCreateProcessTap()` off
  the main actor and stores a `SystemAudioCheck` (`permissions.systemAudioCheck`); the row's mark is neutral
  unless the check failed, the header's count of missing permissions leaves it out, and the button is off
  while a meeting is recorded.

Who reads trust: `PermissionManager.axTrusted` feeds the menu, the Settings rows and the gesture hints.
Delivery of a dictation, the password-field check and the call-window reader ask
`AccessibilityAuthorization.isTrusted` themselves at the moment of use.

## Login item

`settings.launchAtLogin` (`app.launchAtLogin`, on by default) is what the user wants; `LoginItemManager` keeps
`SMAppService.mainApp` in step with it. `isInstalledBundle` is true when the running bundle's path, links
resolved, is `/Applications/<name>` or `~/Applications/<name>`
(`defaultInstalledBundlePaths(appName:)`). Outside those, and in any test process, `reconcile` neither reads
nor changes the service and `serviceStatus` stays nil.

`reconcile(desired:)` is called by the launch task (`activate`), by every opening of the Settings window and
by the switch. It applies `reconciliationAction`:

| Wanted | Service status | Action |
|---|---|---|
| off | enabled, requires approval | unregister |
| off | not registered, not found | none (the stored path is forgotten) |
| on | not registered, not found | register |
| on | enabled or requires approval, last registered path is this bundle | none |
| on | enabled or requires approval, another or no stored path | unregister, then register |

The path of the bundle that registered is kept in `loginItem.lastRegisteredBundlePath`. `refreshStatus()`
only reads the status again and runs when the app becomes active, so the row shows what was decided in System
Settings. The switch shows the wanted value and the line under it the actual status, an error, or "Install
the app first" for a copy outside the install folders. Both Getting Started and Permissions show the same
group.

## Why it is this way

- **The label's task, not a window, starts the services**, because dictation and automatic recording have to
  work with all windows closed, and a launch at login opens none.
- **Settings is a plain `Window`**: the `Settings` scene raced with activation when opened from a menu-bar-only
  app.
- **The activation policy is switched by hand** so the app has a Dock icon and a place in the app switcher
  only while it has something to show there. Panels are left out of the count because the indicator is on
  screen for every dictation.
- **A manual meeting start makes the app regular and active** to keep it in front while Core Audio presents
  its one-time system-audio consent dialog.
- **No `runModal`**: nested modal run loops hung quit and the Files section; every panel is `begin` or a
  sheet.
- **No stored flag decides whether a window is shown.** A persisted "show the window" flag once produced an
  endless open and close loop. Getting Started keys off a setting that does not exist yet instead.
- **Getting Started ends with Startup next to automatic recording**: both are on from the first launch, and
  macOS announces the login item with its own "Login Item Added" notice, which should find its switch where
  the person is already looking.
- **Permissions are polled**: there is no reliable public notification for Accessibility trust, and none for
  the microphone. Assigning only changed values matters because `@Published` sends on every assignment and
  each poll would redraw the menu.
- **No prompt from the dictation shortcut**: an `.accessory` app does not present a consent prompt reliably,
  and the pending request would leave the shortcut's caller waiting.
- **A new version asks for Accessibility once**: a build signed without a Developer ID changes its code hash
  with every update, and macOS then no longer honours the earlier grant.
- **System audio has only a "Check…"**: macOS asks for that permission when an aggregate device with the tap
  first starts recording, so creating a tap proves nothing about it, and Settings never shows it as granted.
- **A copy outside the install folders never touches the login item**: it shares the bundle identifier with
  the installed copy and would re-point or remove that copy's registration.
