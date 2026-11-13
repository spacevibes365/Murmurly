---
paths:
  - "Sources/MeetingRecorder/CallFeedWatcher.swift"
  - "Sources/Archive/CallFeed.swift"
  - "Tests/MurmurlyTests/CallFeed*Tests.swift"
---

# Call feed and picked names

`CallFeed` (Core layer, `Sources/Archive`, shared with the helper) is the format of `.call.murmurly.jsonl` and the
rule that names a line; `CallFeedWatcher` (Feature layer) writes the file while a meeting records.

- **`CallFeed.swift` builds into the helper: no AppKit, no app types.**
- **Version 1 is on disk in users' meetings.** A new key is optional and written only when it says something
  (`offscreen` only when true), `"self": null` is always written, and a line of another `v` is skipped, never
  refused. A required key removed makes this version's readers skip every line.
- **`t` is the capture's `writtenSeconds()`, read after the snapshot answers,** the scale of
  `MeetingAttempt.Line.start`/`end`. Without that clock no line is written; never the wall clock.
- **Only changes are written, and nothing until the page was found once:** a meeting without a call page leaves
  no file.
- **`.skipped` writes nothing:** no line, no state change, not even the clock.
- **`finish()` runs before `capture.stop()`, sets `closed` before its one `await`, and never waits for a read
  under way.** It appends a closing `visible: false` line, or the last speaker keeps speaking to the end of the
  recording.
- **The events in memory (`events()`) are the live transcript's only source.** They are kept when the file cannot
  be opened or written; never reopen the file or poll the page a second time for them.
- **Open the file `0600` with `O_NOFOLLOW` and `O_CLOEXEC`, appending:** it holds other people's names.
- **Logs carry counts and error texts, never names.**
- **Pin only from a confirmed find (`event.visible`);** afterwards only the pin's `remoteWindow` follows the
  reads.
- **Names are cleaned on both ways in** (`Event.cleanedName`: one line, no `*`): a name becomes a transcript
  line's `**label:**`.
- **`pickedNames` is the one rule for a name** — the meeting job's gluing, the shown transcript, the helper and the
  live text all call it. It answers one name or nil per line, in the lines' order.
- **Better no name than a wrong one.** Keep the thresholds (`dominantShare`, `dominantMargin`, the single-other
  conditions) and the half-open spans: an event exactly at a line's `end` belongs to the next line.
- **Keep the whole-feed work to one pass before the lines are walked;** a feed runs to tens of thousands of
  events and a transcript to thousands of lines.

How it works: `reference/live-transcript-and-call-window.md`.
