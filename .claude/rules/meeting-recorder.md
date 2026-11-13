---
paths:
  - "Sources/MeetingRecorder/MeetingRecorder.swift"
  - "Sources/MeetingRecorder/MeetingWatchdog.swift"
  - "Sources/MeetingRecorder/RecordingsStore.swift"
  - "Tests/MurmurlyTests/MeetingRecorderTests.swift"
  - "Tests/MurmurlyTests/MeetingWatchdog*Tests.swift"
  - "Tests/MurmurlyTests/RecordingsStoreTests.swift"
---

# Meeting recorder and automatic recording

Feature layer. `MeetingRecorder` owns a recording from folder to queue; `MeetingWatchdog` starts automatic ones.

- **Check the other mode and take the state in one main-actor turn.** `beginStart` refuses while
  `dictation.isBusy`, `DictationCoordinator.toggle` while `meetingPeer.isBusy`; an `await` between the check and
  `state = .starting` lets both take the microphone.
- **Make the session folder and set `currentSession` before the start is awaited, and clear it last** (the
  `defer` in `beginStop`, after the queue's job is in). The window, marks, deletions and the queue tell "the
  recording under way" from "a folder that broke off without `metadata.json`" only by it.
- **No `await` between `state = .idle` and `offerToQueue`:** quit and `AppUpdater.busy` must never read "nothing
  busy" between the recorder and the queue.
- **Keep `beginStop`'s order:** `keepLiveTranscriptForNotepad()`, `.stopping`, `watchdog.recordingWillStop()`,
  then in the task `live.finish()`, the call feed's `finish()`, `capture.stop()`. `@Published` sends in `willSet`,
  the ban snapshot must precede the save, and the feed must be closed before `metadata.json` exists.
- **Never cancel `capture.start` to stop an automatic recording that is still starting:** cancellation removes
  the folder. `stopFromWatchdog` sets `stopAutomaticWhenStarted`, and the late success takes the ordinary stop.
- **A cancelled start task must not clear `operationTask`:** the stop or quit has replaced it and waits on it.
- **A partial failure never discards the recording.** An error with `savedDirectory` becomes a `recordingWarning`
  tied to that folder; a later clean recording neither clears nor relabels it.
- **Report every end of an automatic attempt to the watchdog exactly once** (`automaticStartFailed`,
  `automaticStartCancelled`, or `recordingWillStop` then `recordingDidEnd`): it acts on events, not on `state`.
- **`recordingTrigger` stays nil for a manual recording;** `manual` (`MeetingMetadata.manualTrigger`, never
  translated) exists only in `metadata.json`. The watchdog path tells the two kinds apart by the nil.
- **An unreadable process snapshot (`nil`) is "unknown", never "nobody holds the microphone";** the time limit is
  checked before the snapshot is read. Murmurly itself and System Settings are never holders.
- **`RecordingsStore.createSession` gives the only folder names `MeetingStorage.isMeetingFolderName` accepts**
  (`yyyy-MM-dd HH-mm-ss Meeting`, with `-N`); change both or neither, and never translate the suffix.

How it works: `reference/meeting-recording.md`.
