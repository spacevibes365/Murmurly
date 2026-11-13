---
paths:
  - "Sources/MeetingRecorder/MeetingLibrary.swift"
  - "Sources/MeetingRecorder/MeetingLibrary+Notes.swift"
  - "Sources/MeetingRecorder/MeetingStorage.swift"
  - "Sources/Archive/MeetingFiles.swift"
  - "Tests/MurmurlyTests/MeetingLibrary*Tests.swift"
  - "Tests/MurmurlyTests/MeetingNotesTests.swift"
---

# A meeting's marks (`murmurly.json`)

Features layer; the format and its reading are Core (`Sources/Archive/MeetingFiles.swift`). The file holds a
meeting's name, star, speakers' names (`speakers`, `callNames`) and notepad notes (`notes`).

- **One writer.** Only `MeetingLibrary` writes the file, through `MeetingMarks.write`, with one writer state per
  folder keyed by `FolderIdentity` and one write at a time; a second path to the same folder is the same writer.
- **A change sets fields, never the file.** The file is read once, checked by `parse`, that very object is
  changed and written atomically. Never encode `MeetingMarks` whole: unknown keys at the top, inside `speakers`
  and `callNames`, inside a note, and `notes` elements the app does not read must survive.
- **Only a file proven to be version 1, or proven absent, is written.** No version, another type, version 0, a
  later version, not JSON or a failed read leave it byte for byte, with the reason shown.
- **Only into the folder the change was made for.** `write` refuses unless `FolderIdentity.of(folder)` is the
  expected identity (`Refusal.replaced`); a link at the address is no folder.
- **Never into a folder the queue is taking.** Under an operation the name, star and names are refused
  (`markRefusal`) and a notes change is parked (`writeMarks`); a write during a move would stay in the copy left.
- **A folder in the local root is written at once on the main actor** (`isInMeetingsRoot`), so it lands before
  the move takes the folder; any other on its parent folder's serial channel, never on the main actor.
- **A pending change must end.** `pendingMarks` holds back quit, updates, moves and deletions, so a change whose
  folder is gone with no operation or move to explain it fails with a reason. It is published in one assignment
  (`publishMarks`): `AppUpdater.busy` must see no empty moment between two steps of one change.
- **Notes go by `id`, in place, and an `add` is idempotent**: the writer resends the whole pending change. The
  notes part is a write of its own, so a `notes` that is not an array loses only notes; a note's failure goes
  to `noteFailures`, never to the card's `markFailures`.
- **Only notes may be written into the recording under way**, in `.recording` or `.stopping`, in the local root.
- **Names never change a transcript.** `speakers` holds `microphone` and `system` only; a name is one line
  without `*` (`speakerName`, `speakerNameRefusal`).
- **The file name and its keys are never translated**; the read side stays free of AppKit, as the helper links it.

How it works: `reference/marks-and-notes.md`.
