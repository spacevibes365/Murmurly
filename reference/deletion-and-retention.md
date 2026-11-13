# Deleting a meeting or its audio, and old meeting audio

Two ways a meeting's files leave its folder on purpose: the user deletes a meeting or its audio in the main
window (to the Trash), and the audio rule deletes old audio (for good). Both end in
`MeetingStorage.Removal.perform`. The rules that must hold are in `.claude/rules/deletion-retention.md`.

| Part | Where |
|---|---|
| Strict reading (`Address`, `entry`, `audio`, `manifest`), `audioRetention(of:)`, `Removal` | `Sources/MeetingRecorder/MeetingStorage.swift`, from "What may be removed, read strictly" |
| The window's deletion (`removalPlan`, `remove`, `checked`, `carryOut`, `carriedOut`) | `Sources/MeetingRecorder/MeetingLibrary.swift`, "Deletion" |
| The audio rule's question, pass and job step; `reserve`, `operations` | `Sources/MeetingRecorder/MeetingTranscription.swift`, "Old audio" and "Operations" |
| The setting (`MeetingAudioRetention`, `retentionGeneration`) | `Sources/SettingsStore.swift` |
| The sheets (`RemovalSheet`, `AudioRuleQuestion`) | `Sources/MainWindow/MeetingsView.swift`, `Sources/Settings/MeetingsSettingsView.swift` |

Other code removes files of a meeting's folder as part of its own protocol and does not go through `Removal`:
compression removes a CAF once its m4a is committed, the move removes the local folder once its copy is in
place, a scan removes a killed move's leftovers, a cancelled transcription removes its attempt record
(`reference/meeting-transcription.md`).

## Reading strictly

Everything a deletion acts on is read by `lstat`, never through a link, and an error is "unknown", never "not
there". The window's own listing reads loosely; only what is read here is deleted.

| Function | Answer |
|---|---|
| `MeetingStorage.address(of:)` | `Address(identity, path)`: the folder itself (`FolderIdentity`, volume and file number) and its path with links resolved in the parent. `identity` nil is "proven absent"; a nil result is "unknown" (a link, a file, an error) |
| `entry(_:in:)` | `.file(FileFact)` (name, device, inode, size), `.absent` (only `ENOENT`), or `.unknown(reason)` |
| `audio(in:requiringMetadata:)` | the tracks `metadata.json` names (plain names in the folder, `isPlainTrackName`; the default `system.caf` / `microphone.caf` where it names none), each as `<stem>.caf`, `<stem>.m4a` and `.<stem>.partial.m4a`; `.unknown` if anything cannot be read or a name leads outside the folder |
| `manifest(of:)` | every entry at the top of the folder as a `FileFact`; refused when one is a folder, a link or unreadable |
| `Manifest.matches` | the same folder and the same files; Finder's own (`isSystemFile`: `.DS_Store`, `._*`, `Icon\r`) are left out of the comparison |
| `FolderIdentity.reach` | what a setting's path leads to, its last link followed; used only to tell whether a folder is that one |

## Deleting by hand

From a row's menu, the card's Delete menu, the card of several selected meetings and ⌘⌫ in the list. Two kinds:

- **Delete Audio…** takes `audio(in:requiringMetadata: true)`. A recording without `metadata.json` (one that
  broke off) has no audio to name and goes only whole. The call feed, transcripts, records and marks stay.
- **Delete Meeting…** takes the manifest: every file at the top of the folder, files that are not the app's own
  included (the sheet lists them as "Also deleted").

### The flow

1. **The sheet** (`removalPlan`). For each meeting `removalRefusal` answers from what the window knows: the
   folder unreadable or not named as a meeting's, the recording under way or just stopped, an operation of the
   queue, the active job, a waiting transcription (or one whose folder is not known yet,
   `untoldTranscription`), marks not on disk yet, a listing that is unavailable; for a whole meeting, a folder
   that is the transcripts folder or a refused manifest; for audio, no metadata or no audio. Those that can go
   are listed with their sizes, the others with the reason.
2. **Read again** (`remove`). On the serial queue of the folder's parent: the address, and the audio or the
   manifest as they are now.
3. **Compared** (`checked`, main actor). Another folder at the address, or other files than the sheet showed
   (`sameTarget`), puts the meeting into `removalRecheck`: a new sheet with what is there now. Nothing is
   deleted on the earlier answer.
4. **Admitted**, in the same turn: `removalRefusal` again, then `MeetingTranscriptionQueue.reserve`. The
   reservation is a `.removing` operation: no job is queued or started for the folder, its marks, moves and
   audio are refused, and its waiting jobs that do not transcribe are dropped.
5. **Carried out** (`carryOut`, the folder's queue), one `Removal.perform` at a time.
   - Audio: file by file; the first that does not go stops the rest, and the report says what went and what
     is left.
   - A whole meeting: the transcripts folder the setting names is resolved first (`copiesCheck` through
     `Reader.copiesFolder`); a folder that is it, or one that cannot be told, refuses. Then `perform`, whose
     `stillWanted` only compares the setting with the one resolved. A setting changed meanwhile repeats the
     whole admission, three times at most, then refuses.
6. **Reported** (`carriedOut`). The operation ends, `removalReport` gets a line, and after `.trashed` or
   `.stopped` the menu forgets the folder (`MeetingRecorder.forget`, `MeetingTranscriptionQueue.forget`) under
   every address it pointed to it by; once every meeting of the confirmation is settled the listing is read
   again.

### `Removal.perform`

One call for one file or one folder:

1. `FolderIdentity.of(folder)` equals the identity that was confirmed.
2. A file: `entry` gives the same `FileFact` (name, device, inode, size). A folder: its manifest read now
   matches the confirmed one.
3. `stillWanted()` returns nil. It runs after the last read of the disk.
4. `trash` or `remove`, by `forGood`.

Failures: `.changed` (not what was confirmed), `.stale` (no longer wanted), `.noTrash`
(`CocoaError.featureUnsupported` from the Trash call), `.failed`. On a volume without a Trash nothing is
deleted and the folder is shown in Finder (`reveal`), also when part of the audio already went.

`Removal.live` is the disk's own calls (`FileManager.trashItem`, `removeItem`). What a test process gets
instead is described in `reference/test-isolation.md`.

## The audio rule

Settings → Meetings, `meeting.audioRetentionDays`, `MeetingAudioRetention`: `keep` (0, the default), or 7, 30 or
90 days after the end of the first complete transcription. A stored value that is none of the four reads as
`keep`. The rule covers every meeting in the local root and in the chosen meetings folder.

### What may go (`MeetingStorage.audioRetention(of:)`)

`.eligible(since:files:)` only when all of this is read and holds; anything else is `.kept(reason)`, or
`.unknown(reason)` when it could not be read:

- the folder is named as a meeting's and can be read;
- `metadata.json` is there and its `state` is `done`;
- `murmurly.json` is absent, or readable and not starred;
- there is at least one attempt record, no two share a number, every one is a plain file and readable;
- the last attempt is `complete`;
- the last one and the first `complete` one are consistent (`isConsistentComplete`: a transcript name and a
  fingerprint, an end not before its start, no failed chunk, not cut short, no missing track);
- the last attempt's transcript is in the folder with the recorded size and SHA-256;
- `audio(in:)` is known and not empty.

`since` is the `endedAt` of the first complete attempt; `Retention.due(days:now:)` gives the files once that
many days have passed. The card shows the date or the reason (`MeetingText.retentionNote`).

### Setting the rule

`keep` is written at once. A number of days is asked about first (`askAudioRetention`): each root is counted
on a queue of its own (`due(in:local:days:now:)`), waited for at most 3 s. The question (`AudioQuestion`)
carries the meetings that would go now, each with its `FolderIdentity` and size, whether the count is complete,
and the `retentionGeneration` it was made under; the sheet shows their number and total size. The count is
incomplete when a root is away, cannot be listed, did not answer in time or is still being counted from an
earlier request, or a meeting's facts are `.unknown`.

`answerAudioQuestion` writes the rule only on a yes, and only if the generation is still the one counted
under; otherwise it counts and asks again. Then it restarts the daily timer and runs the first pass over the
counted meetings only (`pruneAudio(only:)`).

`SettingsStore.retentionGeneration` is in memory and rises with every change of the rule and of the meetings
folder.

### The pass and the step

`pruneAudio` runs at `activate`, after a yes, and every 86 400 s of the app running (`restartRetentionTimer`).
It counts without a time limit, drops everything if the generation changed meanwhile, and gives each due
meeting to the queue (`enqueueAudioRemoval`): a job with `removesAudio` (`AudioRemoval`: the generation and the
folder's identity), or that step added to a job of the folder already waiting.

The step (`removeOldAudio`) runs in the job after the transcription and its copy and before compression:

1. `stillWanted`: the rule is not `keep` and the generation is the job's.
2. The folder at the job's address is the one counted (`activeAddress.identity == removal.identity`).
3. If a transcription waits that is of this folder, or whose folder is not known yet, the step is handed to
   the last of them and this job leaves the audio.
4. No marks are being written, and `beginOperations(.removingAudio)` takes the folder.
5. Off the main actor (`removeAudio`): for each file, `audioRetention(of:)` is read again and must still name
   that file as due; then `perform(.file, forGood: true)` with a `stillWanted` that asks the main actor for
   the rule, the generation, marks being written and a transcription asked for meanwhile. The first file not
   admitted stops the rest.

The outcome goes to the log ("old audio: removed …", "stopped before …").

Settings → Storage shows the meeting audio's size and how many meetings have none left.

## Why it is this way

- **`lstat` and "unknown".** A link is never followed and an error is never taken for absence: either could
  point a deletion at something that was not confirmed, or pass a missing proof for a met condition.
- **Finder's files are left out of the comparison.** Finder rewrites `.DS_Store` while the folder is open, and
  volumes add `._*` files of their own.
- **A root is empty only when proven absent.** `MeetingStorage.meetingFolders` throws for a root behind a
  parent that cannot be passed; an unreadable root must not look like a root with nothing to keep.
- **The transcripts folder is resolved before the last check, not inside it.** A network volume may take long
  to say what a path leads to; the last check must wait for no disk.
- **The question comes before the rule is written** because the first pass deletes for good at once.
- **The step goes after every transcription** so that the rule looks at what they left: a new attempt that is
  not complete keeps the audio.
- **A job without a known folder holds deletions back**: until its folder is read it may be any folder.
