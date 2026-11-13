# Architecture: layers, wiring, cross-cutting rules

How the app is put together above the level of a single feature. `CLAUDE.md` has the map of what lives where;
this file explains the layers, how the long-lived objects are wired, and who owns each rule that cuts across
features.

## Layers

Dependencies point down only. A type may use anything in its own layer's area or below; it must not name a type
from a layer above.

| Layer | What belongs there | Test |
|---|---|---|
| Core | On-disk formats and their readers: `Sources/Archive/`. No AppKit or SwiftUI: Foundation, `Darwin`, `CryptoKit`. | It compiles into the `murmurly` helper, which has none of the app. |
| Services | Things several features use and that know no feature: engines and their cache, model downloads, the speech pipeline (`MeetingTranscriber`), meeting storage, the audio codec, the dictionary replacer, `SettingsStore`, hotkeys, microphone and system audio capture, the dictation history store, the recording indicator, permissions, shared view parts. | Could another feature use it unchanged? |
| Features | Dictation, meeting recording (with the call window and live transcript), the transcription queue, the meeting library and main window, the notepad, Files, the Dictionary section. | It has user-visible behaviour of its own. |
| Shell | `MurmurlyApp`, `AppDelegate`, object construction, the menu, the Settings window, updates, DEBUG probes. | It knows every feature and nothing knows it. |

Only the Core boundary is enforced by the compiler today. The rest is a convention: one module, every type
visible to every other. Known references that point up are listed at the end; do not add new ones.

Features may use each other where the product needs it (the notepad shows the recorder's live transcript and
writes notes through the library). A feature never reaches another feature's private state: it goes through that
feature's published properties or a closure handed over at construction.

## Construction and wiring

Objects are created in `MurmurlyApp.init` and activated from the `.task` of `MenuBarLabel`, on the label's first
render: dictation and the meeting watchdog must live with every window closed. Everything that can create work
starts from that task, after the links below are set.

Links set after construction, and why each one is late:

| Link | Why late |
|---|---|
| `DictationCoordinator.meetingPeer` and `MeetingRecorder`'s weak `dictation` | A real cycle: each refuses to start while the other holds the microphone. |
| `MeetingRecorder.transcripts` (its `didSet` hands the queue the recorder's facts) | A real cycle: the recorder queues a finished meeting, the queue must never touch the folder being recorded. |
| `MeetingTranscriptionQueue.marksBeingWritten` | A real cycle: a move waits for a marks write, a marks write is refused during a move. |
| `AppDelegate.attach`, `fileLosses`, `meetingLosses` | SwiftUI creates the delegate; the app's objects reach it from the label's task. |
| `AppDelegate.showMainWindow`, `MeetingLibrary.showMainWindow` | `openWindow` exists only inside a view. |
| `settings` and `permissions` on `DictationCoordinator` and `MeetingRecorder` | Passed in `activate`, so tests can build either without them. |
| `MeetingTranscriptionQueue.releaseAudio`, `audioOpening`; `MeetingPlayer.startRefusal` | Set by `MeetingLibrary` in its initializer: the library owns the player and is created after the queue. |
| `MeetingTranscriptionQueue.audioRetention`, `writeAudioRetention` | Set in `MurmurlyApp.init` right after the queue is created; they read and write the settings. |
| `MeetingRecorder.notepadLinks` | The notepad panel is created before the library, so the library reaches it through the recorder. |
| `NotepadModel.noteServices` | Set by `NotepadNotes.attach`, which ties the notepad to the recorder and the library. |

Until a link is set its default answers as if the other side were idle. New links must not rely on that: prefer a
constructor parameter, and when a link has to be late, make its absence visible (an optional that is checked, not
a closure that returns a harmless value).

## Cross-cutting rules and their owners

Each rule has one definition. A new feature joins it there, not by adding a parallel check.

| Rule | Defined in | A new feature must |
|---|---|---|
| What a quit would lose, and whether quit waits | `AppDelegate.applicationShouldTerminate`, `AppDelegate.QuitLoss`, `quitLosses()`; `hasUnfinishedWork` on `DictationCoordinator` and `MeetingRecorder` | Report its unfinished work to the delegate. See `reference/quit-and-update.md`. |
| Whether an update may relaunch now | `AppUpdater.busy(meeting:dictation:transcripts:files:library:)` | Add its publisher there; the parameters are required so none is forgotten. |
| One microphone | `DictationCoordinator` and `MeetingRecorder` refuse while the other is busy | Never open the microphone outside these two. |
| Playback during recording | `MeetingLibrary` holds `MeetingPlayer` while a recording or dictation runs (`startRefusal`, `held`) | Ask before starting any sound. |
| One loaded engine | `WhisperKitCache` holds one engine; a job in another engine waits while `DictationCoordinator.heldEngine` or `MeetingRecorder.liveTranscriptEngine` names a different one | Wait before each request, and be cancellable while waiting. |
| A meeting folder being worked on | `MeetingTranscriptionQueue.operations`, `reserve`, `operation(on:)` | Check before writing into a meeting folder; identify the folder by `FolderIdentity`, never by path alone. |
| Test processes touch no real service | `TestIsolation` | See `reference/test-isolation.md`. |

Rules are computed from their owners' state, never registered: a stored "work in progress" flag that is not
cleared would block quit or dictation for good.

## Seams

- A dependency on hardware, an engine or the disk is a protocol (`MicCapturing`, `MeetingCaptureBackend`,
  `WhisperEngine`, `ParakeetEngine`, `MeetingTrack`, `AccessibilityPageNode`) or a struct of closures with a
  `.live` value (`MeetingLibrary.Reader`, `MeetingLibrary.Saving`, `MeetingPlayer.Deck`, `MeetingStorage.Removal`).
- A seam is a constructor parameter with the live value as its default, so the function body is the same in Debug
  and Release. A `#if DEBUG` branch inside a production function means its Release path runs in no automated test;
  do not add new ones.
- Work takes a `SettingsSnapshot` when it starts. Only views and construction hold the live `SettingsStore`.
- Disk work on a folder that may be a network volume runs on a serial queue for that folder, never on the main
  actor and never on the cooperative pool.

## The large types

| Type | Shape | Guidance |
|---|---|---|
| `MeetingLibrary` | The window's read model plus marks writer, deletion, export, search and player coordination, tied by one serial queue per folder (`Channel`). | Do not add a responsibility to it. New behaviour comes as its own type with a `Reader`-style seam. |
| `DictationCoordinator` | One state machine: capture, Esc, pipeline, quit. Quit claims the pipeline, a paste and Recognize Again in one synchronous step. | Keep that step in one type. |
| `MeetingTranscriptionQueue` | One runner for transcription, copy, compression, moves and old-audio removal, plus the folder operations. | Facts it needs from the recorder and the player arrive as closures; treat them as required. |

## References that point up today

They exist; they are not a pattern to copy.

| From | To | Where |
|---|---|---|
| `SettingsStore` (service) | `MeetingTranscriptionQueue.Destinations`, `LiveTranscriptPanelFrame`, `SettingsTab` | `Sources/SettingsStore.swift` |
| `AXPageNode` in `AccessibilityAuthorization.swift` (service) | `AccessibilityPageNode` | `Sources/Permissions/AccessibilityAuthorization.swift` |
| `SystemAudioCapture` (service) | `MeetingCaptureBackend`, declared beside the recorder | `Sources/MeetingRecorder/SystemAudioCapture.swift` |
| `FilesModel`, `MeetingLibrary` (features) | `AppDelegate.QuitLoss` | `Sources/ContentView.swift`, `Sources/MeetingRecorder/MeetingLibrary.swift` |
| `MeetingRecorder`, `MeetingTranscriptionQueue` (features) | `AppWindowController` | `Sources/MeetingRecorder/MeetingRecorder.swift`, `Sources/MeetingRecorder/MeetingTranscription.swift` |
| `MeetingLibrary` (feature) | `MeetingsSettingsView.applicationName` | `Sources/MeetingRecorder/MeetingLibrary.swift` |
| `FilesModel`, `DictionarySettingsView` (features) | `FileProbe` | `Sources/ContentView.swift`, `Sources/Settings/DictionarySettingsView.swift` |

Shared code that lives under a feature's name: the lossless audio encoder is an extension of
`DictationHistoryStore` and also compresses meetings; app-wide open and save panels are static functions of
`FilesModel`; `HotkeyManager` in `Sources/Dictation/` also serves the meeting shortcut and the notepad.
