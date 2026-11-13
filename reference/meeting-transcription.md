# Meeting transcription, its queue, compression and the move

How a recorded meeting becomes `transcript.md`, and what the queue does to the folder afterwards. The rules that
must hold are in `.claude/rules/transcription.md` and `.claude/rules/transcription-queue.md`; this file explains
the machinery behind them.

| Part | Where |
|---|---|
| `MeetingTranscriber` (the pipeline), `MeetingTranscriber.Folder`, `MeetingAttempt.finish` / `fail` | `Sources/MeetingRecorder/MeetingTranscription.swift`, first half |
| `MeetingTranscriptionQueue` (jobs, the choice panel, operations), `TranscriptionChoiceView` | the same file, second half |
| Compression, the move, the transcript's copy, `MeetingAttempt.begin` / `write` | `Sources/MeetingRecorder/MeetingStorage.swift` |
| `MeetingAttempt` (the type and its reading), `FolderIdentity`, `transcriptNumber`, `isAvailable` | `Sources/Archive/MeetingFiles.swift` |

## The pipeline (`MeetingTranscriber.transcribe`)

`MeetingTranscriber` is a nonisolated `Sendable` struct of closures (`loadSpeechDetector`, `currentEngine`,
`dictionary`, `heldByDictation`, `heldByLiveTranscript`); `MeetingTranscriber.live` wires them to the settings,
the model folder and `WhisperKitCache.shared`, and is the only place that sets `cancelsEcho`.

1. **As the job starts.** Stale `.transcript-*.tmp` files of a killed run are removed from the folder. The
   personal dictionary is taken once (`DictionarySnapshot`), before the first wait. `loadSpeechDetector` checks
   that the job's own engine has every file (tokenizer and VAD included, `ModelDownloader.missing`) and loads the
   Silero VAD, before any audio is converted; a missing model is `Failure.modelNotDownloaded`. The call feed
   (`CallFeed.read`, links refused) is read once; an unreadable feed is logged and read as none.
2. **Per track, microphone first, then system** (`transcribeTrack`). The track is converted to 16 kHz by
   FluidAudio's disk-backed source (`AudioSourceFactory.makeDiskBackedSource`), so its samples are never held in
   memory. A compressed track is divided by its gain (`GainRestoredSource`): a quieter track is recognized worse.
3. **Echo cancellation, microphone only** (`cancellingEcho`, WebRTC AEC3 from the `WebRTCAEC3` package). The
   microphone and the system track go through one `EchoCanceller` in 1 s blocks into a Float32 work file, which is
   then memory-mapped (`CleanedSource`). The output lags the input by a fixed 128 samples (8 ms). If the system
   track cannot be opened, the work file cannot be made, the canceller throws or the sample count does not come
   out equal, the error is logged and the raw microphone goes on. There is no step of its own: it runs under
   `.reading` of the microphone.
4. **Speech detection** (`speechRanges`). The track is streamed through the VAD in blocks of
   `VadManager.chunkSize`, one probability kept per block, and segmented from the probabilities with
   `VadConfig.default`'s threshold.
5. **Recognition, chunk by chunk.** A chunk under `minimumChunkSamples` (FluidAudio's 0.3 s guard) is skipped and
   counted. Each chunk is written to a CAF in the work folder and sent as one request to the cache. The engine is
   asked for again before every chunk (`engine(for:)`), with the job's choice laid over the settings; a job
   without a choice therefore follows a change of the settings in the middle of a meeting.
6. **After both tracks:** `removingEcho`, then `finished` (`merged`, then the dictionary for `.meetings`), then
   `markdown` and `write`.

Work files live in `<temporaryRoot>/Murmurly-meeting-<UUID>/` (`Murmurly-file-<UUID>/` for a Files run), removed
in a `defer`. The meeting's own folder gets only the hidden `.transcript-<UUID>.tmp` for the moment of the write.

### Waiting for the engine

The cache holds one engine. Right before a chunk's request, `engine(for:)` compares the job's engine with what
the dictation holds (`heldByDictation`) and what a live transcript of the recording under way holds
(`heldByLiveTranscript`). While either holds another engine the job shows `.waitingForEngine`, sleeps 250 ms and
reads its engine again. The wait is part of the job, so it can be stopped and quit and updates see it.

### Steps

`.reading(track)` → `.detecting(track)` → `.preparingModel` or `.waitingForEngine` → `.recognizing(track, done,
total)`. The per-chunk ones come from inside the cache operation: `recognize` gives the cache a callback that
feeds a local `AsyncStream`, and reads that stream to its end before it awaits the decoded chunk. So
"recognizing" is shown only once the engine is ready, and no step arrives after the result.
`MeetingTranscriber.Step` also carries `.compressing`, `.moving` and `.removingAudio`, which only the queue sends.

### Language

`MeetingTranscriber.Engine.forMeeting` takes the descriptor and `SettingsSnapshot.decodeRequest` of the job's
snapshot. For Whisper on Auto, every chunk goes without a language until the first non-empty chunk longer than
`languageFixSeconds` (5 s) comes back; the language it was recognized in (`report.fixedLanguage`) is then asked
for on every later chunk of the job. Tracks are processed one after the other, so this is no detector of a
change of language during a call.

### Failures

| What happens | Result |
|---|---|
| The task is cancelled | `CancellationError`; nothing is written |
| A chunk fails | counted in `failedChunks`, the job goes on |
| Three chunks in a row fail | `Failure.repeatedChunkFailures` |
| A `TranscriptionError` (a missing or broken model) | thrown at once |
| A track cannot be opened | `Failure.unreadableAudio` |
| Any of the last three with nothing recognized yet | the job fails; the other track is not tried |
| Any of the last three after something was recognized | the text so far is written, with an interruption note in its header (`Outcome.cutShort`) |
| Speech found, every chunk failed | `Failure.nothingRecognized` |
| No speech | no file; `Report.transcript` is nil (`Outcome.noSpeech`) |

### Echo left in the words (`removingEcho`)

A microphone line of at least `minimumEchoWords` (3) words is dropped when at least `echoContainment` (half) of
its words appear, in order, in the text of the system lines that overlap it in time, with `echoSlack` (0.5 s) on
either side. Words are compared lower-cased, with the Russian letter yo read as ye, and split at every
character that is not a letter or a digit (`normalizedWords`), so the rule does nothing for a language written
without separators between words. Only the count of dropped lines is kept (the header and the log).

### Lines (`merged`, `finished`)

Lines are put in time order. Neighbouring chunks of one track are joined while the pause is under `glueGap`
(1.5 s) and the block stays within `maximumBlockSeconds` (60 s), so a timecode comes at least once a minute.
With a call feed, two neighbouring system chunks that `CallFeed.pickedNames` names differently are never joined.
The dictionary is then applied to each line's text; `report.microphone` and `report.system` stay as recognized.

### The file

`markdown` writes a title (`# Meeting <date>`), a header paragraph (engines, languages, what the two labels
mean, the number of echo lines removed, pieces not recognized, an interruption note), a line `---`, and one
paragraph per line: `[m:ss] **label:** text` (`h:mm:ss` from an hour on). The labels are the interface
language's (`MeetingTranscript.microphoneLabel`, `systemLabel`). A reader takes the file as lines only when
every row below `---` has that form (`MeetingTranscript.parse`); the dictionary's written form and the
engine's text are inserted as they are.

The header names every engine a chunk was sent to (added before the request) and every language a kept chunk was
recognized in.

`write` puts the bytes into `.transcript-<UUID>.tmp` in the meeting's folder and moves that to the first name
that is free among `transcript.md`, `transcript 2.md` … `transcript 999.md`. Readers sort the versions by that
number and take the last as the latest (`versions.last` in the window, `Archive.Meeting.latest` for the
helper); the two agree as long as no lower-numbered file was removed by hand.

## Attempt records (`MeetingAttempt`)

Each attempt leaves `.attempt <NNNN> <UUID>.murmurly.json` in the meeting's folder (`number(inName:)` parses the
name back). The queue alone writes it, inside the job's detached task:

1. `Folder.inspect` must accept the folder first; a refusal leaves no record.
2. `MeetingAttempt.begin` writes the record as `inProgress`, numbered one above the highest number among the
   record names in the folder, readable or not. If it cannot be written, the attempt does not start.
3. After the pipeline, `finish` (or `fail`) fills the result and `write` replaces the file atomically, before
   `isTranscribing` goes back to false.
4. A cancel removes the record. A result that cannot be written leaves it `inProgress`, as a killed process does.

| Field | Meaning |
|---|---|
| `version` | 1; a record of another version reads as unreadable |
| `number`, `startedAt`, `endedAt` | order is the number, never the dates |
| `result` | `inProgress`, `complete`, `incomplete`, `noSpeech`, `failed` |
| `transcript`, `fingerprint` | the file's name in the folder; the size and SHA-256 of the bytes written |
| `engines`, `languages` | `DictationEngine` raw values; language codes, or `auto` |
| `failedChunks`, `cutShort`, `missingTracks` | what `complete` is decided by |
| `speakers` | the two labels as written in that run |
| `lines` | each line's `start`, `end` and `source` (`microphone` or `system`), in the file's order; no text |
| `reason` | why it failed, as shown; nothing decides by it |

`complete` means a transcript was written, the job was not cut short, no chunk failed and both tracks were
there. A transcript with a gap is `.saved` in the menu and `incomplete` on disk. The n-th line of the record is
the n-th line of its transcript for as long as the fingerprint matches the file.

`entries(in:)` lists the records by number; one that cannot be read keeps its place with `attempt == nil`.
`withLines: false` decodes through `Head`, which skips the `lines` array. `latest(writing:in:)` finds the record
of a given transcript file. A move carries the records with the folder; the copy into the transcripts folder
takes only the `.md`.

An attempt that left no record (refused by `Folder.inspect`, the recording under way, a record that could not
be made, a folder that cannot be told) is in `unrecordedOutcomes`, by the folder's path; the queue's own move
carries it, and the next attempt at the folder clears it.

## The queue (`MeetingTranscriptionQueue`)

A `@MainActor ObservableObject` with one job at a time (`job`, `activeJob`) and a list of waiting ones
(`pending`). Nothing is kept across launches; scans find the work again.

### A job

`Job` is the folder, whether it transcribes, an optional `choice` (engine and language for this transcription),
the folder's `identity` once known, and `removesAudio` when the audio rule's step is to run. In order:

1. `location(of:)` gives the folder's address now; `MeetingStorage.address(of:)` reads it off the main actor
   into `activeAddress`. An address that cannot be told drops the job (a transcription asked for leaves a
   failed outcome); a folder under a `.removing` operation drops it too.
2. With `transcribe`: the attempt and its record (above), then one copy of the new transcript into the
   transcripts folder if one is set (`MeetingStorage.copyTranscript`).
3. If the job had a choice, the queue remembers to hand the engine back, and once no waiting job transcribes it
   calls `prepareDictationEngine` (`DictationCoordinator.prepareAfterOtherEngineJob`). This runs in a job that
   transcribed; a job dropped at step 1 does not reach it.
4. With `removesAudio`: the audio rule's step (`reference/deletion-and-retention.md`).
5. For a folder directly in the local root only (`isInMeetingsRoot`): `compress`, then `move`, each skipped
   while the recorder is busy.
6. `finish` clears the active state and starts the next job.

Only the transcription can be stopped (`cancelCurrent`, from the menu); it runs in a task of its own, so the
other steps of the same job still go ahead.

### Where jobs come from

| Source | Job |
|---|---|
| A clean stop of a recording (`MeetingRecorder.offerToQueue`) | the new folder, transcribing if "transcribe after stop" is on; then a scan |
| A scan (`scanLocalFolders`): at `activate`, whenever any volume is mounted, after each clean stop | every finished local folder with work, without transcription |
| "Transcribe Meeting…" and "Transcribe Again…" in the menu (`chooseFolder`) | the chosen folder with the panel's choice |
| The main window (`MeetingLibrary.transcribe`) | the meeting at its address now, with its identity and the sheet's choice |
| The audio rule (`enqueueAudioRemoval`) | a job with `removesAudio`, or that step added to a waiting job of the folder |

A scan lists the local root off the main actor (`MeetingStorage.foldersNeedingWork`): finished folders with a
CAF the metadata names, a CAF left beside its committed m4a, or, when the meetings folder is available, every
finished folder. Its result is dropped if a deletion was reserved meanwhile (`removalEpoch`, and the scan runs
again) or if the recorder is busy when the folders would go in.

### `enqueue`

A folder is queued again only for a transcription it does not have yet. Jobs of the folder are those waiting
and the active one, matched by the folder's URL.

| Asked for | Already there | Result |
|---|---|---|
| no transcription (a scan) | any job of the folder | nothing |
| transcription as the settings say | any transcribing job of the folder | nothing |
| a choice | a transcribing job with the same choice | nothing |
| transcription | a waiting job that does not transcribe | that job takes it over |
| a choice | a waiting job that transcribes as the settings say | that job takes the choice over |
| anything else | | a new job at the end |

"The same choice" compares `SettingsSnapshot.Choice`, which is normalized to the engine and the code the engine
is asked for. A folder under a `.removing` operation is not queued. A job without an identity has it read off
the main actor (`tell`); until then `untoldTranscription` holds back every deletion from the window.

The job's start is logged with `engine=… language=…` when it has a choice and with "as the settings say"
otherwise; the language is a code, never what was said.

### Transcribing again from the menu

"Transcribe Meeting…" opens a folder panel in `panelDirectory` (the chosen meetings folder, else the local
root, not checked on disk). "Transcribe Again…" opens it inside `lastMeeting`, the last outcome's meeting
wherever it is now, so Transcribe with nothing selected takes that folder. The panel is
`AppWindowController.chooseFolder`, shown with `begin`; a test process gets a stand-in.

The panel's accessory is `TranscriptionChoiceView` over a `ChoiceDraft`: the engine and language, taken from the
settings as the panel opens and never written back. `ChoiceDraft.language` keeps the code as picked across a
change of engine; `shownLanguage` shows Auto for a code the engine does not know. An engine whose model is not
downloaded stays choosable, marked so, with a button that downloads that engine's model
(`ModelDownloader.start`). `ChoiceDraft` is also the panel's delegate: `panel(_:validate:)` throws
`ModelMissing` while a file of the chosen engine is missing, so the panel stays open and says why.

Each run writes a new `transcript N.md` and, with a transcripts folder, `<folder name> N.md` there
(`transcriptCopyName`); a copy name already taken is refused (`DeliveryFailure.alreadyThere`), kept in
`issues[folder].transcriptCopy` and shown in Storage, while the transcript stays in the meeting's folder.

### Published state

| Property | Meaning |
|---|---|
| `pending`, `activeJob`, `activeFolder`, `activeAddress` | what waits and what runs; `activeFolder` is the address the job started with |
| `isTranscribing`, `step` | the transcription under way and its step; `stepLabel` / `statusLabel` are the menu's words |
| `lastOutcome` | `.saved`, `.cutShort`, `.noSpeech`, `.failed`, `.cancelled` of the last transcription |
| `issues` | per folder, in memory: why a track stayed CAF, a copy or a move did not happen |
| `unrecordedOutcomes` | outcomes that left no record in the folder |
| `movedTo` | where this run's moves put each local folder |
| `operations` | folders taken for a move, a deletion or the audio rule's step |
| `finishedJobs` | a counter, so views that show sizes read them again |

## Compression (`MeetingStorage.compress`)

Each track `metadata.json` names as a CAF becomes 24-bit ALAC `.m4a` at the track's own rate and channel count
(`DictationHistoryStore.encodeAppleLossless`). Per track:

1. `measurePeak` reads the whole CAF. A sample that is not finite is `Rejection.notFinite`; a peak above
   `maximumPeak` (×16) is `Rejection.glitch`. Both keep the CAF.
2. With a peak above 1 the whole track is written scaled by `1 / peak`.
3. The encoder writes `.<track>.partial.m4a`; `verify` reads both files in step and requires the same format
   and length and every sample within `tolerance` (one 24-bit step) of the source times the gain.
4. The partial file is renamed to `<track>.m4a`; `commit` writes the new name, and `micGain` / `systemGain` when
   the gain is not 1, into the first segment of `metadata.json`, keeping every other key, atomically.
5. The CAF is removed.

Recovery needs no state. A hidden `.partial.m4a` is removed at the start; an m4a the metadata does not name is
unfinished and is made again; a CAF beside an m4a the metadata names is removed. A track that stays CAF is
reported in `issues[folder].compression` and is tried again by every scan.

`metadata.json` is read loosely here and in `Folder.inspect` (`finishedMetadata`), not through
`MeetingMetadata`. Only folders whose `state` is `done`, `suspect` or `failed` are finished.

## The move (`MeetingTranscriptionQueue.move`, `MeetingStorage.move`)

With a meetings folder chosen, a finished local folder goes there after compression. Compression failing does
not hold the move back, and a moved folder is not compressed later.

The queue's part:

1. Reads the folder's `FolderIdentity` and address, and the destination's address off the main actor.
2. Waits, 50 ms at a time and without a deadline, while a write of the folder's marks is pending
   (`marksBeingWritten`) or the player is opening audio of either end (`audioOpening`).
3. Reads the identity again; a folder that is no longer the one waited for is not moved this time.
4. `beginOperations(.moving, on: [source, destination])`; nil when either is another operation's.
5. Off the main actor: checks the destination's address is unchanged, then calls `mover`
   (`MeetingStorage.move`).
6. On success sets `movedTo[local path]`, gives waiting jobs of that folder the new address and identity,
   carries `unrecordedOutcomes`, and ends the operation in the same turn.

`MeetingStorage.move`:

1. Refuses a folder without finished metadata (`DeliveryFailure.unfinished`) and a target that is not available
   (`isAvailable`: an existing folder that, under `/Volumes`, is on another volume than `/Volumes` itself).
2. Removes `.<meeting>.partial-<UUID>` leftovers of a killed move from the target (only that exact form).
3. If the name is free: copies to `.<name>.partial-<UUID>`, compares every local file's size with the copy's
   (`difference`), renames into place.
4. If the name is taken: compares every local file with the one there byte by byte; any difference is
   `DeliveryFailure.conflict` and nothing is touched.
5. Renames the local folder to `.<name>.removing` in the local root and removes it. A scan removes such a
   leftover of a killed move.

`difference` is one way: it walks the local folder's regular files, every name included, and does not mind
extra files in the copy. `move` itself never compares the source with the destination as folders; that the
meetings folder is not the local root or inside it is checked by `SettingsStore.chooseMeetingsFolder`, by
resolved paths, when the folder is chosen.

`location(of:)` answers where a local folder is now: `movedTo` when the local folder is gone, otherwise
`RecordingsStore.currentLocation`, which guesses the same name in the current meetings folder for a folder
moved in an earlier run. Only the local root is asked on disk.

## Operations

`operations` lists what is being done to folders that may move or remove them: `.moving` (source and
destination), `.removingAudio`, `.removing` (the window's deletion). Each holds a `MeetingStorage.Address`: the
folder's identity when it exists, and its path with links resolved in the parent.

| Call | Matching |
|---|---|
| `beginOperations`, `reserve`, `enqueue` | `Address.isSameFolder`: the same identity, or the same path |
| `operation(on:)`, used by the marks writer, the player and the window's refusals | the identity alone |

`beginOperations` refuses while the player is still opening files of those folders, and calls `releaseAudio`
in the same turn so open files are closed. `reserve` is the window's deletion: one turn of the main actor that
refuses the recording under way, any operation on the folder, the active job, a waiting transcription of it
and an untold transcription, then takes `.removing`, drops the folder's waiting jobs that do not transcribe and
raises `removalEpoch`.

## Why it is this way

- **AEC before the VAD.** On the Mac's speakers the far side is louder in the microphone than the user. The VAD
  then joined both into one chunk, and the word filter dropped that chunk whole, the user's words with it.
- **AEC off outside `live`.** Test tracks are constant levels, not speech; the canceller would bend them.
- **The engine is read per chunk.** The cache holds one engine. A job that kept its first engine would make the
  cache reload a model after each dictation once the user switched engines.
- **The VAD is streamed by hand.** `VadManager`'s whole-track call needs the track in memory and cannot be
  cancelled. The VAD model is loaded directly rather than through FluidAudio's model hub, which may download
  and deletes the model folder after a failed load.
- **A hidden file and a move for the transcript.** A killed process leaves no half transcript, and the move
  stays atomic when meetings live on another disk. Some folders already hold a transcript written by hand.
- **Loose metadata.** Early recordings have no `endedAt`, and `MeetingMetadata` must keep requiring it for the
  quit-time proof that a recording was saved.
- **Records ordered by number.** Two attempts can share a second, and a record that cannot be read must still
  keep its place.
- **Sizes after a fresh copy, bytes for a name already taken.** Read back at once, a fresh copy's bytes would
  come from this Mac's own cache. A copy found under the name is an earlier one, and the local folder may have
  been edited since.
- **The comparison is one way** because exFAT and SMB volumes add `._*` and `.DS_Store` files of their own.
- **The local folder is renamed away before it is removed**, so a kill never leaves half of it looking like a
  meeting.
- **Paths, not the disk, for `isInMeetingsRoot`.** A folder chosen by hand may be on a network volume, and
  touching a dead one hangs the main actor.
- **The panel sizes its accessory once.** `NSOpenPanel` takes the accessory's size as it opens and never
  changes it, so the model row always reserves the room of its tallest state. A longer download failure is
  cut to two lines there, with the whole text in the tooltip.
- **`panel(_:validate:)` instead of a disabled button.** The panel's own OK button cannot be turned off.
- **One copy of a transcript, never by a scan.** A note the user renamed or deleted in the transcripts folder
  must not come back.
