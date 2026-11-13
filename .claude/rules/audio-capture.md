---
paths:
  - "Sources/MeetingRecorder/SystemAudioCapture.swift"
  - "Tests/MurmurlyTests/SystemAudioCapture*Tests.swift"
  - "Tests/MurmurlyTests/SystemAudioLiveAudioTests.swift"
  - "Tests/MurmurlyTests/MissingMicrophoneTests.swift"
---

# Meeting audio capture

Services layer. `SystemAudioCapture` records the system mix and the microphone into two CAF tracks on one clock,
measures them at the stop and feeds the live-audio ring.

- **Add nothing to the IOProc that allocates, locks, logs or awaits.** `murmurlySystemAudioIOProc` runs on Core
  Audio's realtime thread; its only lock is `SystemAudioRuntime.record`, on the write-error path.
- **A cycle goes to both tracks or to neither.** A cycle with a stream missing, or with different frame counts, is
  skipped and counted (`cyclesWithoutAStream`, `cyclesOutOfStep`), never written to one file: equal frames per
  cycle are what keeps the tracks aligned. Only a failed write can leave them apart, and that fails the recording.
- **Both files take the aggregate's nominal rate, never the rate the tap's stream declares**
  (`SystemAudioCapture.trackFormats`): the tap arrives resampled to the microphone's clock while still declaring its
  own rate, and a file made at the declared rate plays at the wrong speed.
- **Read `SystemAudioRuntime`'s fields only behind `AudioDeviceStop` and `AudioDeviceDestroyIOProcID`.** The IOProc
  is their only writer while capture runs; outside that fence only the atomic `writtenFrames` and the immutable
  `live` are safe.
- **The ring has one writer and one reader.** The IOProc writes, `LiveAudioRing.read()` is called only through the
  capture actor, and a new base is set only while the ring is empty; a second reader or a base moved under a read
  hands out samples with the wrong `firstFrame`.
- **The ring gets a cycle only after both files accepted it,** and a full ring drops the cycle for the live text
  only: the live transcript never shows audio the tracks do not hold, and never costs the tracks a frame.
- **A failed or cancelled `start(in:)` removes the folder it was given; nothing else in the capture ever does.**
  Pass it only a folder made for this session.
- **`stop()` never discards audio.** Both tracks are closed even if one fails; a `failed` state or an unwritten
  `metadata.json` throws `captureFailed(message:savedAt:)` and the folder stays.
- **`failed` is fixed before the `suspect` reasons are added:** only an unreadable track or a write/close error
  fails a recording. `state` is `done`, `suspect` or `failed`, never translated; `issues` is interface text in
  the language of the moment, never branch on it.
- **Other code tells recording time by `writtenSeconds()`** (frames accepted into the tracks ÷ their rate), never
  by the wall clock, which runs ahead of the files while a headset is gone.

How it works: `reference/meeting-recording.md`.
