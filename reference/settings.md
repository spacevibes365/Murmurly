# Settings

Where every preference lives, who writes it, and who reads it at which moment. This document cuts across the
features: a setting is listed once, with all of its readers. Rules: `.claude/rules/settings.md`.

Code: `Sources/SettingsStore.swift` (`SettingsStore`, `SettingsSnapshot`), `Sources/Settings/`
(`SettingsWindow`, the tab views, `ArchiveSnapshot` in `StorageSettingsView.swift`).

## The store

`SettingsStore` is one `@MainActor ObservableObject`, built first in `MurmurlyApp.init`. Each preference is a
`@Published` property whose `didSet` writes one `UserDefaults` key. The defaults object is
`TestIsolation.settingsDefaults()`: the app's own domain, or an isolated test process's own file.

- **Reading.** `init` reads every key and writes none (property observers do not run in an initializer). A
  missing key gives the default in the table. A value of another kind, or a raw value no case has, gives the
  default too and the key stays as stored; the exceptions are named in the table.
- **Writing.** Assigning a property writes its key at once. Optional values (`overlay.placement`, the two
  folder paths, the panel frame, the system-audio check) remove the key when set to nil.
- **Publishing.** `@Published` sends the new value before the property changes. Every subscriber in the app
  applies the value it is sent; `MeetingLibrary` only schedules a read for the next turn of the main queue.

Three counters are in memory only:

| Counter | Bumped by | Used for |
|---|---|---|
| `retentionGeneration` | every write of `meetingAudioRetention` and of `meetingsFolderPath`, the same value included | the queue reads `(days, generation)` together; a deletion of old audio asked for under another generation is not carried out |
| `meetingsFolderAttempt` | every `chooseMeetingsFolder` and every write of `meetingsFolderPath` | a choice checked off the main actor is applied only while it is still the latest (`.superseded` otherwise) |
| `transcriptsFolderAttempt` | the same for the transcripts folder | the same |

## Snapshots

Work does not hold the store. It takes a value when it starts:

- `SettingsStore.snapshot` → `SettingsSnapshot`: `dictationLanguage`, `dictationEngine`, `saveDictationAudio`,
  `autoPaste`, and the two model paths, which are constants (`SettingsStore.modelPath(for:)`; models live in
  one folder and there is nothing to choose). It is `Sendable` and has no reference back.
- `SettingsStore.dictionarySnapshot` → `DictionarySnapshot`: the entries, the three "applies to" switches, and
  whether word forms match for the engine and language of that moment.
- `SettingsSnapshot.applying(_:)` lays a job's own `Choice` (an engine and a language; a code the engine does
  not know is kept as `auto`) over a snapshot. It is the only overlay; a choice is never written to the store.
- `SettingsSnapshot.dictationDescriptor` is the `EngineDescriptor` for the snapshot's engine.

In the table below, **snapshot** means read through one of these at the named moment, **live** means read from
the store at the moment of use, and **subscribed** means a Combine sink that applies each value sent.

## Keys written by the store

### Dictation

| Key | Type, default | Written by | Read by |
|---|---|---|---|
| `dictation.language` | String, `auto`. Any string is kept as stored; a code the selected engine does not know acts as Auto at use (`pickedLanguage` shows Auto and never rewrites the key) | the language pickers in the menu and Settings | **snapshot** at the start of each dictation (`recordingSnapshot`) and of Recognize Again; **snapshot** once per recording for the live transcript; a meeting or file job without a choice of its own reads it **live** before every chunk, and once at its start for the dictionary's word forms |
| `dictation.engine` | String, `parakeet`; unknown → `parakeet` | the engine pickers in the menu and Settings | **subscribed** by `DictationCoordinator` (warms the newly selected engine); **live** in the model check before recording, in Recognize Again, in the warm-up after another engine's job, in `heldEngine` for 30 s after a dictation; **snapshot** with the language everywhere else in that row; a job without a choice checks its model once at its start and reads the engine live per chunk |
| `dictation.saveAudio` | Bool, false | Settings, Dictation | **snapshot** of the dictation |
| `dictation.autoPaste` | Bool, true | Settings, Dictation | **snapshot** of the dictation; ⌃⌘V and ⌃⌘C ignore it |
| `dictation.hotkey.activation` | String, `press`; unknown → `press` | Settings, Dictation | **subscribed** by `HotkeyManager`; live in the menu's and footer's gesture hint |
| `dictation.hotkey.doubleModifier` | String, `rightCommand` | Settings, Dictation | the same subscription and hints |
| `dictation.hotkey.doubleThresholdMS` | Int, 250, clamped to 150…500 on read and on write | the stepper in Settings | the same subscription |
| `dictation.sound.start`, `dictation.sound.inserted` | Bool, true each | one switch, `soundsEnabled`, which sets both and reads as on while either is | **live** at the moment of each sound; the meeting's start beep reads `soundsEnabled` |
| `overlay.enabled` | Bool, true | Settings, Dictation | `RecordingIndicator`: the value at `init`, then **subscribed** |
| `overlay.placement` | Data (JSON `OverlayPlacement`), none; undecodable → none | a drag of the indicator, "Reset to Default" | the same |

### Meetings

| Key | Type, default | Written by | Read by |
|---|---|---|---|
| `meeting.autoRecord` | Bool, true. The key's absence is what shows Getting Started | Settings, the menu; `prepareGettingStarted()` writes the default at the first launch, before the window opens | **subscribed** by `MeetingRecorder` → `MeetingWatchdog.updateSettings` |
| `meeting.excludedBundleIDs` | [String], empty | the menu's Exclude item, Settings (remove) | the same subscription |
| `meeting.afterStop` | String, `transcribe`; unknown → `transcribe` | Settings, Meetings | **live** when a stopped recording is offered to the queue, so it follows a change made during the recording; **live** in the quit warning |
| `meeting.namesFromCallWindow` | Bool, true | Settings, Meetings | **live** once as a recording starts (builds `CallFeedWatcher` or not) and on every step of the watcher; off stops the watcher for the rest of that recording, on again does not build one |
| `meeting.liveTranscript` | Bool, true | Settings, Meetings | the recorder reads it **live** once, as a recording enters `.recording`, to build a `LiveTranscriptModel` or not; `LiveTranscriptPanel` is **subscribed** and shows or hides the notepad at once |
| `liveTranscript.panelFrame` | Data (JSON), none | the notepad, 180 ms after a move or resize | **live** when the notepad is shown |
| `liveTranscript.keepOnTop` | Bool, false | the notepad's pin | **subscribed** by `LiveTranscriptPanel` |
| `meeting.storageFolder` | String, none (finished meetings stay in the local root). Read as stored | `chooseMeetingsFolder` after its checks; "Reset to Default" | the queue, through `settings.meetingDestinations`, **live** at each scan and each move; the recorder and the menu, to locate a moved meeting; `MeetingLibrary`, **subscribed** as a nudge to read again; Storage; the helper process, on every call (an empty string reads there as no folder) |
| `meeting.transcriptCopyFolder` | String, none (no copy). Read as stored | `chooseTranscriptsFolder`; "Don’t Copy" | the queue, **live** at the moment of the copy; the quit warning; the deletion of a meeting, which resolves it again; Storage |
| `meeting.audioRetentionDays` | Int, 0 (keep); a value other than 0, 7, 30, 90 → keep. Read with `integer(forKey:)`, which also takes a numeric string | the queue's `writeAudioRetention`, after the question was answered yes; keep is written at once | the queue, **live** with `retentionGeneration` before every deletion; the meeting card's note; Settings |

### Dictionary, agents, interface

| Key | Type, default | Written by | Read by |
|---|---|---|---|
| `dictionary.entries` | Data, one versioned JSON document; absent → empty. A document that does not read is kept as it is (`dictionaryUnreadable`) | `saveDictionary(_:)`, the import, `clearDictionary()` | **snapshot** (`dictionarySnapshot`) at the start of a dictation, a meeting or file job, and a recording's live transcript |
| `dictionary.inDictation`, `.inMeetings`, `.inFiles` | Bool, true each | the Dictionary section | the same snapshot |
| `agents.meetings`, `agents.dictations` | Bool, false. The app reads `as? Bool`; the helper accepts only a real boolean | Settings, Agents | the helper process, at the start and the end of every call |
| `agents.periodDays` | Int, 0 (all history). A stored value that is not a non-negative whole number reads as −1 in the app and is refused by the helper (`HelperContract.periodDays(fromStored:)`, one rule for both) | Settings, Agents | the helper process |
| `app.launchAtLogin` | Bool, true | the Open at login switch, which also calls `reconcile` | **live** by `LoginItemManager.reconcile` at launch and at every opening of Settings |
| `ui.settingsTab` | String, `dictation`; unknown, or a tab that no longer exists → `dictation`, not rewritten | the sidebar; the menu, before it opens Settings; the Getting Started closure | **live** by `SettingsWindow` |
| `ui.appearance` | String, `system`; unknown → `system` | Settings, Permissions; choosing Match System writes `system` | **subscribed** by `AppDelegate.followAppearance(of:)` |
| `permissions.systemAudioCheck` | Data (JSON `SystemAudioCheck`), none | the "Check…" button | **live** by the Permissions row and the tab's dot |

## Keys written elsewhere

These live in the same defaults object (`TestIsolation.settingsDefaults()`), written by their owners, not by
the store:

| Key | Owner | Meaning |
|---|---|---|
| `permissions.accessibilityPromptedVersion` | `PermissionManager` | the `CFBundleVersion` that last ran the launch-time Accessibility check |
| `loginItem.lastRegisteredBundlePath` | `LoginItemManager` | the bundle path that registered the login item |
| `agents.claudeCode.helperPath`, `agents.codex.helperPath` | `AgentConnections` | the helper path that passed the last Connect |

And two libraries keep their own keys in `UserDefaults.standard`, whatever defaults object the store has:

| Keys | Owner | Notes |
|---|---|---|
| the shortcuts `dictate`, `meeting`, `pasteLastDictation`, `copyLastDictation`, `markMoment` | KeyboardShortcuts | The library writes a name's initial shortcut the first time the name is touched; an isolated test process declares none. The store only reads descriptions (`dictationShortcutDescription` and its like), and a view that records a shortcut calls `settings.objectWillChange.send()` so the hints redraw |
| Sparkle's own (`SU…`), the automatic-check choice among them | Sparkle | `AppUpdater.automaticallyChecksForUpdates` passes through to it |

## One setting, several moments

Where readers of one setting take it at different moments, a change made while work is under way reaches
them at different times:

| Setting | What a change during the work does |
|---|---|
| engine and language, during a dictation | nothing: the dictation keeps its snapshot; the next one uses the new values |
| engine and language, during a meeting or file job without a choice of its own | the next chunk is recognized with the new values; the model check and the dictionary's word-form rule stay as they were at the job's start |
| engine and language, during a job with its own choice | nothing: the choice is laid over every read |
| dictionary entries and switches | nothing until the next job |
| `meeting.liveTranscript`, during a recording | the notepad hides or shows at once; whether the recording has live text was decided as it began |
| `meeting.namesFromCallWindow`, during a recording | off stops the reading for that recording; on has no effect until the next one |
| `meeting.afterStop`, during a recording | applies to that recording: it is read at the stop |
| `meeting.storageFolder`, during a move | the move under way finishes into the folder it started with; the next step reads the new one |
| `meeting.audioRetentionDays` or the meetings folder, during the audio pass | deletions admitted under the earlier generation are not carried out |

## The two folders

`chooseMeetingsFolder(_:)` and `chooseTranscriptsFolder(_:)` are the only way a picked folder becomes a
setting. Both resolve links off the main actor (`resolvedPath`, a detached task) and answer a `FolderChoice`:

| Answer | Meaning |
|---|---|
| `.applied` | the path is stored as the panel gave it |
| `.insideLocalRoot` | meetings folder only: the pick is the local recording root or inside it |
| `.insideDictationArchive` | the pick is the dictation archive or inside it |
| `.superseded` | another choice or a reset came while this one was checked; nothing changes |

Storage shows the two refusals as a warning line. These checks run at the choice. At launch the stored path is
read as it is, and its readers take it as it is.

## Storage

Settings, Storage shows `ArchiveSnapshot`, held as `@State` in `SettingsWindow` with `archiveFailure` and
`archiveRetry`. `refreshArchiveSnapshot()` runs as a `.task(id:)` whose identity is the dictation history's
revision, `finishedJobs` of the queue, the two folder paths and `archiveRetry`; a new identity cancels the
task under way.

1. `DictationHistoryStore.shared.historySummary()`. If it throws, `archiveFailure` is set and the count stops
   there: the last figures stay with "Figures from the last successful count" and "Try Again".
2. `ArchiveSnapshot.refresh(...)` counts this Mac off the main actor (`ArchiveSnapshot.local`: the dictation
   archive's own files, the meetings in the local root, their audio) and publishes.
3. If a folder is chosen, it then reads the chosen folders in a second detached task
   (`loadMeetingsFolder`, `MeetingStorage.isAvailable` for the transcripts folder) and publishes again.

Each publication first checks `Task.isCancelled`, so a late answer from a folder no longer chosen overwrites
nothing. Until a folder answers, its previous figures are carried over, and the view shows them only when
their path is the chosen one (`checkedMeetingsFolder`, and the same comparison for the transcripts folder), so
another folder never borrows them. "Show in Finder" is enabled only for a folder the last check found, and
selects exactly that folder.

`recheckChosenFolders()` bumps `archiveRetry`, which runs the whole count again, when the app becomes active
and when a volume is mounted or unmounted, if a folder is chosen. "Try Again" and "Move Now" bump it too;
"Move Now" also calls `scanLocalFolders()`.

What is counted: a meeting is `MeetingStorage.meetingFolders`, the same definition as the main window's.
`meetingBytes` is `MeetingStorage.folderSize` of the whole root, every file in it. `MeetingAudio` sums
`MeetingStorage.audio(in:)` per meeting and counts the meetings with none left or that cannot be told. A root
that cannot be listed counts as no meetings here. `waiting` is the number of finished meetings still in the
local root.

## Why it is this way

- **No stored flag decides whether a window is shown.** A persisted "show the window" flag once caused an
  endless open and close loop. Getting Started is shown while the automatic-recording key does not exist, and
  that key is written before the window opens, so the condition cannot be true twice.
- **Reading writes nothing** because the stage gate, and any test process of a Release build, run on the app's
  own, live domain (a Debug unit-test host gets an isolated suite): a seeded default there would stay in the
  user's preferences.
- **Parakeet is the default engine**: a third of Whisper's download, and Whisper is needed only for languages
  beyond Parakeet's 25.
- **Transcribe is the default after a stop**: a call recorded on its own is easily forgotten, and a transcript
  nobody asked for costs only a file.
- **Work takes snapshots** so a change in Settings cannot land in the middle of a dictation, and so background
  work never touches a main-actor object.
- **A language is kept as stored even when the engine does not know it**, so switching the engine and back
  brings the choice back.
- **The meetings folder may not be the local root or inside it**: moving meetings there would only shuffle
  them around this Mac, and a move into the root itself would remove them. Neither folder may be in the
  dictation archive, which is the archive's own to manage.
- **Links are resolved and folders counted off the main actor**: a chosen folder may be on a network volume,
  and a dead one hangs whatever touches it.
- **The count runs in two steps** so a slow or dead network volume never holds back this Mac's figures.
- **The audio rule is written only after a question**: a number of days deletes audio for good, so the user
  first sees what would go at once.
- **Shortcuts are outside the store** because KeyboardShortcuts reads and writes only `UserDefaults.standard`.
