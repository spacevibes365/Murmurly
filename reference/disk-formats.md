# Files on disk

Every file the app and the `murmurly` helper write: who writes it, who reads it, how it is versioned and what
a reader does with something it does not know. The types that define these formats live in `Sources/Archive/`
(rule: `.claude/rules/core-archive.md`).

## Where things are

| Place | Holds |
|---|---|
| `~/Library/Application Support/Murmurly/Dictations/` | `history.jsonl` and dictation audio |
| `~/Library/Application Support/Murmurly/Meetings/` | the local meetings root: one folder per meeting |
| the chosen meetings folder (`meeting.storageFolder`) | finished meeting folders the queue moved, same layout |
| the chosen transcripts folder | a copy of each transcript, nothing else |
| `~/Library/Application Support/Murmurly/Models/` | downloaded speech models |
| `~/Library/Logs/Murmurly/` | `murmurly.log`, `murmurly.old.log`, `agents.log` |
| the app's preferences domain | settings, the personal dictionary among them |

A test copy uses a temporary root instead of the first two and of the log: `reference/test-isolation.md`.

## Overview

| File | Written by | Read by | Version | A reader that does not know it |
|---|---|---|---|---|
| `history.jsonl` | `DictationHistoryStore` | the same store (list, menu, last dictation, counts), the helper | `schema_version` in each line; written, not checked | a line that does not decode is skipped and counted |
| dictation audio | `DictationHistoryStore` (`DictationAudioArchive.swift`) | Play and Recognize Again, by `audio_path` | none (container) | a missing file: the line has no audio |
| meeting folder name | `RecordingsStore.createSession` | everything that lists meetings | none | another name is not a meeting |
| `system.caf`, `microphone.caf` / `.m4a` | `SystemAudioCapture`; compression in `MeetingStorage` | transcription, the player, deletion, the audio rule | none | |
| `metadata.json` | the capture's stop, `MeetingRecorder` (`trigger`), compression | the queue, the window, the helper, Storage | none | unknown keys ignored; an unknown `state` is "not finished" |
| `transcript.md`, `transcript N.md` | `MeetingTranscriber` | the window, the helper, export | none | any line out of form: the whole file is shown as plain text |
| `.attempt <n> <UUID>.murmurly.json` | `MeetingTranscriptionQueue` | `MeetingAttempt.entries` (window, helper, audio rule) | `version`, checked | another version or a missing key: "unreadable", its number still counts |
| `murmurly.json` | `MeetingLibrary` | the window, the helper, the audio rule | `version`, checked | unknown keys are kept; a newer version is never written over |
| `.call.murmurly.jsonl` | `CallFeedWatcher` | transcription, the window, the helper | `v` in each line, checked | a line of another version or shape is skipped |
| dictionary document | `SettingsStore` (settings key and exported file) | `SettingsStore` | `version` 1 or 2, checked | another version: kept as it is, nothing applied |
| `murmurly.log` | `AppLog` | no code | none | |
| `agents.log` | the helper (`AgentsLog`) | no code | none | |
| model folders | `ModelDownloader` | the engines, readiness checks | none on disk | a missing required file: "not installed" |

## `history.jsonl`

`Dictations/history.jsonl`: one JSON object per line, UTF-8, each line ended by a line feed. The type is
`DictationHistoryEntry` (`Sources/Archive/Dictations.swift`); keys are written sorted, and the encoder escapes
`/` as `\/`, so parse a line as JSON rather than search its bytes. The folder is created with mode 0700, the
file with 0600.

```json
{"actual_language":"en","at":"2026-03-04T09:20:30.512Z","audio_path":"","duration_seconds":4.2,"engine":"parakeet","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","schema_version":1,"selected_language":"auto","source":"dictation","target_app_name":"Notes","target_bundle_id":"com.apple.Notes","text":"Send the draft on Friday."}
```

| Key | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | integer | yes | `1` |
| `id` | string, UUID | yes | the dictation's identity; never reused |
| `source` | string | yes | `"dictation"` |
| `at` | string | yes | when recording started: ISO 8601, UTC, with fractional seconds (`…T09:20:30.512Z`). A time without the fraction does not decode |
| `duration_seconds` | number | yes | length of the audio |
| `selected_language` | string | yes | the language setting when recording started: `"auto"` or a language code |
| `actual_language` | string | yes | the language the engine reported; empty when nothing was recognized |
| `engine` | string | no | `"parakeet"` or `"whisper"` |
| `target_bundle_id` | string | no | the app that was in front when recording started |
| `target_app_name` | string | no | its name as shown then |
| `audio_path` | string | yes | empty when no audio is kept; else a path relative to `Dictations/`, never absolute |
| `text` | string | yes | the text as delivered, after the personal dictionary; may be empty |
| `raw_text` | string | no | the recognized text before the dictionary; present only when the dictionary changed it |
| `interrupted` | `true` | no | the recording broke off (a device change, a write error) |
| `recognition_failed` | `true` | no | the audio could not be recognized |
| `recognition_skipped` | `true` | no | quit saved the audio without waiting for recognition |

An optional key is left out, never written as `null` or `false`, so an ordinary line is the same bytes as
before the key existed.

**Writing.** A dictation only appends: one `write` of the line to a file opened with `O_APPEND`. If the file's
last byte is not a line feed (a line cut off earlier), one is written first, so the new line is never joined
to it. A line changes only by an explicit action, each of which copies the index into `.history-<UUID>.tmp`,
syncs it and renames it over the original:

| Action | Effect on the file |
|---|---|
| Delete | the line is left out; every other line is copied byte for byte |
| Clear All | the index becomes empty |
| Recognize Again | that line's `text`, `raw_text`, `actual_language` and `engine` are replaced and the two recognition flags dropped; the line is written again from the decoded entry, so keys this build does not know are lost from that one line. Every other line, an unreadable one included, is copied byte for byte |

**Reading.** One decoder everywhere (`DictationHistoryEntry.makeDecoder`). Lists read the file backward in
blocks (`scanBackward`), so the newest line is the last. A last line without a line feed is read like any
other. A line that fails to decode (a missing required key, another type, a time in another form) is skipped:
the app logs it, the helper counts it in `skippedLines`. Extra keys are ignored. No reader looks at
`schema_version`: a line that says 2 is read as this format.

**Search** compares `text` only, case-insensitively, and tells the Russian letters yo and ye apart, unlike
the search over meetings.

## Dictation audio

`Dictations/<yyyy>/<MM>/<uuid>.m4a` or `.caf`: the year and month of `at` in UTC, the id in lower case.
Normally mono 24-bit Apple Lossless at the microphone's own rate; a byte-for-byte CAF when conversion fails or
when the samples do not fit 24-bit, and for a dictation that was interrupted, not recognized or saved by quit.
The file is created empty with mode 0600, filled, and only then is its line appended, so audio can exist
without a line but a line never names audio that was not written. Clear All removes files by this name
pattern (and leftover `.history-<UUID>.tmp`), whatever a line says; deleting one entry removes the file its
`audio_path` names. Moving the whole `Dictations` folder to another Mac needs no rewriting.

## A meeting's folder

```
2026-03-04 10-20-30 Meeting/
  system.caf  microphone.caf        → system.m4a  microphone.m4a after compression
  metadata.json
  transcript.md  transcript 2.md …
  .attempt 0001 <UUID>.murmurly.json
  murmurly.json
  .call.murmurly.jsonl
```

**The name** is `yyyy-MM-dd HH-mm-ss Meeting`, in the Mac's local time when recording started, with `-2`,
`-3`… when the name is taken. It is never translated and the app never renames it. A folder is a meeting for
the window, Storage, the helper and the audio rule when its name has this form
(`MeetingStorage.isMeetingFolderName`) and it holds `metadata.json` or one of the four default track names. The
queue's launch scan goes by a finished `metadata.json` in any visible folder of the local root, whatever its
name. The time in the name is the start when `metadata.json` has none; it is read in the time zone of the
reader.

**Tracks.** `system.caf` and `microphone.caf` are written while recording, on one clock. Compression makes
24-bit ALAC `.m4a` files under `.<name>.partial.m4a`, verifies them sample by sample against the CAF, renames
them, names them in `metadata.json`, and only then removes the CAF. `metadata.json` therefore always names a
whole file; a pair left by a killed step is cleaned by the next pass.

**`metadata.json`** is written atomically, indented, keys sorted (`MeetingMetadata`):

| Key | Meaning |
|---|---|
| `startedAt`, `endedAt` | ISO 8601 strings |
| `sampleRate` | the tracks' rate |
| `state` | `done`, `suspect` or `failed`; never translated. A folder without the file is the recording under way or one cut off |
| `issues` | why it is `suspect` or `failed`, as text in the interface language of that moment; absent when there are none |
| `trigger` | the app an automatic recording started for (bundle identifier, or `pid:<n>`), or `manual`; absent in older recordings |
| `segments[0].system`, `.mic` | the track files' names |
| `segments[0].frames`, `.micFrames` | frames measured in the closed files; absent means not measured |
| `segments[0].enqueuedFrames` | frames handed to the writer, for diagnostics |
| `segments[0].micInputChannels`, `.micRecordedChannel` | the microphone's channels, and the one kept when it had three or more |
| `segments[0].systemGain`, `.micGain` | set by compression when a track was scaled down to fit 24 bits |

It has no version key. Compression edits the object it read and keeps every other key; the stop and the
`trigger` write go through `MeetingMetadata` and write only its keys. Most readers read it loosely (recordings
from before some keys exist); the track names for playback and deletion are read strictly and must be plain
names in the folder.

**Transcripts.** `transcript.md` is version 1 and `transcript N.md` version N. Each run writes to a hidden
`.transcript-<UUID>.tmp` and moves it to the first free name from 1 to 999, never over a file. Readers take
the highest number as the newest. The text is a header, a line `---`, then one paragraph per line:

```
# Meeting <date>

<notes: engine, language, what the labels mean, gaps>

---

[0:07] **Me:** text
[1:02:15] **Others:** text
```

The labels are in the interface language of the run. `MeetingTranscript.parse` accepts the file only if every
non-empty line below the first `---` has that form; otherwise the whole file is "not in the app's form" and is
shown, searched and exported as plain text without times. A transcript is never rewritten: names set later are
laid over it when it is shown. A copy for the transcripts folder is named `<folder name>.md` or
`<folder name> N.md`, written through `.<name>.tmp-<UUID>` and never over a file there.

**Attempt records.** `.attempt <number, four digits> <UUID>.murmurly.json`, one per transcription attempt,
written atomically with sorted keys and ISO 8601 dates (`MeetingAttempt`):

| Key | Meaning |
|---|---|
| `version` | `1` |
| `number` | the attempt's order; the same number is in the file's name, so an unreadable record keeps its place |
| `result` | `inProgress`, `complete`, `incomplete`, `noSpeech`, `failed` |
| `startedAt`, `endedAt` | when the attempt ran |
| `transcript` | the transcript file it wrote |
| `engines`, `languages` | what was actually used |
| `failedChunks`, `cutShort`, `missingTracks` | why a result is `incomplete` |
| `reason` | why it failed, as shown; nothing decides by it |
| `speakers` | the two labels as written in the file |
| `lines` | for each transcript line, in order: `start`, `end`, `source` (`microphone` or `system`); no text |
| `fingerprint` | `bytes` and `sha256` of the transcript file |

The n-th element of `lines` describes the n-th line of the transcript only while the file still matches the
fingerprint and the counts agree; then times are exact and speakers' names can replace the labels. A record of
another version, or one that does not decode, reads as "unreadable": nothing is concluded from it and nobody
rewrites it. A listing may read records without walking `lines` (`MeetingAttempt.Head`).

**`murmurly.json`** (`MeetingMarks`), written atomically, indented, keys sorted:

| Key | Meaning |
|---|---|
| `version` | `1` |
| `title` | the user's name for the meeting |
| `starred` | boolean |
| `speakers` | `{"microphone": …, "system": …}`: names shown instead of the labels |
| `callNames` | a name found in the call window → how to show it |
| `notes` | array of `{"id", "kind": "note"\|"moment", "text", "t"}`; `t` is seconds into the recording, absent for a note without a time |

A write reads the file, checks it, changes that very object and writes it back, so every key this build does
not know survives, at the top level, inside `speakers` and `callNames`, inside a note, and whole elements of
`notes` it cannot read. It writes only over a file proven to be version 1. Without a version, with version 0,
with a value of the wrong type or when it is not a JSON object, the file is "unreadable" and left byte for
byte; a higher version is "written by a newer Murmurly" and left too. A `notes` that is not an array blocks
only note writes. On read, a note that is not well formed is skipped, a time of 100 hours or more reads as no
time, and of two notes with one id the first counts.

**`.call.murmurly.jsonl`** (`CallFeed`): one JSON object per change of the call window, appended as the call
goes, keys sorted:

| Key | Meaning |
|---|---|
| `v` | `1` |
| `t` | seconds of audio already written when this was seen; never decreases |
| `service` | which call service's page it was |
| `visible` | whether any tile was found |
| `self` | the name on the user's own tile, or `null` (always written) |
| `selfSpeaking` | whether that tile was highlighted |
| `people`, `speaking` | the others' names, and those highlighted |
| `selfVisible` | whether the own tile was on screen; absent in older lines |
| `offscreen` | `true` when read through a window not on screen; written only then |

A line that is not valid UTF-8, does not decode, has another `v` or a `t` below the previous one is skipped;
the rest still counts. A missing file is "no feed"; so is one the helper refuses or cannot read, when a
transcript is shown.

**Leftovers the queue cleans.** A move copies to `.<meeting>.partial-<UUID>` in the target and takes the local
folder away as `.<meeting>.removing`; a killed move leaves one of them, and the next pass removes it.

## The personal dictionary

One JSON document, the same bytes under the settings key `dictionary.entries` and in an exported file
(`SettingsStore.encodedDictionary`: indented, keys sorted, slashes not escaped). Its shape, condensed:

```json
{
  "entries" : [
    { "enabled" : true, "heard" : ["cloud code"], "id" : "…", "written" : "Claude Code" }
  ],
  "version" : 1
}
```

`id` and `enabled` are required in every entry. `kind` is written only for a snippet (`"kind": "snippet"`); a
document holds version 1 while it has no snippet and version 2 once it has one, and both are read. A document
of another version, with an entry of an unknown kind or with a broken entry is kept as it is: nothing is
applied and nothing is saved over it until the user clears the dictionary. Saving writes the whole document,
so keys inside a known version that this build does not know are not kept.

## Logs

- `murmurly.log`: `<ISO 8601 time> [LEVEL] category: message`, appended; at launch a log over 5 MB becomes
  `murmurly.old.log`, replacing the earlier one. Lines hold file names and paths.
- `agents.log`: `<ISO 8601 time, local offset> <command> <fields>`, one line per helper call, mode 0600, lines
  older than 30 days dropped at a later write; `agents.log.lock` beside it is the writers' lock. No text of
  the archive, no query, no path.

No code parses either.

## Models

`Models/<repository path>/…`, fetched into `Models/.partial-<UUID>/` and moved into place with one
`rename(2)`. A model is installed when its required files are there; the revision it came from is fixed in
`ModelDownloader` and not recorded on disk.

## How to change a format

- Add a key as optional, and leave it out when it has no value, so files written before stay valid and
  unchanged.
- Where a version is checked (`MeetingAttempt`, `MeetingMarks`, `CallFeed`, the dictionary), a change old
  builds cannot read needs a new version; they then answer "unreadable" or "newer" and leave the file alone.
- `history.jsonl`, `metadata.json` and the transcript have no checked version: an older build reads a new
  file as its own format. Change them only by adding optional keys, and keep the transcript's line form.
- Machine-read values (`state`, `result`, `kind`, `source`, `trigger`) and file names are English and never
  translated.
- The helper, an older installed copy and the user's own scripts read the same folders at the same time.

## Why it is this way

- **Relative `audio_path`.** Moving the whole `Dictations` folder to another disk or Mac is the entire
  migration.
- **Order by number, not by clock.** Two attempts can share a second, and a record that cannot be read must
  still hold its place among the others.
- **No text in attempt records.** The transcript stays the one place the words are; the fingerprint says
  whether record and file still belong together.
- **`murmurly.json` edited as an object.** A later version's keys, or a user's own, must survive a build that
  does not know them; a file that cannot be understood is safer left alone than rewritten.
- **`"self": null` always written** in the call feed, so "no own tile" is told apart from a line that never
  looked for one.
- **Version 1 of the dictionary while there is no snippet.** An earlier release reads version 1 only.
- **The metadata names the m4a before the CAF goes.** Quit may kill compression at any point; every step is
  recovered from the files alone.
