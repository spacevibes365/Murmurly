# Live transcript, the call window and speakers' names

What runs beside a recording while a meeting is under way: the live transcript shown in the notepad, the reader of
the call's window, the feed it writes, and the rule that turns the feed into a name for a line. The rules that
must not be broken are in `.claude/rules/live-transcript.md`, `.claude/rules/call-window.md` and
`.claude/rules/call-feed.md`. The capture and the recorder are in `reference/meeting-recording.md`.

## Parts

| Type | Isolation | Role |
|---|---|---|
| `LiveTranscript` | actor, one per recording | reads the live-audio ring, cuts speech into chunks, recognizes them, builds lines |
| `LiveTranscriptModel` | main actor, one per recording | `lines`, `state`, `hasEarlierLines` for the notepad |
| `MeetingPageReader` | static functions on one serial queue | one read of the call window: who is there, who is highlighted |
| `AXPageNode` | value over one `AXUIElement` | the live `AccessibilityPageNode`; tests use synthetic nodes |
| `CallFeedWatcher` | actor, one per recording | polls the reader, writes `.call.murmurly.jsonl`, keeps the events in memory |
| `CallFeed` | pure, in `Sources/Archive` | the file's format, `pickedNames`, `summary` |

`MeetingRecorder` creates all of it in the start task, after `state = .recording`, and ends all of it in
`beginStop` before `capture.stop()`. Two settings, both on by default and both read as a recording starts:
`meeting.liveTranscript` and `meeting.namesFromCallWindow` (the watcher reads the second again on every loop).

## Live transcript: from the ring to chunks

`startLiveTranscript` runs only when the recorder was given a `LiveTranscription` configuration (the app's
recorder; the quit probe's and most tests' have none). If the engine's model is missing the model shows `.noModel`
and no pipeline is built. Otherwise the Silero VAD and the meetings' dictionary replacer are prepared in a
detached task; if that fails the model shows `.stopped(reason)`. After the wait the recorder checks again, with no
`await` in between, that the task is not cancelled and the same recording is still `.recording`, and only then
keeps the pipeline and sets `liveTranscriptEngine`.

The pipeline has two tasks. The ingest task calls `capture.liveAudio()` every 250 ms and takes every snapshot
there is; it never waits for the recognition task.

1. **Break check.** A snapshot with `dropped > 0`, a `firstFrame` that is not where the last snapshot ended, a
   changed sample rate or channel count, or a malformed snapshot resets both lanes, the converters, the echo
   buffers and the echo canceller, and sets a new `origin`. An open chunk is lost with the reset.
2. **Conversion.** Each track goes through its own streaming `AVAudioConverter` to 16 kHz mono Float32 (a stereo
   microphone is mixed down by the converter).
3. **Echo.** The microphone is cleaned against the system track with AEC3 (`EchoCanceller`), the same canceller
   the meeting job uses. If creating or running it fails, the raw microphone is used for the rest of the meeting.
4. **Speech detection.** Each track is cut by Silero's streaming probability, in blocks of `VadManager.chunkSize`
   (4096 samples, 0.256 s). If the detector throws for a track, that track gives no more chunks for the rest of
   the meeting; the error is logged.
5. **Queue.** Closed chunks wait in a queue of 8; a ninth drops the oldest and counts it (`skippedChunks`).

The cutting rule (`cut`):

| Event | Rule |
|---|---|
| A chunk opens | a block at or above 0.85 |
| Speech continues | while open, a block at or above 0.70 moves the accepted end of speech |
| A chunk closes | two blocks in a row below 0.70 |
| Hard cut | before a block would take the open chunk past 15 s (58 blocks, 14.85 s); a block at or above 0.70 opens the next chunk at once |
| Padding | up to 0.1 s of the quiet audio before the chunk and 0.1 s after the accepted end; none before a chunk that opens right where the previous one closed or was cut |
| Too short | speech under `MeetingTranscriber.minimumChunkSamples` (0.3 s) is dropped |

A chunk's `start` and `end` are recording seconds: `origin` plus the 16 kHz index converted to recording frames,
divided by the recording's rate. Its `number` is unique for the whole meeting.

## Live transcript: recognition and lines

The recognition task takes one chunk at a time, final chunks first:

- The chunk is written to `chunk.caf` in a fresh folder under `temporaryRoot` (removed whatever happens) and
  sent to `WhisperKitCache` with the engine and request taken at the start. While the cache reports `.loading` or
  `.waiting` (a load, or a turn behind another request) the model's state is `.preparingModel`.
- On Whisper with the language on Auto, the language is fixed by the first final chunk longer than
  `MeetingTranscriber.languageFixSeconds` (5 s) that had words, as in the meeting job.
- A result without words (`normalizedWords` empty) makes no line.
- Three failed final chunks in a row end recognition with `.stopped(reason)`. The ingest task and the engine
  hold go on until the recording stops; a failed interim request counts for nothing.
- **Interim requests.** Only while the queue is empty: a track's open chunk is recognized again once it holds at
  least 1 s of speech and has gained at least 1 s since its last interim. When both tracks qualify they take
  turns. A result for a chunk that is no longer the track's open one is dropped. With nothing to do the task
  sleeps 100 ms.

Final lines are kept with the engine's raw text (`RawLine`). On every final result (`recompute`):

- The window is the 120 s before the latest line's end. Lines that fall behind it are frozen: their text, name
  and echo decision never change again.
- Echo: every microphone line that is neither frozen nor hidden is checked with `MeetingTranscriber.removingEcho`
  against all system lines still kept. A line hidden once stays hidden.
- The dictionary for meetings and `CallFeed.pickedNames` (over the watcher's events in memory) are applied to the
  lines in the window.
- A frozen line more than 15 s behind the window is dropped if it is hidden; a visible one is dropped only while
  there are more than `LiveTranscriptModel.maximumLines` (5000) visible lines, and then `hasEarlierLines` is set.

Interim lines are never stored: at each publication each track's interim is put through the same echo,
dictionary and name steps (the microphone's interim also against the system's interim) and appended after the
final lines, system first. Every publication replaces `LiveTranscriptModel.lines` whole. Final lines stand in the
order their chunks were recognized, which follows the order the chunks closed, not strictly `start`.

`LiveLine`: `id`, `track`, `start`, `end`, `rawText`, `displayText`, `name`, `isFinal`.

| `LiveTranscriptModel.State` | Meaning |
|---|---|
| `waitingForSpeech` | no chunk taken yet |
| `preparingModel` | no request has completed a model load yet, or the cache reported `.loading` / `.waiting` |
| `running` | chunks are recognized as they come |
| `lagging` | three or more chunks wait |
| `skipped(n)` | the queue has dropped `n` chunks; stays until the stop |
| `stopped(reason)` | preparation failed, or three final chunks in a row failed |
| `noModel` | the engine's model is not downloaded |

## Live transcript: the stop and the engine hold

`beginStop` first copies `model.lines` into `MeetingRecorder.stoppedLiveTranscript` (so the notepad stays on the
meeting; an interim line is copied as it is, `isFinal == false`), then drops the model and takes the pipeline.
`LiveTranscript.finish()` sets `finished`, cancels both tasks, waits for the ingest task, runs the converters'
tails through the echo canceller and the detector and closes the open chunks. It does not wait for a request or a
model load, and nothing is published after it. Words still in the queue at the stop appear only in the
transcript made after the stop.

`MeetingRecorder.liveTranscriptEngine` is set when the pipeline is kept and cleared in `takeLiveTranscript()`.
While it is set, work in another engine waits: the meeting queue and Files (`heldByLiveTranscript`, checked
before each chunk), the dictation's warm-up and Recognize Again (polled every 250 ms). Turning
`meeting.liveTranscript` off mid-meeting hides the notepad's panel but leaves the pipeline and the hold until the
stop.

Nothing of the live text is written into the meeting's folder.

## Call window: what is read

`MeetingPageReader.readLive(holders:pin:limits:)` is one read. It answers `.notFound` at once in a test process,
without Accessibility trust, or when no row of the table runs in an app that holds the microphone. Otherwise the
whole read runs on the reader's own serial queue.

**Whose windows.** The recorder passes the bundle IDs of the processes holding audio input
(`MeetingWatchdog.readHolderBundleIDs`, the watchdog's own filter). `mainApp(ofHolder:)` maps a Chromium helper
to its browser and a `<bundleID>.helper…` process to its program; a bare `com.apple.WebKit.*` process is mapped
to nothing, so a Safari tab is read only if Core Audio names Safari itself. Once a pin is set, holders are not
consulted: only the pinned row in the pinned app is read.

**The table** (`services`). A row's `place` is `.browser(meetingAreas:shells:)` (a tab in one of
`browserBundleIDs`: Arc, Chrome, Yandex Browser, Edge, Brave, Safari), `.app(bundleID:windowIdentifier:)` (a
native window found by `AXIdentifier`) or `.appWeb(bundleID:meetingAreas:)` (a page embedded in a program).

| `id` | Place | Read by |
|---|---|---|
| `telemost` | browser, `telemost.yandex.ru` | classes (prefix match) |
| `jitsi` | browser, `meet.jit.si`, `8x8.vc`, `meet.ffmuc.net` | classes |
| `bitrix24` | browser, any page of a cloud portal (`bitrix24CloudDomains`) | classes |
| `bitrix24` | program `com.bitrixsoft.bitrix24desktop`, any embedded page | classes |
| `zoom` | program `us.zoom.xos`, window `zm.meeting.window.main` | captions |
| `zoom` | browser, `zoom.us/wc/` | classes; one tile, no own tile, never a highlight |
| `meet` | browser, `meet.google.com` | classes |
| `telemost-app` | program `ru.yandex.desktop.telemost`, embedded page | classes (prefix match) |

`unconfirmedServices` (Microsoft Teams, tab and program) is kept beside the table and is not read by
`readLive`. Several rows carry comments in the code saying their classes were taken from other projects or not
yet seen on a live call.

**Finding the meeting.** The app's windows come from `kAXWindowsAttribute`. A top-level window whose
`AXIdentifier` matches an `.app` row is a candidate. Otherwise the tree is walked for `AXWebArea` nodes whose
`AXURL` matches a row's `Address` (host equal to a domain or a subdomain of it, path starting with the prefix);
a `shells` address is only descended through. A matched area is not walked further at this stage. Each candidate
has an identity (`Meeting`): a page's normalized address (scheme, host, path, plus only the query keys a row
names in `meetingQueryKeys`), or a native window's identifier, title and the window object itself, compared with
`CFEqual`.

**Reading tiles.**

- *By classes* (`AXDOMClassList`): the grid (`gridClass`, or the whole area when empty), then nodes carrying a
  tile class and `tileDevicesClass`. A screen-share tile (`tileDisplayClass`) is not opened. Inside a tile:
  `selfClass` or `selfTileIdentifier` marks the user's own tile, `speakingClass` the highlight (cleared by
  `silenceClass`), and the name is the text of the `nameClass` node (title, else value, else description) or,
  when it has none and the row allows, of the first `AXStaticText` below it. A tile without a name is not a
  person.
- *By captions* (`captionRules`, the Zoom program): nodes with the tile role, whose description is parsed from
  its end: a speaking marker, exactly `statusCount` known status phrases and any optional ones are stripped,
  and what is left is the name; a description with fewer known statuses is not a person. The user's own name
  is a row of the participants list ending with the self suffix (`" (me)"`), accepted only when it equals a
  tile's name. The phrases of every language the installed Zoom ships are read from its bundle
  (`addingInstalledZoomCaptions`), files only, and only when the Zoom program is the read's target.

**Choosing.** Without a pin, every candidate's tiles are read from the one shared budget, and the read succeeds
only when exactly one candidate has a confirmed tile (`visible`) and a known identity. With a pin, exactly one
candidate must equal the pinned meeting.

## Call window: budget, answers, other Spaces

One read has one `Budget` (`Limits.standard`): 5000 nodes, depth 40, a deadline 5 s after the call. It is checked
before every node; each element also has a 0.25 s messaging timeout, and an attribute that fails or times out
reads as nil or empty.

| `MeetingPageSnapshot` | Means | The watcher |
|---|---|---|
| `found`, `visible` | the meeting's area and at least one tile; names complete | writes a line if it changed; pins on the first one |
| `found`, not `visible` (only with a pin) | the pinned area with no tile, or its tile read cut short by the budget (every other field dropped) | writes a line with no names if it changed |
| `.notFound` | no target, no candidate, an ambiguous choice, a walk of the listed windows cut short by the budget, or, before a pin, a tile read cut short | after the page was found once: writes a "nobody" line |
| `deferred` | a hidden-window scan was not run this time, or its scan or walk was cut short by the deadline | skips the read entirely |

A window on another Space is not in the app's `kAXWindowsAttribute`. When the listed windows
hold no confirmed meeting (or, with a pin, no match), `HiddenWindows.live` is used:

- `_AXUIElementCreateWithRemoteToken` and `_AXUIElementGetWindow` are looked up once with `dlsym`. Without the
  first the answer is `.unavailable` and the read ends as `.notFound`.
- With a pin, the remembered window (`Pin.remoteWindow`: pid and element number) is reopened first, one token and
  no scan.
- A scan builds tokens for element numbers 0…999 of each process of the app, keeps those that are windows and
  are not in the public list, and runs at most once every 5 s per app; in between it answers `.deferred`.
- A meeting found this way is `offscreen`, and its `remoteWindow` is returned for the pin. A meeting found in a
  listed window is `offscreen` when `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` does not show that window.

What leaves the reader: the row's `id`, the app's bundle ID, names, the flags, the meeting's identity and the
window token. Only the `id`, names and flags reach the feed file; the address stays in the pin, in memory. The
reader itself logs nothing, and never writes an attribute or performs an action.

## The call feed

`CallFeedWatcher.run()` loops until closed: check `meeting.namesFromCallWindow` (off ends the watcher for the
rest of the meeting, as `finish()` does), read once, then sleep `callFeedInterval` (300 ms). The period is
therefore the read's own time plus 300 ms, and reads never overlap.

- Before a pin, an unreadable holder list makes the read `.skipped`.
- After a read answers, `writtenSeconds()` is taken as the line's `t`; without it no line is written.
- Nothing is written until the page was found once. From then on a read that finds nothing becomes a line with
  `visible: false` and no names, under the last line's `service`.
- A line equal to the last one, `t` aside, is not written.
- The pin is set by the first read with `visible`; later reads only carry `remoteWindow` forward.
- Every accepted event is appended to `writtenEvents` (what `events()` returns) before the file is touched. The
  file is opened on the first line, mode `0600`, `O_APPEND | O_NOFOLLOW | O_CLOEXEC`; a failed open or write turns
  the file off for the rest of the meeting while the events in memory go on.
- `finish()` sets `closed`, cancels the loop without waiting for a read under way, appends a closing
  `visible: false` line (at `writtenSeconds()`, or the last known clock) if anything was ever written, closes
  the file and logs the counts: snapshots, changes, skipped reads, whether the page was found, off-screen reads
  and highlight changes seen between two off-screen reads.

`.call.murmurly.jsonl` holds one JSON object per line, keys sorted:

| Key | Type | Notes |
|---|---|---|
| `v` | int | `1`; a line of another version is skipped by readers |
| `t` | number | recording seconds; readers skip a line whose `t` is not finite, negative or less than the previous |
| `service` | string | the row's `id` |
| `visible` | bool | whether any tile was found |
| `self` | string or null | the name on the user's own tile; always written |
| `selfSpeaking` | bool | written; not used by `pickedNames` |
| `people` | [string] | other people's names, no repeats |
| `speaking` | [string] | those highlighted now |
| `selfVisible` | bool, optional | whether the own tile was seen; absent from older lines |
| `offscreen` | bool, optional | written only when true |

A damaged line (a process killed mid-write, invalid UTF-8) costs only that line. `CallFeed.read(in:links:)`
answers nil for a missing file and throws for one that cannot be read. `MeetingStorage.isOwnFile` counts the
feed among the app's own files in a meeting's folder.

## Picking a name for a line

`CallFeed.pickedNames(for:feed:leads:)` takes the lines' spans and sources (`MeetingAttempt.Line`) and answers
one name or nil per line. The feed is sorted once (stably, by `t`) and turned into intervals; each line then
looks only at the intervals its span touches. Spans are half-open: an event exactly at a line's `end` belongs to
the next line. A line with no positive, finite span gets nil.

**A microphone line** gets the last own-tile name (`self`) seen strictly before its end.

**A system line:**

1. *Credit.* Among the highlighted names, the one that lit up last holds the credit; when it goes dark and an
   earlier one is still lit, the credit returns to that one. Names that lit up in the same event share the
   credit in full, so neither clears the margin below. A line with `visible: false` credits nobody.
2. *Lead.* A name that has just lit up is credited from a little before its event, by service
   (`highlightLeads`: `jitsi` 0.5 s, `zoom` 1.2 s, others 0), never before the previous event and never across a
   hidden stretch.
3. *Off screen.* A highlight read `offscreen` is credited for at most 10 s (`offscreenHighlightLimit`) after the
   `speaking` set last changed.
4. *The single other person.* If, for the whole line, the feed shows exactly one other tile, the own tile is
   confirmed (seen, or the line has no `selfVisible` key, as lines written before it existed) and that name is
   the only other name the whole feed ever showed on a visible tile, the line gets that name without any
   highlight.
5. *The dominant speaker.* Otherwise the most credited name wins if it holds at least 60 % of the line
   (`dominantShare`) and at least twice the next name's time (`dominantMargin`). Hidden time counts against the
   60 %.
6. *The opening is unknown, not hidden.* If the line starts before the feed first saw the call with people in it,
   and what remains after that moment is at least 2 s and at least 40 % of the line, the share and the margin
   are measured on that remainder alone.

`CallFeed.summary(for:feed:)` adds, for the Names sheet and the card, every name the feed ever showed and whether
a tile was ever found.

Who calls it:

| Caller | Use |
|---|---|
| `MeetingTranscriber.merged` | the feed is read once per job, before the first chunk; two neighbouring system chunks with different picked names are never glued into one line |
| `MeetingLibrary` and the helper (`CallFeed.summary`) | the shown transcript's names, through `MeetingTranscript.named(by:call:)` |
| `LiveTranscript` | names for the lines in the window and for interim lines, from the watcher's events in memory |

When a transcript is shown, a microphone name typed in the Names sheet wins over the picked one; for a system
line the picked name (renamed through `callNames` in the meeting's marks) wins over the sheet's system name, and
the track's label is last.

## Numbers

| What | Value |
|---|---|
| Ring poll | 250 ms |
| VAD block | 4096 samples at 16 kHz (0.256 s) |
| Open / stay-open thresholds | 0.85 / 0.70 |
| Close after | 2 blocks below the lower threshold |
| Longest chunk | 15 s |
| Padding | 0.1 s |
| Shortest speech | 0.3 s |
| Chunk queue | 8 |
| Interim step | 1 s of new speech |
| Recompute window | 120 s (plus 15 s kept for echo matching) |
| Lines kept | 5000 |
| Pause between page reads | 300 ms |
| Read budget | 5000 nodes, depth 40, 5 s |
| Accessibility messaging timeout | 0.25 s per element |
| Hidden-window scan | element numbers 0…999, at most every 5 s per app |
| Off-screen highlight | 10 s |
| Name thresholds | 60 %, ×2; remainder 2 s and 40 % |

## Why it is this way

- **The thresholds are not tuned here.** 0.85 is FluidAudio's `VadConfig.default.defaultThreshold` and 0.70 its
  derived exit threshold; 0.3 s is `ASRConstants`' minimum. With them the live text was measured against the
  transcription after the stop on synthetic meetings: 3.16 % word errors against 3.27 %, with text about 0.7 s
  after a phrase ends. The package is pinned, so its defaults change only with the pin.
- **The cutting is the pipeline's own rule,** not FluidAudio's segmentation: the meeting job cuts a finished
  file, the live path must decide block by block. The other pieces are shared with the meeting job so both paths
  agree on what is a word, an echo and too short a chunk.
- **Ingestion never waits for the engine** because the ring holds only 30 s; a reader stalled behind a model
  load would lose audio for the live text. A bounded queue that drops the oldest chunk loses a phrase instead.
- **The stop does not wait for recognition** so that a hung engine can never hold a recording's stop or the quit
  behind it. The price is the unfinished tail in the notepad after a stop.
- **Echo is matched beyond the window** because a chunk may be 15 s long: a system line can start well before
  the microphone line it overlaps leaves the window.
- **The engine is held for the whole meeting:** the cache keeps one loaded engine, and another engine's work in
  between would make every live chunk load its model back.
- **The reader is tied to the microphone's holder** so that an open tab of a call service that is not in use can
  neither be read by mistake nor spend the budget.
- **A partial read reports nothing** because a name or a highlight from half a grid may belong to another tile,
  and an unwalked window may hold a second area of the same or another meeting.
- **Windows on other Spaces are reached through remote tokens,** the approach window switchers use, because
  `kAXWindowsAttribute` lists only the current Space. A page there may stop updating, which is why an off-screen
  highlight expires and why the stop logs how many off-screen reads there were and how many highlight changes
  they saw.
- **The scan is limited to once in 5 s** because it costs up to a thousand round trips to the other process, and
  most reads need none: the remembered window is reopened with one.
- **Highlight leads are per service** because each service lights its highlight some time after speech starts:
  Jitsi's was measured at 0.42–0.74 s (0.5 s stays under the maximum), Zoom's at about 1.2 s.
- **Simultaneous highlights share the credit in full** because crediting one of them by any tie-break let either
  cross both thresholds by chance, differently between runs.
- **The single-other rule needs the whole feed to agree** because a pinned video, a screen share or a gallery
  not fully shown can leave one tile on screen in a call of several people.
- **The feed's clock is the tracks' clock** so that its events and the transcript's lines are on one scale even
  when a headset drops out and the wall clock runs ahead of the files.
- **The closing line exists** because without it the last highlighted person would keep speaking from the last
  event to the end of the recording.
