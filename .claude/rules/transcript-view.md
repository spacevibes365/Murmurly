---
paths:
  - "Sources/Archive/MeetingText.swift"
  - "Sources/MainWindow/TranscriptTextView.swift"
  - "Sources/MainWindow/MeetingPlayer.swift"
  - "Sources/MeetingRecorder/MeetingLibrary.swift"
  - "Sources/MeetingRecorder/MeetingLibrary+OpenAndPlay.swift"
  - "Tests/MurmurlyTests/MeetingListeningTests.swift"
  - "Tests/MurmurlyTests/MeetingNotesOnCardTests.swift"
---

# Transcript on the card: text, search, Save As, player

Feature layer over a Core type: `MeetingTranscript` and `MeetingSearch` (`Sources/Archive/MeetingText.swift`) are
shared with the agents' helper, so they take no AppKit and no `UTType`; export lives in `MeetingLibrary.swift`.

- **Transcript files never change.** Names, notes and Save As are laid over the text read; nothing here writes
  into a meeting's folder, and `destinationRefusal` refuses a save inside any meeting's folder, links followed.
- **One text for the card, Copy Text and Save As:** `shownTranscript(of:)`. A second way to build it would let
  the three disagree.
- **Names only with `timing == .exact`,** by index from the record's `lines[i].source`, never by the label's
  text: only a file its record still matches (size, SHA-256, line count) says which track a line came from.
  Any other version says why through `recordRefusal`.
- **`MeetingSearch` is the one rule for a match** (the window's count, the card's highlights, the notepad, a
  moment's highlight). `fold` keeps the UTF-16 length; a fold that shortened the text made a range run past
  its end.
- **"No matches" waits for `SearchState.settled`.** A text not read, unreadable, in a folder not read or being
  read again is not "not found". A search read or a count begun before a newer request or query is dropped.
- **Subtitles only from exact spans whose times pass `isSubtitleTime`** (finite, not negative, under 100
  hours): a record edited by hand may hold any number.
- **One save at a time, panel through `FilesModel.present`** on the window the click came from, never
  `runModal`; the write goes on `exportQueue`, and `exporting?.writing` is what quit and updates wait on.
- **The player opens files only on its own serial queue,** and before each file checks the folder's
  `FolderIdentity` and the track by `lstat` (a link or an unknown entry is not opened). A late load only closes
  what it opened.
- **`isOpening` and `release` are the queue's handshake.** `beginOperations` takes no folder while a load of
  it is opening and closes the files of the folders it takes in that same turn; while an operation holds a
  folder nothing opens (`audioRefusal`).
- **Every start asks `startRefusal` again** (recording, dictation, the card's meeting, the window, operations);
  `seek`, `skip` and `setRate` restart through it. Both tracks start at one moment of the output's clock, one
  rate, volume 1 or 0, never a gain.
- **The card's state is not changed inside `updateNSView`.** `TranscriptTextView` reports matches and
  selection after the update, and a selection only for the text it was made in (identity and generation).

How it works: `reference/meetings-window.md`.
