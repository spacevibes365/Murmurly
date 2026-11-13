---
paths:
  - "Sources/MeetingRecorder/MeetingTranscription.swift"
  - "Sources/Archive/MeetingFiles.swift"
  - "Tests/MurmurlyTests/MeetingTranscriptionTests.swift"
  - "Tests/MurmurlyTests/MeetingEchoCancellationTests.swift"
  - "Tests/MurmurlyTests/MeetingCompressedTranscriptionTests.swift"
  - "Tests/MurmurlyStageGateTests/MeetingTranscriptionStageGateTests.swift"
---

# Meeting transcription

Services layer. `MeetingTranscriber` turns a meeting folder's two tracks into `transcript.md`, and one file into
lines for the Files section (`transcribeFile`). `MeetingAttempt` is the record each attempt leaves in the folder.

- **Never replace a transcript.** `MeetingTranscriber.write` goes through a hidden `.transcript-<UUID>.tmp` in the
  same folder and moves it to a name that is free; a file already there, the user's own included, is never written
  over, renamed or removed.
- **Nothing else goes into the meeting's folder.** Chunks and the echo-cancelled microphone live under
  `temporaryRoot` and go on every exit, a cancel included; `transcribeFile` writes nothing beside the user's file.
- **Never on the main actor, never a whole track in memory.** The type is nonisolated and streams: AEC in 1 s
  blocks, the VAD block by block, one chunk per request. A two-hour track held whole costs about 1 GB.
- **A cancel writes nothing; any other break keeps what was recognized.** Every `catch` passes a cancel on
  (`Task.isCancelled || error is CancellationError`): the queue reads it as "cancelled" and removes the record.
- **Echo cancellation never fails a job.** It is on only in `MeetingTranscriber.live` (`cancelsEcho`); when the
  canceller or the system track fails, the raw microphone goes on.
- **The last steps keep their order:** `removingEcho`, `merged`, then the dictionary (`finished`). Echo removal
  counts words as recognized; a phrase split between two chunks is found only after merging.
- **The engine is read before every chunk; the dictionary, the call feed and the model check once, as the job
  starts.** A job's `Choice` is laid over the settings snapshot (`SettingsSnapshot.applying`), never written.
- **Line n of a record is line n of its transcript.** `markdown` and `MeetingAttempt.finish` walk the same
  `report.lines`, and the fingerprint is of the bytes written; change one and the other must follow.
- **The two track labels must differ in every translation.** `finish` and `merged` tell a line's track by its
  label (`speaker == microphoneSpeaker`); equal labels would make every line a microphone line.
- **`complete` is a proof, not a status:** not cut short, no failed chunk, no missing track. The audio rule deletes
  for good on it; never widen it, and read an unreadable record as unknown, never as an earlier result.
- **Records are ordered by the number in their name, never by the clock.** The type and its reading stay in
  `Sources/Archive/` (the helper links it); `Head` mirrors every field of `MeetingAttempt`.

How it works: `reference/meeting-transcription.md`.
