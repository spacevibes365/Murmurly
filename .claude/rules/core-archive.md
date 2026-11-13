---
paths:
  - "Sources/Archive/**"
  - "Tests/MurmurlyTests/ArchiveTests.swift"
---

# The shared read layer (`Sources/Archive`)

Core layer. The formats on disk and how they are read: meeting folders, attempt records, marks, the call
feed, transcripts, the dictation history, the helper's contract. It builds into two targets, the app and
the `murmurly` helper.

- **Two targets compile every file here.** Use Foundation, Darwin and CryptoKit only: no AppKit, SwiftUI or
  AVFoundation, no `@MainActor`, no `AppLog`, `SettingsStore`, `TestIsolation` or any other app type. A file
  that needs one belongs in the app, as an `extension` (see `MeetingStorage`, `MeetingTranscript`).
- **The helper has no string catalog.** `String(localized:)` here gives the app a translation and the
  helper the English key; never branch on such text, and keep machine-read values (`state`, `kind`,
  `result`, error codes) untranslated.
- **"Could not read" is never "not there".** Only `ENOENT`/`ENOTDIR` mean absent. Everything else is its
  own answer: `Archive.ReadError`, `RootState.failed`, `MeetingMarks.State.unreadable`,
  `LastAttempt.unreadable`, `metadataError`. A caller that folds them into `nil` or `[]` hides a loss.
- **Each read says how it treats links.** `Archive.Links.refuse` (the helper) opens with `O_NOFOLLOW` and
  never opens a meeting folder that is a link; `.follow` is the window's behaviour. A new read takes
  `links:` and honours both.
- **A known version or hands off.** A file whose version this build does not know is not read as the
  current one and is never written over (`MeetingAttempt`, `MeetingMarks`, `CallFeed`).
- **Change formats compatibly.** A new field is optional and absent in old files; an absent key keeps an
  ordinary line byte for byte what it was (`DictationHistoryEntry`, `CallFeed.Event.encodedLine`). Keys a
  build does not know survive a write: `murmurly.json` is edited as the object that was read.
- **One decoder per format.** The app's writers use the encoders and names defined here
  (`DictationHistoryEntry.makeEncoder`, `MeetingAttempt.namePrefix`, `CallFeed.fileName`,
  `MeetingMarks.fileName`); a second copy of a name or a date format lets reader and writer drift.
- **`MeetingAttempt.Head` mirrors `MeetingAttempt`.** A field added to one without the other makes the
  listing's lighter read stop seeing it.
- **What a meeting is, is decided here**: `MeetingStorage.isMeetingFolderName` plus `metadata.json` or a
  default track. Storage, the window and the helper must count the same folders.
- **File and folder names are never translated**: ` Meeting`, `transcript N.md`, `murmurly.json`,
  `history.jsonl`.

Formats, field by field: `reference/disk-formats.md`.
