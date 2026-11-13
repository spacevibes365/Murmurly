# Dictation

How one dictation goes from the shortcut to text in another app. Rules that must not be broken are in
`.claude/rules/dictation.md`, `text-delivery.md` and `hotkeys.md`; the archive it writes is in
`reference/dictation-archive.md`, the dictionary it applies in `reference/dictionary.md`.

## Parts

| Type | File | What it owns |
|---|---|---|
| `DictationCoordinator` | `Sources/Dictation/DictationCoordinator.swift` | state, the start, the pipeline, delivery, ⌃⌘V / ⌃⌘C, Recognize Again, the model's warm-up, the dictation side of quit |
| `MicCapture` | `Sources/Dictation/MicCapture.swift` | an actor around `AVAudioEngine`; writes the temporary CAF |
| `MicrophoneLevelMeter` | `Sources/Dictation/MicrophoneLevelMeter.swift` | one atomic level the tap feeds and the indicator reads |
| `HotkeyManager` | `Sources/Dictation/HotkeyManager.swift` | shortcut names, activation, the Esc listener |
| `DoubleModifierReducer` | `Sources/Dictation/HotkeyActivation.swift` | the double-press state machine |
| `TextInjector` | `Sources/Dictation/TextInjector.swift` | clipboard writes and the synthetic ⌘V |
| `AccessibilityAuthorization` | `Sources/Permissions/AccessibilityAuthorization.swift` | trust, and whether the focused field is a password field |

Flow: `MicCapture` → temporary CAF → engine (`WhisperKitCache.transcribe`) → personal dictionary → trim → history
(`DictationHistoryStore.saveDictation`) → `deliver` → `TextInjector`.

## States

`DictationCoordinator.State` is `.idle`, `.starting`, `.recording`, `.transcribing`. `isBusy` is `state != .idle`.

`.transcribing` covers everything after recording: the microphone stopping, recognition, the save and the delivery
(told apart by `DictationJob.Phase`: `.stopping`, `.recognizing`, `.saving`, `.delivering`), and also, with no `job`
at all, an abandoned start or a short hold being wound down.

`DictationJob` is the dictation between stop and its confirmed save. Exactly one side owns it: the pipeline, or quit
once `claimed` is set. The pipeline asks `owns(entryID)` after every `await`.

Who reads the state from outside: `MeetingRecorder` (refuses to start while `isBusy`), `MeetingLibrary` (holds the
meeting player off while a dictation is under way), `AppUpdater.busy`, and `heldEngine(at:)`, which names the
dictation's engine while it is busy and for 30 s after it ends (`engineHold`; nil before the first dictation), so
meeting jobs and Files runs in another engine wait (`reference/engines.md`).

## Two recording modes

Dictation and meeting recording both need the microphone and exclude each other. `DictationCoordinator.meetingPeer`
is a weak reference set in `MeetingRecorder.activate`; `toggle()` refuses with `.busyWithMeeting` while the recorder
is busy (`.starting`, `.recording`, `.stopping`; a failed recorder is not busy), and the recorder's `beginStart`
refuses with `.busyWithDictation` while `isBusy`. An automatic meeting start is refused the same way without a
banner and tried again on the watchdog's next tick. Because `isBusy` covers recognition, saving and delivery as
well, the recorder also waits while the microphone itself is already free.

Both refusals are conflict flashes: `RecordingIndicator.visibleState` shows failure-style states and conflict
flashes even with the recording indicator turned off, and hides only plain notices.

## Start

`toggle()` from `.idle` calls `startRecording()`:

1. No model on disk for the selected engine (`ModelDownloader.isReady`): a banner says where to download one;
   nothing is recorded.
2. `micGate(AVCaptureDevice.authorizationStatus(for: .audio))`: `.proceed`, or a banner (`.promptViaMenu` for
   not determined, `.openSettings` for denied or restricted). No prompt is ever shown from here.
3. `beginCapture()`: a new `startAttempt`, `recordingSnapshot` and `recordingDictionary` are taken, the app in front
   is remembered as the start target, `state = .starting`, and two tasks begin: `mic.start()` and an 8 s watchdog
   (`startTimeout`).

| What happens first | Result |
|---|---|
| `mic.start()` succeeds for the current attempt | `.recording`, the start sound, the indicator with a countdown, the 5-minute limit armed |
| `mic.start()` throws | `.idle`, a failure banner with the error (none for a cancellation) |
| The watchdog fires | the attempt is invalidated, `.idle`, "the microphone didn't respond", one `mic.stop()` |
| Hold released or Esc pressed | `abandonStart` (below) |
| Quit | the attempt is invalidated; a late success with audio is saved as `recognition_skipped` |

A late success of an attempt that is no longer current never changes state: its recording is stopped and, depending
on who invalidated it, deleted (release or Esc), kept for quit, or stopped.

`MicCapture.start()` checks that an input device exists, builds an `AVAudioEngine`, creates the CAF in the
temporary directory in the input's own format, installs a 4096-frame tap that feeds the level meter and writes the
file, and starts the engine. Any failure removes the tap and the file. A start cancelled after it succeeded stops
itself.

## Recording

The tap writes each buffer to the file. After the first failure it writes nothing more, so the file is a continuous
prefix. Two things count as a failure: a write error, and `AVAudioEngineConfigurationChange` (the audio device
changed). Either is only recorded in the capture's error box; the coordinator learns of it when it calls `stop()`,
and until then the indicator shows a recording.

A dictation lasts at most `maxRecordingSeconds` (300 s). The indicator counts down the last 30 s. At the limit the
dictation stops by itself and goes through the pipeline as usual.

`MicCapture.stop()` returns nil when nothing was recording, the file's URL for a complete recording, and throws
`PartialRecording(url:reason:)` when a failure was recorded and the file holds audio. A file proven empty is removed
and the original error thrown.

## Stop and pipeline

`beginStop` picks the paste target (`preferredInjectionTarget`: the app in front at stop, else the one at start,
never Murmurly itself), creates the `DictationJob` and sets `.transcribing`. `runPipeline` then:

1. waits for `mic.stop()`;
2. recognizes (`transcribe`): engine, then `DictionarySnapshot.replacer(for: .dictation)` off the main actor;
3. trims spaces and line breaks from both ends of the text and of the raw text; `raw_text` is kept only when it
   differs from the text;
4. saves through `saveDictation`, in a task quit can wait for;
5. deletes the temporary CAF if the save succeeded;
6. delivers, unless one of the rows below ends it earlier.

| Case | History | Audio | Delivery | What the person sees |
|---|---|---|---|---|
| Text, save succeeded | a line | m4a if `dictation.saveAudio`, else none | yes | the delivery's own banner |
| Text, save failed | none; the text is in `unsavedDictations` | the temporary CAF is kept | yes, as usual | then "History not saved — the text is in the "M" menu" |
| Recording cut off | a line marked `interrupted` (and `recognition_failed` if so), or the unsaved list | the source CAF, byte for byte | never | a failure banner with the reason |
| Recognition failed | a line marked `recognition_failed`, or the unsaved list | the source CAF, byte for byte, whatever the audio switch | none | a failure banner saying where the audio is |
| Empty text | a line with empty text | saved whatever the audio switch | none | the `.noSpeech` notice, or a failure banner if the save failed |
| Esc (`skipsDelivery`) | as usual | as usual | none | a notice naming ⌃⌘V's shortcut when one is set |
| `mic.stop()` returned nothing | — | — | — | nothing |
| `mic.stop()` threw without audio | — | — | — | a failure banner with the error |

A recognition failure sets `modelFailure` only if the model never became `.ready` and the engine selection has not
changed meanwhile; a decode error of a ready model does not blame the model.

When an empty result's save fails, the temporary CAF stays where it is and is not listed among the unsaved.

`lastDictationHitLimit` is set by every stop (true only for a stop at the limit), so the menu's Dictation line says
"the last one stopped at 5 minutes" until the next dictation is stopped; an abandoned start or a discarded short
hold does not clear it. The line shows only while readiness is `.ready`.

`unsavedDictations` is in memory only, newest first; each item keeps the text and the path of its temporary audio
until quit or an explicit Remove in the menu.

## Activation

`HotkeyActivation` has three values, stored in `dictation.hotkey.activation`.

| Activation | How it is heard | What it calls |
|---|---|---|
| `.press` | `KeyboardShortcuts.onKeyDown(for: .dictate)` (Carbon) | `toggle()` on each press |
| `.hold` | the same key-down plus `onKeyUp` | `holdBegan()` / `holdEnded()`, never `toggle()` directly |
| `.doubleModifier` | global and local `NSEvent` monitors, plus the same key-down as a backup shortcut | `toggle()` on a double tap; while recording, on any single completed tap |

The dictation shortcut is registered in every activation. Shortcuts by name (`.dictate`, `.meeting`,
`.pasteLastDictation`, `.copyLastDictation`) follow a change made in Settings at once; the Esc and mark-moment
listeners are opened for a concrete shortcut read at that moment.

**Hold.** `holdBegan` reads the clock first, then calls `toggle()` (so every refusal of a press applies), and keeps
a `Hold` with the start attempt it began. Key repeats and presses while busy are ignored. `holdEnded` counts only
for that very attempt:

- while `.starting`: the start is abandoned ("Released before recording started");
- while `.recording`, at least `minimumHold` (0.5 s) after the key went down: stops as a press would;
- while `.recording`, sooner: a slip — the recording is stopped and deleted, nothing is recognized, saved or pasted.

The 0.5 s run from the key-down, not from the moment recording began.

**Abandoned start** (`abandonStart`, for that release and for Esc): the attempt is invalidated, the watchdog
cancelled, the state becomes `.transcribing` with no job, and a task waits for a `mic.stop()` of its own and then
for the start task itself, whose late success makes a second stop in `captureDidStart` (`releasedStartAttempt`).
Both recordings are deleted. Only then is the coordinator idle again; this wait has no time limit of its own.

**Double-press** (`DoubleModifierReducer`). The modifier is one of right or left ⌘ or ⌥ (`TapModifier`, told apart by
key code); the threshold (`dictation.hotkey.doubleThresholdMS`, 250 ms by default) is measured from the first
key-down to the second. Only complete taps with nothing else pressed count: a key, a mouse button or live scrolling
with the modifier down turns the press into a chord, another modifier blocks it until release, scroll momentum is
ignored. The reducer is reset whenever dictation becomes idle, and while a shortcut recorder in a Murmurly window
is being edited. The monitors need Accessibility but not Input Monitoring.

## Esc

Esc is registered through KeyboardShortcuts (Carbon) as a stream of events for the plain Esc shortcut. While it is
registered, no other app receives Esc, so `escapeCancels` decides when it is open:

| State | Open |
|---|---|
| `.idle`, or quit has begun | no |
| `.starting`, `.recording` | yes |
| `.transcribing` with a job that is not claimed, not already cancelled, and whose snapshot has auto-paste on | yes, through the delivery phase too |
| `.transcribing` otherwise (no job, cancel accepted, auto-paste off) | no |

It is recomputed on every change of `state`, `job` or `hold`; `beginTermination` and the coordinator's `deinit`
close it. While a Hold shortcut is down, Esc is also registered with that shortcut's modifiers
(`HotkeyManager.escapeChord(holding:)`: ⌥Esc for ⌥Space; fn is dropped, as Carbon has no such modifier), because
that is what the keys send; that registration ends with the hold.

What a press does (`escapePressed`): while starting it abandons the start; while recording it stops the dictation
and marks the job `skipsDelivery`; while the job is stopping, recognizing or saving it marks it; during delivery, or
on a job quit has claimed, it does nothing. A marked dictation is recognized and saved as usual and never delivered.

## Delivery

`deliver` runs after the save, for a dictation with text that was neither cut off nor cancelled.

1. Quit accepted or the job taken: nothing.
2. Auto-paste off (`snapshot.autoPaste`): no paste and no clipboard write. A saved dictation gets a notice naming
   ⌃⌘V's shortcut when one is set (a failure-style banner if the limit ended it); an unsaved one gets the caller's
   "History not saved" banner.
3. `focusedFieldIsSecure() == true`: a banner says where the text is; nothing is pasted or put on the clipboard.
4. With Accessibility trust, a target that is not Murmurly, and a successful `activate()`: the front app is polled
   every 20 ms, up to 30 times. Once the target is in front, the password check is asked again and
   `TextInjector.inject` runs inside `deliveringPaste`.
5. `inject` returned true: the insertion sound and "Pasted · N" (or the limit's banner).
   `inject` returned false: "Couldn't paste — the text is in the history"; the clipboard is not used as a fallback.
6. No paste was attempted (no trust, no target, the target is Murmurly, activation failed, or the target was not in
   front within 600 ms): a beep and `TextInjector.placeLocally` — the text stays on the clipboard, with the notice
   "On the clipboard — press ⌘V".

The fallback's notice is a plain one, so it is hidden when the indicator is turned off; the limit's variants and
all failures are failure-style and always show.

### The clipboard

| Function | Used by | Scope | History marks | Stays on the clipboard |
|---|---|---|---|---|
| `inject` | auto-paste, ⌃⌘V | this Mac (`.currentHostOnly`) | `org.nspasteboard.TransientType`, `.AutoGeneratedType` | no: the previous contents come back |
| `placeLocally` | the fallback | this Mac | none | yes |
| `place` | ⌃⌘C, Copy in the menu | ordinary, Universal Clipboard included | none | yes |

`inject`, step by step: take a snapshot of every item and type → clear with `.currentHostOnly` and write the text →
add the two marks (a failure is logged, never stops the paste) → read `changeCount` → post ⌘V → wait 400 ms →
restore the snapshot, again with `.currentHostOnly`, only if `changeCount` is still the one read. A failure before
the ⌘V restores at once and returns false. True means only that the whole chord was posted: AppKit offers no proof
that the target accepted it.

The snapshot reads every type's data on the main actor, skips a type without data, never carries
`com.apple.is-remote-clipboard`, and drops an item with no readable type at all (another device's copy the Mac
never received): that item is gone from this Mac after the dictation. A clipboard that was empty stays empty.

The ⌘V is four events posted to the HID tap (⌘ down, V down, V up, ⌘ up) with explicit flags, by key codes 55 and
9; either all four are created or none is posted.

### Password fields

`AccessibilityAuthorization.focusedFieldIsSecure()` asks the system-wide element for the focused element and
compares its subrole with `AXSecureTextField`. It answers nil — "macOS did not say" — without trust, without a
focused element, on any error and on a timeout, and nil pastes as before. The 0.25 s messaging timeout is set on
the system-wide element, which makes it the process-wide Accessibility timeout; each check makes two calls under
it, and delivery checks twice. Without Accessibility the answer is always nil, so the fallback puts the text on the
clipboard whatever field has the focus. An isolated test process answers nil without asking.

## The last dictation again

⌃⌘V pastes the last dictation where the cursor is now; ⌃⌘C puts it on the ordinary clipboard. The names are
`KeyboardShortcuts.Name.pasteLastDictation` and `.copyLastDictation`, set in Settings → Dictation → Pasting. Both
ignore `dictation.autoPaste`, and a dictation under way refuses both.

"The last one" is looked up at the press (`lookUpLast`): the newer of `historyStore.recent(limit: 1)` and the first
of `unsavedDictations`, the history winning a tie. A read that throws refuses ("Couldn't read Dictations"). One
without text says where its audio is. An interrupted one with text is pasted: the press is the user's own act.

⌃⌘V in time:

1. Key-down: the app in front becomes the target and the lookup starts. A press while a paste runs is skipped; an
   earlier press whose release never came is replaced.
2. Key-up: `runPasteLast` starts; `isPastingLast` is true until it ends.
3. It waits until ⌃, ⌥, ⇧ and ⌘ are all up, polling every 20 ms; after 1.5 s it gives up with "Release the keys to
   paste".
4. From here it is `deliver`'s sequence: the password check, activation and the 600 ms wait, the second check,
   `inject`, the same feedback and the same clipboard fallback. A target that is Murmurly goes to the fallback.

Every refusal is a failure-style or conflict banner. ⌃⌘C's "Copied · N" is a plain notice.

## Readiness

`DictationCoordinator.readiness(modelDownloaded:microphoneGranted:modelState:modelFailure:)` is the one answer to
"will dictation work", used by the menu's Dictation line (`DictationMenuView`) and the Settings footer
(`SettingsWindow.footerText` / `footerColor`, exhaustive `switch`es). It checks in the order the person has to fix
things:

| Check | Result |
|---|---|
| the model is not downloaded | `.needsModel` |
| `modelFailure != nil` | `.modelFailed` |
| the microphone is not granted | `.needsMicrophone` |
| `modelState` is `.loading` / `.waiting` / `.cold` / `.ready` | `.preparing` / `.waitingForEngine` / `.notPrepared` / `.ready` |

Accessibility is not part of it: without it the text goes to the clipboard.

`modelState` is what the engine cache reported to the coordinator's own last request (a warm-up or a dictation).
The cache reports progress only to the caller of a request, so the state is not updated when another job's engine
takes the model's place; the next warm-up or dictation reports again.

The model is warmed (`startModelWarmup`) when the app starts and whenever the engine selection changes, after every
dictation, on `retryModelPreparation()` — which is both "Try Again" and the path after a download
(`ModelDownloader.$installs`) — and on `prepareAfterOtherEngineJob()`, which the meeting queue and Files call after
a job in another engine. It is skipped in a test process, while a warm-up is running and while the model is not on
disk, and it waits while a live transcript holds another engine. A failure sets `modelFailure`, in memory only and
only under the engine selection's current generation, so an older selection's failure never shows on a new one.

## Quit

Quit takes a dictation over from the pipeline through the job's `claimed` mark and saves the raw audio itself
without waiting for the model; a paste already under way is waited for. The whole sequence is in
`reference/quit-and-update.md`.

## Numbers

| What | Value | Where |
|---|---|---|
| Longest dictation | 300 s; countdown for the last 30 s | `maxRecordingSeconds` |
| Start watchdog | 8 s | `startTimeout` |
| Shortest hold | 0.5 s from key-down | `minimumHold` |
| Wait for the target to come to the front | 30 × 20 ms | `deliver`, `runPasteLast` |
| Clipboard restored after ⌘V | 400 ms | `TextInjector.inject` |
| Wait for ⌃⌥⇧⌘ to be released | up to 1.5 s, every 20 ms | `runPasteLast` |
| Accessibility messaging timeout | 0.25 s | `focusedFieldIsSecure` |
| Engine held after a dictation | 30 s | `engineHold` |
| Double-press threshold | 250 ms by default | `SettingsStore.doubleTapThresholdMS` |

## Why it is this way

- **`MicCapture` is an actor** so that `engine.start()`, which can block in Core Audio, never blocks the main actor;
  the 8 s watchdog exists for the same stall.
- **The history is written before delivery**, and audio and line are one store operation, so the text exists
  somewhere durable before anything touches another app, and clearing the history sees a dictation whole or not at
  all.
- **The clipboard and ⌘V, not typed characters:** per-character Unicode events drop Cyrillic in Electron, Qt and
  Java apps. A full chord with real ⌘ key events is accepted by more apps than flags alone.
- **This Mac only.** A normal write when restoring would make Universal Clipboard announce the old contents as the
  newest copy, and a phone would take them over its own. The cost: what was copied on this Mac before a dictation
  no longer reaches other devices after it.
- **The snapshot is read on the main actor** because pasteboard items cannot be carried across a suspension; a very
  large or slow provider can block the interface for that moment.
- **`IsSecureEventInputEnabled` is never asked:** Terminal's Secure Keyboard Entry and password managers turn it on
  for every field, so it would block ordinary pastes.
- **⌃⌘V waits for the modifiers:** a synthetic ⌘V posted while ⌃ is still down would arrive as ⌃⌘V.
- **Esc is registered as narrowly as possible:** a plain Esc registered through Carbon is taken from every app,
  Terminal included, and reaches them again only once it is unregistered. This was checked on real hardware.
- **An abandoned start keeps the coordinator busy:** otherwise a new start could reach the capture first and be
  ended by the late `stop` of the old one.
- **No permission prompt from the shortcut:** an `.accessory` app cannot present prompts reliably, and the hot path
  may hang.
- **Empty text keeps its audio** even with audio saving off: to the person it is a failed recognition, and the line
  would otherwise have nothing to replay.
