---
paths:
  - "Sources/MeetingRecorder/MeetingStorage.swift"
  - "Sources/MeetingRecorder/MeetingLibrary.swift"
  - "Sources/MeetingRecorder/MeetingTranscription.swift"
  - "Sources/Settings/MeetingsSettingsView.swift"
  - "Sources/MainWindow/MeetingsView.swift"
  - "Sources/Archive/MeetingFiles.swift"
  - "Tests/MurmurlyTests/MeetingLibraryTests.swift"
  - "Tests/MurmurlyTests/MeetingStorageTests.swift"
---

# Deleting meetings and old audio

Features layer over `MeetingStorage.Removal`. Deleting by hand goes to the Trash; the audio rule
(`MeetingAudioRetention`) is the only code in the app that deletes a user's recording for good.

- **One door.** A deletion asked for by the user or by the rule calls `MeetingStorage.Removal.perform` once per
  file or folder. By hand it passes `forGood: false`; only `MeetingTranscriptionQueue.removeAudio` passes `true`.
- **No Trash, no deletion.** `CocoaError.featureUnsupported` becomes `.noTrash`: the folder is shown in Finder
  and left, also after part of its audio went. Never fall back to removing.
- **What deletes is read strictly:** `lstat` only (`entry`, `FolderIdentity.of`), a link never followed, an
  error `.unknown` and never `.absent`. Audio is the tracks `metadata.json` names (`isPlainTrackName`), their
  CAF/m4a pairs and `.<track>.partial.m4a`; a whole meeting is `manifest(of:)`, refused with a folder or a link.
- **Never deleted:** a folder not named as a meeting's (`isMeetingFolderName`), the transcripts folder through
  any address (`copiesCheck`), the recording under way (`Session.identity`), a copy in the transcripts folder.
- **Only what was confirmed goes.** The folder is read again on its own queue; another folder or other files
  there are asked about again (`removalRecheck`), never deleted on the earlier yes.
- **Admission is one turn of the main actor:** `removalRefusal`, then `MeetingTranscriptionQueue.reserve`, with
  no `await` between. The `.removing` operation is ended on every path (`carriedOut`).
- **`perform` keeps its order:** the folder by identity, the file or manifest by `lstat` again, `stillWanted`
  after that last read, then the backend. A check added later goes into `stillWanted`.
- **The rule keeps audio unless everything is proven.** `audioRetention(of:)` answers `.kept` or `.unknown` for
  any doubt, and `.unknown` makes the count incomplete; a read error is never a condition met.
- **A number of days is written only by `answerAudioQuestion` on a yes** to a count made under the same
  generation; the first pass takes only the meetings counted, by `FolderIdentity`.
- **Each file is admitted again right before it goes:** the facts from the disk, the rule and
  `retentionGeneration` (raised by whatever changes what the rule covers), no marks being written, no
  transcription of the meeting waiting. The step runs after every transcription that may be of the meeting.
- **In a test process `Removal.live` refuses.** The probe that lifts it: `reference/test-isolation.md`.

How it works: `reference/deletion-and-retention.md`.
