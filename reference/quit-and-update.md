# Quit and updates

What happens to work under way when the app is asked to quit, and when Sparkle wants to relaunch it. This
document cuts across the features: every kind of work is listed with what quit does to it and whether it holds
an update. Rules: `.claude/rules/quit-update.md`.

Code: `Sources/AppLifecycle.swift` (`AppDelegate`), `Sources/AppUpdater.swift`, the "Quit" sections of
`Sources/Dictation/DictationCoordinator.swift` and `Sources/MeetingRecorder/MeetingRecorder.swift`,
`FilesModel.quitLosses` in `Sources/ContentView.swift`, `MeetingLibrary.quitLosses` in
`Sources/MeetingRecorder/MeetingLibrary.swift`.

## Routes

Every way out reaches `AppDelegate.applicationShouldTerminate`: the menu's Quit item and ⌘Q, the Dock, logout,
restart and shutdown, Sparkle's quit, and SIGTERM. For SIGTERM the default action is replaced at launch
(`SIG_IGN` plus a `DispatchSource` on the main queue) by a handler that sets `signalled` and calls
`NSApp.terminate`.

`AppDelegate.route(quitReason:signalled:)` sorts a request into one of three routes:

| Route | When | Difference |
|---|---|---|
| `.signal` | `signalled` was set by the SIGTERM handler | no warning; the loss is logged |
| `.system` | the quit Apple event carries `kAEQuitReason` of logout, restart or shutdown | no warning; the loss is logged |
| `.user` | anything else, Sparkle's quit included (it carries no reason) | a loss is warned about first |

## The answer, step by step

`applicationShouldTerminate` answers in this order:

1. `signalled` is read and cleared.
2. `terminationConfirmed` is set: this is the app's own second phase, so `.terminateNow`.
3. `finishingRecordings` is set: a first phase is running, so `.terminateCancel`.
4. `quitLosses()` is worked out. If it is not empty and the route is `.user` and this is not a confirmed
   repeat, the warning is shown (`dictation.showQuitWarning`, a failure-style banner that shows with the
   indicator off) and the answer is `.terminateCancel`. On the other routes, and on a confirmed repeat, the
   losses are logged and the request goes on.
5. If neither `dictation.hasUnfinishedWork` nor `meeting.hasUnfinishedWork` is true:
   `dictation.prepareForImmediateQuit()` and `.terminateNow`.
6. Otherwise the two-phase quit begins and the answer is `.terminateCancel`.

A confirmed repeat (`isConfirmedRepeat`) is a quit within `repeatWindow`, 10 s, of the last warning, whose
losses are all among those the warning named. A new kind of loss inside the 10 s warns again; the same kind
gained by other work in that time does not.

## Two phases

When there is unfinished work, the first request is cancelled and the work is finished in the normal event
loop:

1. `finishingRecordings = true`; `dictation.beginTermination()` and `meeting.beginTermination()` are both
   called at once, so neither can start anything new while the other finishes. Each returns a
   `Task<Bool, Never>`: true means everything it had is confirmed saved.
2. `outcome(of:deadline:)` waits for both results or for `terminationDeadline`, 20 s, whichever comes first.
   The deadline is a task of its own and the work is not joined: `SingleAnswer` takes the first answer.
3. Saved: `terminationConfirmed = true`, then `finishTermination(true)` calls `NSApp.terminate(nil)` again,
   which gets `.terminateNow` at step 2 above.
4. Not saved, or the deadline came first: `cancelTermination()` on both, `showTerminationDeferred()` ("Quit
   postponed: saving not confirmed"), and the app keeps running.

A first phase cancels whatever asked for the quit: a logout, restart or shutdown that arrives while
`hasUnfinishedWork` is true is cancelled by it, and the app then quits by itself, outside that logout.

`beginTermination()` sets `isTerminating`, which closes every new start (a dictation, a meeting, ⌃⌘V,
Recognize Again). `cancelTermination()` opens them again only when no termination task is still running; one
that is (a stop that outlived the deadline) reopens them when it ends, and until then `hasUnfinishedWork`
stays true, so each further quit joins the same task and waits for the deadline again.

### What the dictation coordinator does

`beginTermination()` closes the Esc listener and calls `claimForTermination()` in the same main-actor turn:

- a Recognize Again run is marked `claimed`; if its save has not begun its task is cancelled and its late
  result writes nothing; a save already begun is handed back to be waited for;
- a ⌃⌘V not delivered yet is dropped (`dropUndeliveredPaste`); one already delivering is handed back to be
  waited for.

`finishForTermination` then, by `state`: `.starting` invalidates the start attempt and awaits the start task;
`.recording` calls `beginStop()`. `finishJobForTermination` takes the job from the pipeline (`claimed`): in
`.stopping` or `.recognizing` it cancels recognition without waiting for the model and saves the raw CAF as a
history line marked `recognition_skipped`; in `.saving` it awaits that save; in `.delivering` it settles the
save's result. The pipeline that comes back late no longer owns the job, so it neither saves a duplicate nor
pastes nor deletes the source. Saves left in `pendingSaves` by an earlier quit are retried once. The
Recognize Again save and the delivering paste are awaited last. The result is `pendingSaves.isEmpty`.

A save that fails here stays in `pendingSaves` with its source file kept, shows in the menu's Unsaved
Dictations marked "quit postponed", and makes `hasUnfinishedWork` true until it succeeds at a later quit or
the user chooses Remove.

`prepareForImmediateQuit()`, on the `.terminateNow` path, sets `isTerminating` and drops a ⌃⌘V not delivered
yet. It does nothing about Recognize Again: that path is reached only when no unclaimed run exists.

### What the meeting recorder does

`finishForTermination`: `.recording` calls `beginStop()`; `.starting` cancels the start task; then the
operation under way is awaited. The stop finishes the live transcript, closes the call-window file
(`watcher.finish()`), then `capture.stop()` writes the tracks and `metadata.json`. The result is true only
with proof: a clean stop, or a failed one whose folder holds a readable `metadata.json` in a final state.
Otherwise `unconfirmedRecording` is set with the reason, the menu shows it with "Allow Quitting Without
Confirmation", and it makes `hasUnfinishedWork` true at every later quit until the proof appears or the user
releases it. There is one such slot; a stop made by a later quit writes its own result into it.

A recording stopped by quit is not offered to the queue (`offerToQueue` returns while `isTerminating`): it is
saved, and the launch scan queues it for compression and the move, without a transcription.

## Warnings

`quitLosses()` is the union of four sources:

| `QuitLoss` | True when | Read from |
|---|---|---|
| `meetingTranscription` | `isTranscribing`, or a `pending` job with `transcribe` | `meeting.transcripts` (the queue) |
| `transcriptCopy` | `activeJob.transcribe`, not `isTranscribing`, `step == nil`, and a transcripts folder is set | the queue and `settings.transcriptsFolderPath` |
| `recordingToTranscribe` | `meeting.isBusy` and `settings.meetingAfterStop == .transcribe` | the recorder, the settings |
| `recognizeAgain` | a Recognize Again run not claimed and with no save begun (`recognizeAgainWouldBeLost`) | the dictation coordinator |
| `fileTranscription` | `FilesModel.isTranscribing` | `fileLosses` → `FilesModel.quitLosses` |
| `unsavedFileText` | `FilesModel.hasUnsavedText` | the same |
| `unsavedMeetingMark` | `pendingMarks` or `noteFailures` is not empty | `meetingLosses` → `MeetingLibrary.quitLosses` |
| `transcriptFile` | `exporting?.writing == true` | the same |

The `transcriptCopy` condition names the state of the queue's fields, not the copy itself: it also holds from
the moment a transcribing job is taken until its transcription starts, and after the copy until the job shows
its next step.

One loss is named with its own sentence (`warning`); several are listed (`listName`) in "Quitting now loses:
… — quit again to quit anyway".

## Updates

`AppUpdater` wraps Sparkle 2.10.0's standard updater: its window with the release notes, "Install and
Relaunch", a check once a day, the menu's "Check for Updates…" and the Updates group in Settings, Permissions.

| `state` | Meaning |
|---|---|
| `testCopy` | a test process: no controller is created |
| `noKey` | `SUPublicEDKey` is empty in this build: no controller is created |
| `failed(reason)` | `SPUUpdater.start()` threw; the reason is shown in Settings and logged |
| `running` | started |

The controller is created with `startingUpdater: false` and `AppUpdater` starts the updater itself. Whether
checks run is Sparkle's own setting, exposed as `automaticallyChecksForUpdates`; the app stores no flag of its
own. `Murmurly-Info.plist` sets `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` (86400),
`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`; `SUFeedURL` and `SUPublicEDKey` come from
`MURMURLY_SU_FEED_URL` and `MURMURLY_SU_PUBLIC_KEY` in `Signing.xcconfig`, which also holds
`MURMURLY_SU_DOWNLOAD_BASE`. A fork points the three at its own releases, or empties the key in a local
xcconfig to keep updates off.

### Busy

`AppUpdater.busy(meeting:dictation:transcripts:files:library:)` is a publisher combined from the objects'
`@Published` streams; `AppUpdater` keeps its latest value in `isBusy`. It is true while any of these is:

| Input | Stream |
|---|---|
| a meeting starting, recording or stopping | `meeting.$state` (`isBusy`) |
| a dictation in any state but idle | `dictation.$state` |
| Recognize Again, until its save ends | `dictation.$recognizingAgainID` |
| ⌃⌘V from key-up until its clipboard is restored | `dictation.$isPastingLast` |
| the queue's current job, if it transcribes, until the job ends | `transcripts.$activeJob` |
| a transcription waiting in the queue | `transcripts.$pending` |
| a Files run | `files.$isTranscribing` |
| a meeting's marks not on disk yet | `library.$pendingMarks` |
| a transcript being written to its file | `library.$exporting` (`writing`) |

Every parameter is required, so a call site cannot leave one out.

### Install and Relaunch

Sparkle asks `updaterShouldRelaunchApplication` on every attempt; the answer is `relaunchNow()`:

- Busy: false. `installsAtQuit` is set, and Sparkle closes its window and keeps the prepared update, which
  installs when the app next quits. The menu and Settings then say "The update will be installed when you
  quit the app". "Check for Updates…" and the daily check offer "Install and Relaunch" or "Install on Quit"
  again.
- Not busy: true. `updaterWillRelaunchApplication` sets `installsAtQuit`, and Sparkle asks the app to quit.
  That quit is on the `.user` route. If it goes through, the update installs and the app relaunches. If it is
  cancelled, by a warning or by a refused two-phase quit, the update waits for the next quit and the line
  above is already showing.

`updater(_:userDidMake:forUpdate:state:)` keeps `installsAtQuit` true for "Install on Quit" (a dismissal at
the installing stage) and clears it otherwise. When Sparkle's session ends,
`standardUserDriverWillFinishUpdateSession` calls `AppWindowController.windowDidClose()`, since Sparkle's
windows are not the app's and their closing does not otherwise return the app to `.accessory`.

What passes `busy` and then stops Sparkle's quit:

| State | What stops the quit |
|---|---|
| unsaved Files text | the `unsavedFileText` warning |
| a note whose write was refused or failed (`noteFailures`) | the `unsavedMeetingMark` warning |
| `pendingSaves`, `unconfirmedRecording` | the two-phase quit, refused while they are not confirmed |

In each case a second quit within 10 s of a warning goes ahead, and the update installs at that quit.

### Release side

`scripts/release.sh` runs Sparkle's `generate_appcast` on the verified DMG, signs with the private key from
the login keychain or from `SPARKLE_PRIVATE_KEY_FILE`, and links the DMG by the release tag
`v<MARKETING_VERSION>`. Sparkle compares `CURRENT_PROJECT_VERSION`. How the key is made is in the script's
header.

## Work by kind

"Two phases" means the first request is cancelled, the work is finished and the app quits by itself, as
above; on the system and signal routes it also means the logout or restart is cancelled. "Passes" means quit
does not wait for or mention the work. A warning is shown on the `.user` route only; on the other two the
same loss is one line in the log.

### Dictation

| Work | State that names it | Quit | Holds an update |
|---|---|---|---|
| Microphone starting | `state == .starting` | two phases: the attempt is invalidated and the start awaited; a late start that holds audio is saved as raw CAF marked `recognition_skipped`, an empty one deleted | yes |
| Recording | `state == .recording` | two phases: stopped; recognition is not run; raw CAF and a line marked `recognition_skipped`; nothing pasted | yes |
| Being recognized | `job.phase` `.stopping` or `.recognizing` | two phases: recognition cancelled, the model not waited for; saved as above | yes |
| Being saved | `job.phase` `.saving` | two phases: that save is awaited; the text is in the history, not pasted | yes |
| Being pasted | `pasteDelivering` | two phases: the paste is awaited until the clipboard is restored | yes |
| A save not confirmed at an earlier quit | `pendingSaves` | two phases at every quit: the save is retried; refused while it fails | no |
| Recognize Again, recognizing | `recognizeAgainRun`, no save yet | warns (`recognizeAgain`); then two phases: the run is cancelled, the line keeps its text | yes |
| Recognize Again, saving | `recognizeAgainRun.save` | two phases: the save is awaited; its failure is logged and does not refuse quit | yes |
| ⌃⌘V, before delivery | `pastePress`, `isPastingLast` | passes; the paste is dropped | from key-up |
| ⌃⌘V, delivering | `pasteDelivering` | two phases: awaited until the clipboard is restored | yes |

### Meeting recording

| Work | State that names it | Quit | Holds an update |
|---|---|---|---|
| Starting | `state == .starting` | warns (`recordingToTranscribe`) when "transcribe after stop" is set; then two phases: the start is cancelled and awaited | yes |
| Recording | `state == .recording` | the same warning; two phases: stopped and saved with `metadata.json`; not queued for a transcription | yes |
| Stopping | `state == .stopping` | the same warning; two phases: the stop is awaited | yes |
| A stop without proof of the save | `unconfirmedRecording` | two phases at every quit; refused until the proof is there or the user allows quitting | no |
| The live transcript's lines | `liveTranscriptModel`, `stoppedLiveTranscript` | finished inside the stop; in memory only, nothing of it is written | through the recording |
| The call-window file | `callFeedWatcher` | closed inside the stop, before the tracks | through the recording |

### Transcription queue

| Work | State that names it | Quit | Holds an update |
|---|---|---|---|
| A transcription waiting | `pending` with `transcribe` | warns (`meetingTranscription`); then passes. The launch scan queues folders without a transcription, so it is not made later | yes |
| A transcribing job taken, its folder being resolved | `activeJob` set, `isTranscribing` false, `step` nil | passes, or warns with `transcriptCopy` when a transcripts folder is set | yes |
| Transcribing, or waiting for the engine | `isTranscribing` | warns (`meetingTranscription`); then passes; the attempt record stays in progress | yes |
| The copy into the transcripts folder | the `transcriptCopy` condition | warns; then passes; the transcript stays in the meeting folder and no scan copies it | yes |
| Old-audio deletion, compression, the move, at the end of a transcribing job | `step` set, `activeJob.transcribe` | passes; the launch scan and the audio pass take the folder again | yes |
| The same steps in a job without a transcription | `activeJob` without `transcribe` | passes; redone the same way | no |

### Main window and Files

| Work | State that names it | Quit | Holds an update |
|---|---|---|---|
| A meeting's marks or notes not on disk yet | `MeetingLibrary.pendingMarks` | warns (`unsavedMeetingMark`); then passes | yes |
| A note whose write was refused or failed | `MeetingLibrary.noteFailures` | warns (`unsavedMeetingMark`) at every quit while the entry is there; then passes | no |
| Save As, the file being written | `exporting.writing` | warns (`transcriptFile`); then passes | yes |
| A Files run | `FilesModel.isTranscribing` | warns (`fileTranscription`); then passes | yes |
| Unsaved Files text | `FilesModel.hasUnsavedText` | warns (`unsavedFileText`) at every quit while it is unsaved; then passes | no |

## Not seen by quit

Neither `quitLosses()`, `hasUnfinishedWork` nor `AppUpdater.busy` reads these; quit and a relaunch go ahead
without a word about them:

- **Dictations whose history write failed during ordinary work** (`unsavedDictations` entries that are not in
  `pendingSaves`). The text is in memory and the menu says "Available until you quit the app"; the source CAF
  stays in the temporary folder.
- **A name, star or speakers' names that failed to write** (`MeetingLibrary.markFailures`). The card or the
  window's notice has said so.
- **A confirmed deletion to the Trash under way** (`removalsUnderWay`, the queue's `.removing` operations).
  What was not reached stays where it was.
- **Save As with only its panel open** (`exporting` set, `writing` false).
- **A model download** (`ModelDownloader.download`). Its `.partial-<UUID>` folder stays in `Models` until the
  next download starts and removes it.
- **The dictionary's import and export** (state of the Dictionary view). The export writes atomically.
- **A Connect or Install Command run** in Settings, Agents.
- **Text being typed**: a meeting's name on the card, a note's draft in the notepad, a sheet's fields.
- **A meeting stopped by a quit that was then refused.** It was not offered to the queue, and the app keeps
  running; the next scan (after the next recording stops, when a volume is mounted, from Storage, or at
  launch) queues it for compression and the move, without a transcription.
- **Work folders in the temporary directory** (`Murmurly-meeting-<UUID>`, `Murmurly-file-<UUID>`,
  `Murmurly-live-<UUID>`). Each is removed by a `defer` in its job; nothing looks for them at launch.
- **Crashes, SIGKILL and power loss.** No quit path runs.

## Why it is this way

- **`.terminateLater` is not used.** AppKit then waits in a nested modal run loop inside `terminate`. When
  `terminate` was called from a block on the main queue (a main-actor task, the SIGTERM source), that loop
  could not drain the main queue, the work that had to answer never ran, and quit hung forever. The price of
  cancelling instead: a logout or restart during unfinished work is cancelled by the first phase.
- **The deadline refuses rather than forces.** Twenty seconds is long enough to archive a five-minute
  dictation. Past it the answer is "no" and the unfinished work keeps running: a start or stop stuck in Core
  Audio must not hold the answer, and a forced exit would drop what quit exists to save.
- **Quit does not wait for the model.** A model load can take far longer than any deadline; the raw audio is
  enough to recognize the dictation later.
- **A recording stopped by quit is not queued.** The process is about to end, and the stop must never wait on
  the queue; the launch scan compresses it.
- **A person is warned, a logout is not.** Logout, restart, shutdown and a signal do not wait for an answer,
  so a banner would only delay them; the log line is what remains.
- **The consent to a warned quit expires after 10 s** and covers only the losses it named: one that never
  expired would let a much later quit end new work unasked.
- **Sparkle's quit is a person's quit on purpose**, so unsaved Files text still warns.
- **Busy refuses the relaunch instead of postponing it** (Sparkle's delegate can also postpone a relaunch
  until a block is called): postponing left Sparkle's "Ready to Install" window on screen, unclosable and
  with a dead button, for the whole call.
- **Unsaved Files text is not in `busy`**: it never ends by itself and would hold the update until saved.
- **Compression and moves of their own are not in `busy`**: the launch scan queues them again. A job that
  transcribes counts to its end because the scan queues the folder without the transcription and without the
  copy.
- **`busy` reads the streams** because `@Published` emits before the property changes. The hand-overs between
  the recorder and the queue run synchronously on the main actor, so Sparkle's question never lands on a
  brief false between them.
- **`AppUpdater` starts Sparkle itself**: on a failed start the controller would show an alert through a
  nested modal run loop. The reason goes to Settings and the log.
- **The feed is signed and the archive checked before extraction**, so a changed feed or archive is refused
  before anything of it runs. Without a Developer ID every update has a new code hash, and macOS may ask for
  the permissions again.
