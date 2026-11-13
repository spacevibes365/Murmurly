---
paths:
  - "Sources/Dictation/DictationCoordinator.swift"
  - "Sources/Dictation/Mic*.swift"
  - "Tests/MurmurlyTests/HoldToTalkTests.swift"
  - "Tests/MurmurlyTests/EscapeCancelTests.swift"
  - "Tests/MurmurlyTests/Mic*Tests.swift"
  - "Tests/MurmurlyTests/MissingMicrophoneTests.swift"
  - "Tests/MurmurlyTests/Dictation*Tests.swift"
---

# Dictation

Feature layer. `DictationCoordinator` takes a dictation from the shortcut to saved, delivered text; `MicCapture` records it.

- **One recording mode at a time.** `toggle()` refuses while `meetingPeer.isBusy`, `MeetingRecorder` while `isBusy`:
  both need the microphone. `state` leaves `.idle` before the first `await`, so the other side never sees a gap.
- **Never lose text silently.** Every ending keeps the text or the audio (history, `unsavedDictations`, the source
  CAF) and says where. A refusal or a failure is a failure-style or conflict flash: a `.notice` hides with the indicator.
- **History before delivery.** `saveDictation` runs before `deliver`; a failed save still delivers and lists the text as
  unsaved. The temporary CAF is deleted only after a confirmed save.
- **One text.** Engine → dictionary → trim of the edges → history → paste: the history and the paste never differ.
- **A cut-off recording is never pasted** by the dictation itself; it and a failed recognition keep the source CAF byte
  for byte, whatever the audio switch says.
- **Settings are taken at the start** (`recordingSnapshot`, `recordingDictionary`): the engine, language, auto-paste,
  audio saving and dictionary of a dictation under way never change.
- **Ask again after every `await`.** A start continuation compares `startAttempt` and `state`, the pipeline asks
  `owns(entryID)`: a late success is wound down, and a job quit has claimed is not saved, pasted or deleted here.
- **An abandoned start stays busy** until both of its stops are over, its own and a late success's in
  `captureDidStart`, or a new start reaches the capture first and is ended by their late `stop`.
- **Esc.** Only `escapePressed` sets `DictationJob.skipsDelivery`. The listener is open only while `escapeCancels`,
  recomputed in the `didSet` of `state`, `job` and `hold`, because a registered Esc is taken from every app.
- **No permission prompt from the shortcut.** `startRecording` only shows a banner: an `.accessory` app cannot present
  prompts reliably and the hot path may hang.
- **`MicCapture`.** `engine.start()` stays off the main actor; a failed start removes its tap and file; nothing is
  written after the first error, so the kept file is a continuous prefix of the dictation.

How it works: `reference/dictation.md`. Quit and updates: `reference/quit-and-update.md`.
