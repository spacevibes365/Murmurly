# The Files section and the app's panels

The Files section of the main window transcribes one audio or video file through the meeting pipeline and shows the
text, which can be copied or saved as Markdown. The same file also holds the one way the app's windows show an open
or save panel.

## Where things are

| Thing | Type | File |
|---|---|---|
| The section's state and actions | `FilesModel` | `Sources/ContentView.swift` |
| The section's view | `ContentView`, `FilesChoiceMenu` | `Sources/ContentView.swift` |
| A shown line | `TranscriptSegment` | `Sources/TranscriptionService.swift` |
| The pipeline on one file | `MeetingTranscriber.transcribeFile` | `Sources/MeetingRecorder/MeetingTranscription.swift` |
| Panels on a window | `FilesModel.present`, `PanelPurpose`, `panelBackend`, `WindowAnchor` | `Sources/ContentView.swift` |
| The folder panel without a window | `AppWindowController.chooseFolder`, `folderPanels` | `Sources/AppLifecycle.swift` |

## Ownership

`MurmurlyApp` creates one `FilesModel` with `FilesModel.live(settings:models:dictation:)` and hands it to the main
window as an environment object; the view reads everything from it and keeps only the drop highlight and its window
anchor. The section is a layer of the main window that is built with the window and hidden under other sections.
So a run goes on, and its text stays, with the window closed or another section shown. The state is in memory only:
quitting is what loses an unsaved result. The menu's "Transcribe a File…" only opens the main window on this
section.

`FilesModel.live` wires `MeetingTranscriber` the way a meeting job has it: `heldByDictation` and `heldByLiveTranscript`
from the dictation, and `returnDictationEngine` as `dictation.prepareAfterOtherEngineJob()`. See
`reference/engines.md` for the holds.

## State

| Property | Meaning |
|---|---|
| `fileURL` | the file chosen for the next run |
| `segments` | the shown result; a first segment with no speaker and no time is a note about gaps or a cut |
| `status` | the line at the bottom: the step, or how the run ended |
| `errorText` | a red line over the text, or alone when there is no text |
| `isTranscribing` | a run goes; from the start of its task until its result is shown |
| `choice` | engine and language of the next run; nil is "As Dictation" |
| `pendingReplacement` | the question "Replace the unsaved text?" waiting for an answer |
| `resultRevision`, `savedRevision`, `savedName` | every change of the result is a new revision; the saved one is the revision last written to a file |

`hasUnsavedText` is `!segments.isEmpty && savedRevision != resultRevision`. It decides the orange note under the
text, whether a new file or run asks first, and the quit loss. Copying does not change `savedRevision`.

## Choosing a file

Three ways lead to `select(_:)`: Choose File… or a click on the drop zone (`pickFile(owner:)`, an open panel for
audio and movie types), and a drop anywhere on the section (`handleDrop`). A drop takes any file URL that is not a
folder; a file the system cannot read as audio fails on the run and says so. All three are refused while a run goes.

A drop is answered later, by `NSItemProvider`. `selectionToken` grows with every drop, every open panel and every
started run, and a drop's answer is used only if the token is still its own: neither a stale drop's file nor its
error lands on a newer selection.

`select` over unsaved text sets `pendingReplacement` with `.file(url)`; otherwise the file is taken, and the shown
text, error and status are cleared. Choosing a file runs nothing.

## A run

1. `start()` takes `choice` at once: a change of the menu from here on is the next run's.
2. `readyTranscription(choice)` asks for the transcription. In the app this checks `ModelDownloader.missing` for the
   run's engine (its model, the tokenizer for Whisper, the VAD) and throws `FilesModel.ModelMissing`; the reason
   goes to `errorText` and nothing else changes.
3. Over unsaved text the run becomes `pendingReplacement` with `.rerun(choice)`. Otherwise it starts.
4. `run` bumps `selectionToken`, sets `isTranscribing`, clears the text and the error, shows "Starting…" and starts
   one task. Runs never overlap.
5. After the result is shown, and only for a run with a choice, `returnDictationEngine()` is called.

| What `transcribeFile` gave | Shown | Status |
|---|---|---|
| lines | the lines | "Done — N lines." |
| no lines | nothing | "Done — no speech detected." |
| lines, and the task was cancelled meanwhile | the lines | "Cancelled — the text so far is above" |
| `Failure.incompleteFile` (some chunks failed) | a note, then the lines | "Done with gaps — N lines. Pieces not recognized: K." |
| `Failure.fileCutShort` (broke off after at least one line) | a note, then the lines | "Stopped partway — N lines." |
| `CancellationError` | nothing | "Cancelled." |
| any other error | `errorText`, or "Cancelled." when the task was cancelled | empty |

A result with a note is a result like any other: unsaved until written, and saved with the note on top, so a gap or
a missing end is never taken for the whole file.

`transcribeFile` is the meeting pipeline on a single track with an empty speaker label: the same VAD, chunking,
engine cache, language rule and timecodes as a call, the personal dictionary under the Files switch, and no echo
cancelling. Its work chunks live in `Murmurly-file-<UUID>` in the temporary folder, removed when it returns;
nothing is written or removed next to the user's file. A break keeps what was recognized (`fileCutShort`, with the
position and the reason) unless the task was cancelled or nothing was recognized yet.

## Progress steps

`MeetingTranscriber.Step` is shared by a meeting job and a Files run, and the meeting menu and the Files section
name the same steps.

| Step | From | Files status |
|---|---|---|
| `.reading(track:)` | before the file is decoded | "Reading the audio…" |
| `.detecting(track:)` | before the VAD | "Looking for speech…" |
| `.waitingForEngine` | the hold wait before a chunk, or the cache's `.waiting` | "Waiting for the engine…" |
| `.preparingModel` | the cache's `.loading` | "Preparing the model — the first time takes a few minutes" |
| `.recognizing(track:done:total:)` | the cache's `.ready` | "Recognizing: D of T" |
| `.compressing`, `.moving`, `.removingAudio` | the meeting queue only | none |

The three per-chunk steps come from inside the cache operation. `MeetingTranscriber.recognize` gives the cache a
progress callback that feeds a local `AsyncStream`, shows each state before reading the next, and reads the stream
to its end before it takes the result. So "recognizing" appears only once the engine is at work on that chunk, and
no step arrives after the result. `.waitingForEngine` therefore stands for three waits: the dictation's hold, the
live transcript's hold, and one request ahead in the cache's queue.

`show(_:token:)` and `finish` act only for the active run's token (`runToken`, `activeRunToken`). `transcribeFile`
awaits every progress call and makes none after it returns, so in the app's wiring nothing arrives late; the token
guards a `FileTranscription` that would call progress late, which its type allows.

## Engine and language of a run

A row under the actions holds the choice. `FilesChoiceMenu` lists "As Dictation (engine · language)", then each
engine with Auto and its languages; every item sets engine and language together. "As Dictation" (nil, the state
after every launch) follows the settings chunk by chunk; a pick by hand holds for every chunk. The label tells the
two apart even when they would ask the engine the same. The choice stays across runs, files and the window until
"As Dictation" takes it back, and the menu is off while a run goes.

A line under the menu shows the model of the engine a run would take: a running download under its own engine's
name, or "not downloaded" with a button that downloads that engine's missing models, or nothing.

A run asked for over unsaved text carries its choice in `Replacement.Action.rerun`, through the question and the
save panel. `replace(with:)` asks `readyTranscription` again before the text is dropped: the model may have gone
meanwhile.

## Unsaved text, the question, saving

"Replace the unsaved text?" offers "Save .md…", "Replace" and "Cancel". A `Replacement` carries the revision the
user was asked about; `replace(with:)` does nothing when the result has changed since. "Save .md…"
(`saveThenReplace`) replaces only after the write succeeded: a cancelled panel or a failed write stops there. The
question is cleared when the view disappears, so it is not asked again when the window reopens.

A save takes text, name and revision together before the panel (`SaveRequest`). The name is the result's source file
with `.md`, not whatever is selected now. The write is `String.write(to:atomically:)`, made on the main actor.
`savedRevision` and
`savedName` are set only if the result is still the one the save was taken from, so a result that landed while the
panel was up stays unsaved. A failed save shows in `errorText`; a later save that works clears that message and no
other.

| Output | Format of a block; blocks are separated by an empty line |
|---|---|
| Copy | the time in square brackets, the speaker with a colon, the text, on one line |
| Save .md | a header line (the speaker in bold, the time in square brackets as code), an empty line, the text |

A file's lines have no speaker, and a note has neither speaker nor time.

## Cancelling

Only the Cancel button stops a run; closing the window does not. `cancel()` cancels the run's task and changes
nothing on screen by itself: the run ends at the pipeline's next check (after the file is read, before each chunk,
during a hold wait, in the cache's queue). A result that had already come back is kept. A run cancelled in progress
keeps none of its chunks.

## Quit and updates

`FilesModel.quitLosses` gives `.fileTranscription` while a run goes and `.unsavedFileText` while `hasUnsavedText`;
the menu bar label sets it as `AppDelegate.fileLosses`. `AppUpdater.busy` takes `files.$isTranscribing` (its `files:`
parameter is required) and not the unsaved text.

## Panels

**On a window.** Every open and save panel of the app's windows goes through
`FilesModel.present(_:on:as:)`, a static function that uses none of the model's state.

| Panel | Purpose (`PanelPurpose`) | Asked from |
|---|---|---|
| Choose File… | `.fileToTranscribe` | `FilesModel.pickFile` |
| Save .md | `.filesTranscript` | `FilesModel.askWhereToSave` |
| Dictionary Import… | `.dictionaryImport` | `DictionarySettingsView` |
| Dictionary Export… | `.dictionaryExport` | `DictionarySettingsView` |
| A meeting's Save As | `.meetingTranscript` | `MeetingLibrary` |

The view reads its window at the click, before anything waits, from a `WindowAnchor` put in its background
(`WindowAnchor.Reader`); a view inside a sheet answers with the window the sheet is on. `present` then:

1. returns nil, with a log line, if that window is nil or no longer visible: no panel goes on another window or on
   none;
2. hands the panel to the backend chosen by `panelBackend(arguments:testProcess:sheet:)`.

| Process | Backend |
|---|---|
| the app | `sheet`: `beginSheetModal(for:)` on the owner |
| a test process with the DEBUG file probe | the probe's answer for the panel's purpose |
| any other test process, the stage gate included | nil, no panel |

The purpose is what the probe answers by and what the log names. The probe itself is described in
`reference/test-isolation.md`.

**Without a window.** `AppWindowController.chooseFolder` shows the folder panel of Transcribe Meeting… and of
Settings → Storage. It needs no window, as the menu asks with none open: it runs after the menu has closed, makes
the app regular (`enterRegular`) so the panel is not behind other apps' windows, and shows the panel with `begin`.
It may carry an accessory view and a delegate that refuses a choice; the caller keeps both alive until the
completion. `folderPanels(testProcess:begin:)` is its form of the same rule: a test process gets a log line and no
panel.

No panel anywhere uses `runModal`.

## Why it is this way

- **State in the app, not the window.** A file can take minutes; closing the window must not stop it or drop a text
  that exists nowhere else.
- **No `runModal`.** A nested modal loop already hung the quit path and this section.
- **The window is read at the click.** A panel may come after something else, such as the replace question on its
  way out. By then the key window may be another one, or the question's own.
- **Unsaved text does not hold an update.** It never ends by itself and would hold the update until saved. The
  relaunch goes ahead and the user's quit route warns about the text instead.
- **The model's line is under the menu.** Beside the menu and the download button there was no room for it at the
  window's usual width.
- **Actions inside the section, not in a toolbar.** A window toolbar made the window taller on this section alone.
  No keyboard shortcuts: the hidden section would still answer them.
- **Steps from inside the cache operation.** Only the cache knows whether a chunk waits for the engine, loads the
  model or is being recognized, so "recognizing" on screen means the engine really is at work on that chunk.
- **Any file may be dropped.** `AVAudioFile` opens mp3, m4a, wav, mp4 and mov (checked on macOS 26), and a type
  list would refuse files the system can in fact read.
