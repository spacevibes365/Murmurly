# Meeting recording

How a meeting gets from a shortcut (or a call that takes the microphone) to two audio tracks and a
`metadata.json`: the recorder's session, the capture, the check after the stop, and automatic recording.
The rules that must not be broken are in `.claude/rules/audio-capture.md` and
`.claude/rules/meeting-recorder.md`.

## Parts

| Type | Isolation | Owns |
|---|---|---|
| `MeetingRecorder` | main actor | the state machine, `currentSession`, the stop's results, the live transcript and call feed of the recording, the recorder's part of quit |
| `MeetingWatchdog` | main actor | the decision to start or stop an automatic recording, bans, the 4-hour limit |
| `RecordingsStore` | main actor, no stored state | the meetings root, session folders, writing `metadata.json` |
| `SystemAudioCapture` | actor (`MeetingCaptureBackend`) | one capture session: start, stop, measuring the tracks |
| `SystemAudioTapRecorder` | used only by the capture actor | the tap, the aggregate device, the IOProc, both files |
| `SystemAudioRuntime` | written by the IOProc | file handles, frame counters, skip and silence counters, the ring |
| `LiveAudioRing` | one writer (IOProc), one reader (the actor) | the last ~30 s of both tracks for the live transcript |

`MicCapture` (dictation) is not involved: a meeting's microphone is read through the aggregate device.

## A session

`MeetingRecorder.State` is `idle`, `starting`, `recording`, `stopping` or `failed(message, cause:)`; `isBusy` is
the middle three. `toggle()` (the meeting shortcut, the menu, the notepad's Stop) starts from `idle` or `failed`,
stops from `recording`, and is ignored with a log line in `starting` and `stopping`.

**Start** (`beginStart(trigger:)`, `trigger` nil for a manual start):

1. Refused while quitting, while busy, while `dictation.isBusy`, or without microphone access. Only a manual
   start flashes the reason; an automatic one returns `false` silently and the watchdog tries again on a later
   tick.
2. `RecordingsStore.createSession` makes `<meetings root>/<yyyy-MM-dd HH-mm-ss> Meeting` (with `-2`, `-3`… when
   the name is taken). The root is `~/Library/Application Support/Murmurly/Meetings`. A folder that cannot be
   made sets `.failed` and, for an automatic start, bans the attempt's holders.
3. In the same main-actor turn: `state = .starting`, `currentSession = Session(directory:identity:trigger:)`,
   `lastRecordingDirectory = nil`. A manual start also resets the watchdog's attempt
   (`manualRecordingStarted()`) and calls `AppWindowController.enterRegular()`, so the system audio consent
   dialog has a foreground app, then waits `permissionPromptDelay` (150 ms) inside the task. A start task that
   runs to its end calls `AppWindowController.windowDidClose()`; the early return of a start that was cancelled
   after the capture began does not.
4. The task awaits `capture.start(in:)`. On success: `state = .recording`, a new `LiveTranscriptModel` if
   `meeting.liveTranscript` is on, `currentSession.startedAt`, the beep, the indicator. Then the call feed watcher
   (if `meeting.namesFromCallWindow` is on) and the live transcript are started.

How a start ends otherwise:

| What happened | Result |
|---|---|
| `capture.start` threw | `.failed(message, cause:)`, session cleared; the capture has removed the folder; `watchdog.automaticStartFailed(passing:)` |
| The task was cancelled before the capture began (quit) | `capture.stop()` tried, `idle`, session cleared, `automaticStartCancelled()` |
| The task was cancelled but `capture.start` returned success | `stopCancelledStart()`: the capture is stopped the ordinary way, so the tracks and `metadata.json` are saved; this path does not add `trigger` and does not set `lastRecordingDirectory` |
| The watchdog ordered a stop while `starting` (`stopAutomaticWhenStarted`) | the start completes, then `beginStop()` runs at once |

**Stop** (`beginStop(atLimit:)`, only from `recording`), synchronously: the live transcript's lines are copied to
`stoppedLiveTranscript`, `state = .stopping`, the live model and pipeline are taken,
`watchdog.recordingWillStop()` takes the ban snapshot, the indicator shows saving. Then, in the task:
`live.finish()`, the call feed's `finish()`, `capture.stop()`.

| `capture.stop()` | What is published |
|---|---|
| returned the tracks | `lastRecordingDirectory`; `trigger` written into `metadata.json`; a `recordingWarning` if the state is not `done` or the stop was at the limit; `idle`; the folder offered to the queue (`enqueue` with `transcribe:` from `meeting.afterStop`, then `scanLocalFolders()`); beep; "saved" or "saved with a warning" |
| threw with `savedDirectory` | `lastRecordingDirectory`, `trigger` written, `recordingWarning` with the file's `issues`; `.failed`; "saved partially"; not offered to the queue |
| threw without one | `.failed`, failure banner |

`currentSession` and `recordingTrigger` are cleared, and `watchdog.recordingDidEnd()` called, in the task's
`defer`, after all of the above.

`trigger` in `metadata.json` is the automatic recording's bundle ID, `pid:<n>` for a holder without one, or
`manual`. The capture writes the file; the recorder reads it back, sets `trigger` and writes it again
(`metadata(in:applying:)`).

`recordingWarning` (`directory`, `issues`) is in memory and tied to its folder: a later clean recording leaves it,
a later problem replaces it, deleting the meeting or dismissing it clears it. A stop at the 4-hour limit adds its
own issue to the warning and shows "saved with a warning", but nothing about the limit is written to
`metadata.json`.

## What other parts read from the recorder

| Reader | Reads |
|---|---|
| `DictationCoordinator` | `meetingPeer.isBusy` before its own start (set in `MeetingRecorder.activate`) |
| `MeetingTranscriptionQueue` | `isRecorderBusy`, `currentRecording`, `currentRecordingIdentity`, `heldByLiveTranscript`, through closures set in `transcripts.didSet` |
| Main window, marks, deletions | `currentSession` (the folder and its `FolderIdentity`) |
| Notepad | `liveTranscriptModel`, `stoppedLiveTranscript`, `recordingSeconds()` |
| Quit | `hasUnfinishedWork`, `beginTermination()`, `cancelTermination()`, `unconfirmedRecording` |

For quit, `finishForTermination` stops a recording (or cancels a start), waits for `operationTask`, and answers
true only with proof: a clean stop, or a failed one whose folder holds a `metadata.json` with a terminal state
and an end time. Without proof the recording becomes `unconfirmedRecording`, which blocks the next quit until the
proof appears or the user releases it. While `isTerminating`, new starts are refused and a stopped recording is
not offered to the queue; the next stop's or the next launch's scan finds its folder.

## Capture: one aggregate, one IOProc

`SystemAudioCapture.start(in:)` refuses a second session and a missing microphone permission (it never asks),
then `SystemAudioTapRecorder.start` builds, in order:

1. **The microphone.** The default input device must have exactly one input stream. No stream or no channel yet
   is read again every 100 ms for up to 2 s, then fails with `microphoneNotReady`. One or two channels are
   recorded as they come; three or more (voice processing, multichannel interfaces, virtual devices) keep only
   the first: the microphone file is mono with a converter channel map of `[0]`, applied on the asynchronous
   writer's thread.
2. **The process tap.** `CATapDescription(monoGlobalTapButExcludeProcesses: [])`, private, unmuted, made with
   `AudioHardwareSystem.shared.makeProcessTap`: the whole system mix, mono, no process excluded. No Screen
   Recording permission is involved; macOS asks for system audio recording when the aggregate first starts.
3. **A private aggregate device** (`makeAggregateDevice`): the microphone is its only sub-device and its main
   sub-device (the clock), the tap is in its tap list with drift compensation. Its two input streams are waited
   for up to 2 s and told apart by `startingChannel`: the microphone starts at 1, the tap right after the
   microphone's channels.
4. **Formats** (`trackFormats`): the microphone stream's format as it is, the system stream's format with the
   sample rate replaced by the aggregate's nominal rate. A microphone stream whose rate is not the clock's, or
   whose channel count changed, refuses the start.
5. **Files** `system.caf` and `microphone.caf` (`ExtAudioFile`), the ring if the formats allow one, then
   `AudioDeviceCreateIOProcID` and `AudioDeviceStart`.

Any failure tears down what exists (IOProc, files, aggregate, tap) and removes both files; the actor then removes
the folder. The actor returns the start time (`Date()` after `AudioDeviceStart`) and holds a `ProcessInfo`
activity (`.userInitiated`, `.latencyCritical`) until the stop.

`canCreateProcessTap()` creates and destroys one tap. It proves only that a tap can be made, not that recording
is allowed.

## One cycle in the IOProc

`murmurlySystemAudioIOProc` gets both streams' buffers each cycle.

| Cycle | What happens |
|---|---|
| Neither stream has frames | ignored |
| A stream is missing from the buffer list | skipped, `cyclesWithoutAStream += 1` |
| Both present, frame counts differ (one empty included) | skipped, `cyclesOutOfStep += 1` |
| Both present, equal frames | written to both files with `ExtAudioFileWriteAsync` |

The first skipped cycle of a run records `skippingSinceFrame`; a whole cycle clears it. A write error is recorded
once (`record`) and that cycle does not advance the counters. After a successful write: the silence counters are
updated (a microphone buffer whose every byte is 0 is exact digital silence; a run of at least 10 s widens
`longSilence`), `frames` grows, its atomic copy `writtenFrames` is stored, and the cycle is copied into the ring.

`writtenSeconds()` is `writtenFrames ÷ sampleRate`: the recording's own clock, used for the call feed's `t`, the
notepad's notes and moments, and the live lines' times. It is nil outside a session.

## The live-audio ring

`LiveAudioRing` exists only when both streams are Float32, packed and interleaved; otherwise the start logs
"live audio off" and `liveAudio()` always answers nil. It holds `sampleRate × 30` frames: the system track mono,
the microphone with one or two channels as its file gets it (channel 0 of three or more). Both buffers are
allocated and zero-filled before capture starts.

`write` (IOProc) copies a cycle in and publishes `written` with a releasing store. `read` (through the actor)
returns everything unread as one `LiveAudio`: `sampleRate`, `microphoneChannels`, `firstFrame` (counted like
`writtenFrames`), `system`, `microphone`, `dropped`, or nil when nothing new is there.

When a cycle does not fit, it is dropped and counted, and the ring then drops every cycle until the reader has
emptied it: a new base (the frame number of a ring position) may only be set on an empty ring. So after an
overflow the next read returns the old, contiguous audio with `dropped > 0` (frames lost after that snapshot's
samples), and the read after it starts with a jump in `firstFrame`. A cycle larger than the whole ring is always
dropped. The files are never affected.

## After the stop: measuring

`SystemAudioCapture.stop()` stops and destroys the IOProc, closes both files (each close error is kept, the first
never hides the second), destroys the aggregate and the tap, then opens both closed tracks with `AVAudioFile` and
takes their real length. The IOProc's counter only says what was handed to the asynchronous writer.

| Finding | State |
|---|---|
| No session in the recorder, a write error in the IOProc, a close error, or a track that cannot be opened | `failed` |
| A track's measured frames differ from `enqueuedFrames` | `suspect` |
| The two tracks differ in length | `suspect` |
| Only the first of three or more microphone channels was recorded | `suspect` (always, for such a microphone) |
| The microphone sent exact silence in runs of 10 s or more | `suspect`, with the span from the first long run to the last and the silent time in it |
| Skipping lasted to the stop | `suspect`: "dropped out at <time> and did not come back" |
| Cycles were skipped earlier | `suspect`: about `wall − audio` seconds missing from both tracks (at least 0.1) |
| Audio length against the wall clock | `suspect` when they differ by more than 2 s; with skipped cycles, only when the audio is longer by more than 2 s |

Nothing else makes a recording `suspect`, and none of the `suspect` reasons can make it `failed`. The wall clock
is `Date()` at the end of the start and at the stop.

`metadata.json` (`MeetingMetadata`, written atomically by `RecordingsStore.writeMetadata`, keys sorted):

| Key | Meaning |
|---|---|
| `startedAt`, `endedAt` | ISO 8601 |
| `sampleRate` | the aggregate's nominal rate, the rate of both files |
| `state` | `done`, `suspect` or `failed` from the capture |
| `segments[0].system`, `.mic` | track file names |
| `segments[0].frames`, `.micFrames` | measured frames; absent when the track could not be read |
| `segments[0].enqueuedFrames` | frames handed to the write queue, diagnostics only |
| `segments[0].micInputChannels`, `.micRecordedChannel` | channels the microphone delivered; `1` when only the first was written |
| `segments[0].systemGain`, `.micGain` | set later by compression, not by the capture |
| `trigger` | added by the recorder after the stop |
| `issues` | the reasons, as interface text in the language of the moment |

`failed`, or a `metadata.json` that could not be written, makes `stop()` throw `captureFailed(message:savedAt:)`
with the folder; `done` and `suspect` return `[system.caf, microphone.caf]`, and the recorder learns of `suspect`
from the file.

## Automatic recording

`MeetingWatchdog` ticks every 2 s on the main run loop (and once at `start()`), and also acts on the recorder's
events. A meeting is a foreign process holding audio input: `AudioHardwareSystem.shared.processes` gives each
process's `pid`, `bundleID` and `isRunningInput` without any permission or prompt. A process whose `pid` or
`isRunningInput` cannot be read is left out of the snapshot; a snapshot that cannot be read at all is nil.

**Holders** (`MeetingWatchdog.holders`): processes with `isRunningInput`, except Murmurly's own PID and bundle ID
and System Settings with its panes (`com.apple.systempreferences`, `com.apple.systempreferences.*`,
`com.apple.*-Settings.extension`). **Active** holders are holders that are neither banned nor excluded
(`meetingExcludedBundleIDs`).

**One tick** (`tick`, then `decide`):

1. If an automatic recording has run for 4 hours (`maximumAutomaticDuration`, counted from the decision to
   start), `requestLimitStop()` and nothing else.
2. Read the snapshot; nil ends the tick.
3. With automatic recording off: bans of processes that released the microphone are lifted, nothing starts.
4. Bans and one-time retries are kept only for PIDs that still hold the microphone.
5. An automatic attempt is open: while recording, any active holder clears the silence timer; with none, the
   timer starts, and after 30 s (`stopHysteresis`) the recording is stopped.
6. No attempt is open and the recorder is `idle` or `failed`: with an active holder, a start is requested for the
   one with the lowest PID (`trigger` is its bundle ID or `pid:<n>`), and every active holder is remembered as
   `attemptHolders`. A refused request (dictation busy, no permission, quitting) resets the attempt without a
   ban.

**Bans** (`blockedPIDs`) keep a process from starting or prolonging a recording until it releases the microphone.

| Event | Who is banned |
|---|---|
| A recording is stopped, manual or automatic (`recordingWillStop`, as `beginStop` begins) | the holders in a snapshot read at that moment; if it cannot be read, the attempt's and the session's known holders |
| `capture.start` failed, or the session folder could not be made (`automaticStartFailed`) | the attempt's holders |
| `capture.start` failed with `microphoneNotReady` and no stop was ordered | each holder is let off once (`retriedPIDs`) and gets the next tick's attempt; a second such failure bans it |

**Other stops and changes:**

- The Mac is going to sleep: any recording in `.recording` is stopped, manual ones included; one still `starting`
  is not.
- Automatic recording turned off while an attempt is open: the recording is stopped (or, while `starting`,
  stopped as soon as it has started).
- An exclusion added while an attempt is open: the recording is stopped if an excluded app holds the microphone
  and no holder outside the exclusions remains.
- A manual start resets the attempt, so neither the 30 s stop nor the limit applies to a manual recording; earned
  bans stay.

The tap records the whole system mix, so an exclusion never removes an app's sound from a recording.

## Numbers

| What | Value |
|---|---|
| Watchdog tick | 2 s (tolerance 0.2 s) |
| Stop after the last active holder lets go | 30 s |
| Limit of an automatic recording | 4 h |
| Wait for the microphone's stream, for the aggregate's streams | 2 s each |
| Delay before a manual start's capture | 150 ms |
| Exact microphone silence that is reported | runs of 10 s or more |
| Clock check | 2 s |
| Ring | 30 s at the aggregate's rate |

## Why it is this way

- **Separate tracks are the key design choice.** They give the recording source and the order of utterances.
  They do not give speaker identity: the system track mixes everyone on the call, and the microphone may hear
  more than one person.
- **A process tap needs no Screen Recording permission,** and with the microphone as the aggregate's clock one
  IOProc can write both tracks on one clock.
- **The tracks are measured after the stop** because `ExtAudioFileWriteAsync` only queues: its counter says what
  was accepted, not what reached the disk.
- **A skipped cycle is left out of both tracks** because a Bluetooth headset that drops out mid-call removes its
  input device: the aggregate goes on for a moment on the tap's clock without the microphone stream. Writing
  only the system track would shift everything after it; the gap is told by the clock instead, since for moments
  Core Audio delivers no cycle at all.
- **The clock check ignores short audio after skipped cycles:** skipped cycles explain audio shorter than the
  clock, never longer. Audio ahead of the clock means a wrong rate.
- **A headset's microphone opens with zeros.** On real hardware the microphone's sound begins up to about 2 s
  after the system audio's: its track opens with exact zeros. That is normal: both tracks share one clock and
  stay aligned, and only runs of 10 s or more are reported, since a live microphone's noise floor is never all
  zeros.
- **The tap's declared rate is not the delivered one.** A process tap's stream declares the tap's own rate even
  when the aggregate resamples it. With AirPods in headset mode the microphone, the aggregate's clock, runs at
  24 kHz, and the tap's stream still says 48 kHz while 24 kHz arrive, 480 frames a cycle on both. A file made at
  the declared rate would play twice as fast, so both files take the aggregate's nominal rate, and the IOProc's
  equal-frames check guards it while recording. AirPods also have a 48 kHz two-way mode, so a meeting with them
  is recorded at 24 or 48 kHz.
- **Three or more microphone channels keep only the first.** Mixing would add whatever else the device carries,
  and a track of sixteen channels would only fill the disk. Whether the voice is in the first channel is not
  known, so the recording says it kept one channel of N.
- **System Settings is never a holder:** Sound → Input holds the microphone for its level meter, and checking
  the microphone there (on a first install, right after the system audio prompt) would otherwise record an empty
  meeting. Each pane runs as an extension process of its own, hence the pattern for their bundle IDs.
- **The ban snapshot is taken as the stop begins,** before the save is awaited, so a call that starts while the
  save runs is not banned together with the one being stopped.
- **The limit is checked before the snapshot is read,** so an automatic recording ends on time even while Core
  Audio cannot be read; it is reported in memory only, since `metadata.json` describes the tracks and the limit
  says nothing about them.
- **A `microphoneNotReady` failure is let off once** because the call itself may have just been taking the
  microphone; one such failure should not cost the whole call.
- **A stop ordered during `starting` does not cancel the start,** because a cancelled `capture.start` removes
  the folder; a late success must go through the ordinary, durable stop.
