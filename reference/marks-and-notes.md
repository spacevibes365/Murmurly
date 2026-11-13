# A meeting's marks and notes (`murmurly.json`)

A meeting's own name, its star, its speakers' names and its notepad's notes live in one file in the meeting's
folder, so they go wherever the meeting goes. This file explains the format and the writer; the rules that must
hold are in `.claude/rules/marks.md`.

| Part | Where |
|---|---|
| `MeetingMarks`, `MeetingNote` (the types and the reading), `FolderIdentity` | `Sources/Archive/MeetingFiles.swift` |
| `MeetingMarks.Change`, `NoteOperation`, `MeetingMarks.write` | `Sources/MeetingRecorder/MeetingStorage.swift`, the last extension |
| The writer (`Marks`, `change`, `changeNotes`, `writeMarks`, `followMove`, `finishMarks`, `publishMarks`) | `Sources/MeetingRecorder/MeetingLibrary.swift`, "Marks" |
| `addNote`, `editNote`, `deleteNote` | `Sources/MeetingRecorder/MeetingLibrary+Notes.swift` |

## The file

```json
{
  "version": 1,
  "title": "Weekly sync",
  "starred": true,
  "speakers": { "microphone": "Anna", "system": "The team" },
  "callNames": { "Guest": "Boris" },
  "notes": [
    { "id": "8E6F…", "t": 754.2, "kind": "note", "text": "Send the draft" },
    { "id": "1C0A…", "t": 912.0, "kind": "moment", "text": "we ship on Friday" },
    { "id": "77B2…", "kind": "note", "text": "typed after the meeting" }
  ]
}
```

| Key | Read as |
|---|---|
| `version` | must be the integer 1. Missing or of another type: unreadable. 0: unreadable. Above 1: `State.newer`, "written by a newer Murmurly" |
| `title` | the user's name for the meeting; absent gives the date back. Not a string: the file is unreadable |
| `starred` | absent is false. Not a boolean: the file is unreadable |
| `speakers` | names for the two tracks, keys `microphone` and `system`; any other key inside is ignored and kept. A name that is not a string: the file is unreadable |
| `callNames` | how to call a person the call feed found, keyed by the name the feed used. A value that is not a string: the file is unreadable |
| `notes` | an array of notes. Anything that is not an array reads as no notes and refuses only note writes |

A note (`MeetingNote`) is `id` (a UUID), `kind` (`note` or `moment`), `text` (a moment's is the words it marks,
or empty) and `t`, seconds into the recording, absent or null for a note with no time. An element the app does
not read (not an object, no valid `id`, an unknown `kind`, `text` not a string, `t` a boolean, negative or not
finite) is skipped on read and kept on write. A `t` of 360 000 (100 hours) or more reads as no time. Of several
elements with one `id`, the first is read.

`MeetingMarks.read(in:links:)` answers `.none` (no file), `.read(marks)`, `.unreadable(reason)` or
`.newer(version:)`. The window reads with `.follow`; the helper with `.refuse`, which never opens the file
through a link. The file's name and its keys are never translated.

## One write (`MeetingMarks.write`)

`write(_:in:expecting:)` takes a `Change` and the `FolderIdentity` the change was made for:

1. `FolderIdentity.of(folder)` must be that identity, else `Refusal.replaced`. The identity is the folder's
   volume and file number by `lstat`, so a folder reached through a link in a parent path, or a meetings-folder
   meeting opened from outside both roots, is the same folder, and a link at the address is none.
2. The file is read once. Only "no such file" is a new file; any other read error is thrown.
3. The JSON object is checked by `parse`. A file that is not an object, has no version, version 0 or a later
   version, or a mark of another type is left as it is (`Refusal.unreadable`, `Refusal.newer`).
4. The change is laid over that very object: `version` set to 1; `title` and `starred` when the change sets
   them; `speakers` and `callNames` key by key in the object read (a nil name removes its key, an emptied
   object removes the key itself); `notes` by `id` in the array read.
5. The result is parsed once more, serialized (`.prettyPrinted`, `.sortedKeys`) and written atomically. The
   marks now on disk are returned.

Every key the app does not know survives, with its value; the file's layout is the serializer's.

A `Change` sets fields: `title` (`.some(nil)` takes the name out), `starred`, `speakers` and `callNames` (only
the keys given), and `notes`, a list of `NoteOperation`:

| Operation | On disk |
|---|---|
| `.add(note)` | appended; if an element with that `id` is there, its `t`, `kind` and `text` are replaced in place and its other keys kept |
| `.edit(id:text:)` | the `text` of every element with that `id` |
| `.delete(id:)` | every element with that `id` removed; an emptied array removes the `notes` key |

An `add` repeated gives the same file, which the writer relies on: after a write that did not take every edit
it sends the pending change again.

## The writer

`MeetingLibrary` keeps one `Marks` state per folder, keyed by `FolderIdentity` (`marksStates`): the address to
write to, `change` (every field the user set that is not known to be on disk), a count of edits, the write
under way and the part it was given, a move being followed, and what the last write left on disk.

`writeMarks(of:)` starts the next write unless one is under way, the state follows a move, or the queue has an
operation on the folder (`queue.operation(on:)`). It sends either the name, star and names part
(`Change.withoutNotes`) or, when that is empty, the notes part (`Change.onlyNotes`), never both, so a `notes`
value that is not an array fails only the notes.

| Folder | Where the write runs |
|---|---|
| directly in the local root (`queue.isInMeetingsRoot`) | at once, on the main actor |
| any other (the chosen meetings folder, a meeting outside both roots) | on the serial queue of its parent folder, the one its listing is read on |

`finishMarks` takes a successful write as what is on disk: the snapshot shown is updated without a read
(`show`), and a read that started before the write does not take it back (`marksClock`, `withWrittenMarks`).
If no edit came during the write, the part sent leaves `change`; otherwise the whole change is sent again. A
failed write that took every edit drops its part into `markFailures[identity]` (`MarkFailure`: the reason and
the part sent) or, for notes, into `noteFailures`.

`publishMarks` sets `pendingMarks` (folders with anything pending) and `pendingNotes` (ids of notes not on disk
yet), each in one assignment. While a folder is in `pendingMarks` the card says "saving", a person's quit is
warned (`quitLosses`, `.unsavedMeetingMark`), `AppUpdater.busy` holds an update, the queue's move of that folder
waits (`marksBeingWritten`), the audio rule leaves its audio, and its deletion is refused.

## The name, the star and the names

`toggleStar`, `rename` and `setNames` go through `change(_:of:)`, which first asks `markRefusal`:

- the meeting is the recording under way (by path or by the folder itself);
- the folder cannot be read;
- the queue has an operation on it (a move, a deletion, the audio rule's step): the reason is the step's name;
- a folder of the same name is in both roots;
- `murmurly.json` is unreadable or newer;
- the listing is unavailable or not responding.

A refusal turns the controls off with the reason. The name changes the title only, never the folder's name; an
empty name gives the date back. A name typed is saved for the folder it was typed on
(`rename(typedOn:at:to:)`, found by identity at that path or any other), whatever is selected by then.

`setNames(typedOn:at:microphone:system:callNames:)` writes `speakers` and `callNames` the same way. A name is
kept as one line (`speakerName`: line breaks and tabs become spaces, edges trimmed, empty is no name) and may
not contain `*` (`speakerNameRefusal`). A found name typed empty, or as the feed found it, removes its rename.
`saveNames` waits until the folder has left `pendingMarks` and returns the failure, if any. How the names are
shown in a transcript is the main window's matter; a transcript file and its copies are never changed by them.

A failure of a write made at once comes back from `change` for the caller to show. A write off the main actor
that fails while another meeting, or none, is on the card, or the card is out of sight, becomes `markNotice`,
shown above every section until dismissed; a later one replaces it.

## Notes

`addNote`, `editNote` and `deleteNote` call `changeNotes(_:identity:folder:)`, which works with or without the
main window ever having been open. It clears `noteFailures` for the notes it touches, then finds the folder:

| Case | What happens |
|---|---|
| (a) the recording under way (`recorder.currentSession`, by path or identity) | accepted only in `.recording` or `.stopping` and in the local root; `.starting` refuses. Written at once on the main actor |
| (b) a row the window has for the address now (or for the identity before a move) | `markRefusal(notes: true)`: every refusal above except the queue's operation; then accepted under the row's identity |
| (c) no row, the folder where it was | accepted under the identity given, or the one read from the local root |
| (d) no row, moved by the queue in this run | accepted under the new identity if the writer already followed the move (`movedIdentities`), else under the old one |

The name, star and names of the recording under way stay refused.

**Parking.** An operation of the queue on the folder does not refuse a notes change: it stays in `change` (so
the folder stays in `pendingMarks`) and `writeMarks` returns. The library listens to `queue.$operations` and
`queue.$movedTo` without the window; either schedules `scheduleMarksResume`, which tries every writer again on
the next turn of the main actor.

**Following a move.** A notes-only write whose folder is no longer at its address (`address(of:)` finds it in
`movedTo`) calls `followMove`: the new place's identity is read on that place's own serial queue, and
`moveFollowed` moves the pending change to the state keyed by the new identity (`movedIdentities` remembers the
pair) and writes it there. `moveSources` keeps each `.moving` operation's source identity by its address path,
for a change that arrives with no identity after the move. If the new place cannot be read, the change fails
with `Refusal.replaced` rather than wait.

A notes write that fails with `Refusal.replaced` while an operation or a move explains it is parked again
instead of failing; with nothing to explain it, it fails.

**Failures.** A refused or failed notes change goes to `noteFailures[noteID]` (`MarkFailure` with the lost
operation), which the notepad shows. An entry is cleared by the next change to that note, by a write that
carries an operation with that id and succeeds, or by `dismissNoteFailure`. While `noteFailures` is not empty,
`quitLosses` reports `.unsavedMeetingMark`.

## Why it is this way

- **Fields, not the file.** A later version of the app, or the user, may keep keys this version does not know;
  writing the model back would drop them.
- **Only a proven version 1.** A file that cannot be understood may be damaged or newer; writing over it would
  destroy what it holds.
- **By the folder itself.** Two paths can reach one folder, and a path can come to hold another folder (the
  queue's move leaves a copy elsewhere; the user can put a folder back). Keyed by path, two writers could race
  on one file, or a change could land in the wrong meeting.
- **At once for the local root.** The queue marks a move on the main actor before it copies anything, so a
  write made in that turn either lands before the copy or is refused; a change is never left in the folder the
  move removes.
- **Off the main actor elsewhere.** The chosen meetings folder may be on a network volume, and a dead one would
  hang the menu.
- **Notes are parked, not refused.** A note is typed during or right after a call, exactly when the queue
  compresses and moves the meeting; refusing it would lose what was typed.
- **Fail rather than wait.** Quit, updates and the queue's move all wait for `pendingMarks`; a change that
  could never be written would hold them for the rest of the run.
- **Two writes for one change.** A crooked `notes` value must not take the star or a name down with it.
- **No `*` in a name.** A name stands between the `**` of a line's label in a saved Markdown file; a `*` of its
  own would end the label early.
- **A time of 100 hours or more reads as none.** No recording is that long, and a time from a file edited by
  hand is formatted through `Int`, which a value like 1e20 would overflow.
