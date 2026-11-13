---
paths:
  - "Sources/MeetingRecorder/MeetingTranscription.swift"
  - "Sources/MeetingRecorder/MeetingStorage.swift"
  - "Tests/MurmurlyTests/MeetingCompressionQueueTests.swift"
  - "Tests/MurmurlyTests/MeetingMove*Tests.swift"
  - "Tests/MurmurlyTests/MeetingAutoTranscriptionTests.swift"
  - "Tests/MurmurlyTests/MeetingStorageTests.swift"
  - "Tests/MurmurlyStageGateTests/Meeting*StageGateTests.swift"
---

# Meeting transcription queue

Features layer. `MeetingTranscriptionQueue` works through meeting folders one job at a time: transcription and the
transcript's copy, the audio rule's step, then compression to ALAC and the move to the chosen meetings folder.

- **Every step is recovered from the files alone.** Quit never waits for the queue and nothing is remembered
  across launches, so a step may be killed anywhere; its hidden leftovers are removed by the code that names them.
- **`metadata.json` always names a whole, existing file.** Compression order is fixed: `.<track>.partial.m4a`,
  `verify` sample by sample, rename, `commit` (every other key kept), and only then the CAF goes.
- **A reader of a compressed track divides by its gain.** A track peaking above 1 is written scaled, with
  `micGain` / `systemGain` in the metadata; above `maximumPeak` or with non-numbers it stays CAF.
- **A move removes the only local copy for good.** Fixed order: copy to `.<name>.partial-<UUID>`, `difference`,
  rename, local folder to `.<name>.removing`, remove; a name taken there passes only byte for byte.
- **Nothing in `move` tells the meetings folder from the local root.** That check is
  `SettingsStore.chooseMeetingsFolder`, by resolved paths when the folder is chosen; set the path no other way.
- **Take an operation before the disk is touched.** After its waits (`marksBeingWritten`, `audioOpening`) the
  move re-reads `FolderIdentity` and calls `beginOperations` in the same turn of the main actor, no `await`
  between; `movedTo` is set in the turn `endOperations` runs, as the marks writer needs both.
- **Only finished folders directly in the local root are compressed or moved** (`finishedStates`,
  `isInMeetingsRoot`), and never while `isRecorderBusy()`: a stop still rewrites `metadata.json`.
- **No disk call on the main actor for a folder outside the local root.** `isInMeetingsRoot` compares paths
  only; `MeetingStorage.address(of:)` of anything else runs detached, as a dead network volume hangs.
- **An attempt gets its record first** (`MeetingAttempt.begin` after `Folder.inspect`); the result is written
  before `isTranscribing` goes back. The folder being recorded (`currentRecording`) is never transcribed.
- **A choice belongs to its job** (`Job.choice`), never to the settings; `enqueue` adds a job only for a
  transcription the folder does not have yet. The transcript is copied once, never over a file there.
- **Queue state changes only on the main actor**, and a job that transcribes stays in `activeJob` until
  `finish`: quit reads `pending`, `activeJob`, `isTranscribing` and `step`, `AppUpdater.busy` only the `pending`
  and `activeJob` streams.

How it works: `reference/meeting-transcription.md`.
