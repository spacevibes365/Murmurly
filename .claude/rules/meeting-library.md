---
paths:
  - "Sources/MeetingRecorder/MeetingLibrary*.swift"
  - "Sources/Archive/Meetings.swift"
  - "Tests/MurmurlyTests/MeetingLibrary*Tests.swift"
  - "Tests/MurmurlyTests/ArchiveTests.swift"
---

# Meeting library

Feature layer. `MeetingLibrary` is what the Murmurly window knows about meetings: both roots read off the main
actor, with the recorder's and the queue's live state laid over them. The app owns it, so a closed window keeps
its snapshot and stops nothing.

- **No disk on the main actor for a folder that may be remote.** Every read runs on its listing's `Channel`, a
  serial `DispatchQueue` by the listing's path, never the cooperative pool: a dead network volume then holds one
  thread of its own. On the main actor the chosen meetings folder is a path only, and `fileExists` is asked only
  of local-root paths (`address(of:)`, `follow`).
- **Reads start only while the window is open, one per channel.** A request made meanwhile sets `listWanted`,
  `textWanted` or `searchWanted` and runs after the read under way (`runNext`); two reads of one folder at a
  time would let the earlier answer land over the later one.
- **`fresh` means read for the latest request of this opening** (`requestGeneration`, `windowGeneration`). The
  search, the empty states and "No matches" rest on it; every `refresh()` clears it first.
- **A text is shown only for the token, meeting and version it was read for** (`finishText`), and the 3 s
  "not responding" flag only for the very read still under way (`Channel.token`).
- **Unknown is never "none".** A root that cannot be listed is `.failed` and keeps the meetings it showed; a
  folder of a meeting's name that cannot be read stays a meeting (`readable == false`); an unreadable last
  record is `.unknown`, never the earlier result; a size not measured whole is nil.
- **A row is its path, a folder is its `FolderIdentity`.** The list, the selection and `meeting(at:)` go by the
  canonical path (`MeetingLibrary.canonical`), so one name in both roots is two rows. Anything kept across a
  turn or acted on later (marks, deletion, the player, search texts, a name being typed) goes by
  `Meeting.identity`: another folder may be at the path by then.
- **A session that just ended is "saving", not "broke off",** until a read of the local root started after the
  end answers (`recentlyStopped`, `readsAtStop`): a snapshot without its `metadata.json` is only out of date.
- **A queue move is followed only while nothing is at the old local path** (`address(of:)`, `follow`): a copy
  put back there is a meeting of its own.
- **`section`, the selection, the picked version and the search query are memory only.** No stored value
  decides what the window shows.
- **The library does not forward the queue's or the recorder's changes.** `status(of:)`, `markRefusal` and
  `transcriptionRefusal` read them at the call; whoever shows the answer observes those objects itself.

How it works: `reference/meetings-window.md`.
