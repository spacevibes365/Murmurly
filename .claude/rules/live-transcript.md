---
paths:
  - "Sources/MeetingRecorder/LiveTranscript.swift"
  - "Sources/LiveTranscriptProbe.swift"
  - "Tests/MurmurlyTests/LiveTranscriptTests.swift"
  - "Tests/MurmurlyTests/LiveTranscriptRecordingTests.swift"
---

# Live transcript

Feature layer. `LiveTranscript` cuts and recognizes a meeting's audio while it is recorded and publishes lines
into `LiveTranscriptModel`, which the notepad shows.

- **Ingestion never waits for recognition.** `drain()` only fills the bounded queue (`capacity` 8, the oldest
  chunk dropped and counted in `skippedChunks`); the recognition task pulls from it. An engine call on the ingest
  path stalls the ring's only reader, and the ring overflows.
- **`finish()` never waits for a request or a model load.** It stands before `capture.stop()` in `beginStop`, so
  whatever it awaits holds the recording's stop and the quit behind it.
- **Publish only through `publishState` and `publishLines`,** which check `isFinished`: nothing reaches the model
  after `finish()`. The model is a new instance per recording, so a late result cannot land in the next meeting.
- **Nothing of the live text goes into the meeting's folder.** Chunk files live under `temporaryRoot` and are
  removed by `defer`; `transcript.md` is made after the stop by the meeting job.
- **A live-text failure changes only the model's state** (`.stopped`, `.noModel`), never the recorder's or the
  tracks. Engine, language and dictionary are values taken as the recording starts: a settings change mid-call
  must not load another model under a running meeting.
- **One request at a time, final chunks before interim ones.** An interim request goes only while the queue is
  empty, so it is never the reason final chunks are dropped.
- **A microphone line once hidden as echo stays hidden,** and echo is matched against every system line still
  kept, not only the recompute window.
- **A line's `id` never changes;** the final line inherits its interim's `id`, and there is at most one interim
  line per track, after every final one. The notepad keys its rows on that.
- **A chunk's times come from the frame number** (`origin` plus the 16 kHz index, in recording frames ÷ rate),
  never from a count of samples, which a break makes meaningless; `Chunk.number` is never reset by a break.
- **`MeetingRecorder.liveTranscriptEngine` is set with the pipeline and cleared in `takeLiveTranscript()`,** one
  synchronous step each: work in another engine waits on it and must not see a pipeline without a hold.
- **Share the batch path's pieces** (`MeetingTranscriber.writeChunk`, `removingEcho`, `normalizedWords`,
  `minimumChunkSamples`, `languageFixSeconds`, `sileroVAD`, `EchoCanceller`), so the live text and the transcript
  after the stop decide alike. Logs never carry recognized text.

How it works: `reference/live-transcript-and-call-window.md`.
