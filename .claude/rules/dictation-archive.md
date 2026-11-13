---
paths:
  - "Sources/Dictation/DictationHistory*.swift"
  - "Sources/Dictation/DictationAudioArchive.swift"
  - "Sources/Archive/Dictations.swift"
  - "Tests/MurmurlyTests/DictationHistory*Tests.swift"
  - "Tests/MurmurlyTests/History*Tests.swift"
  - "Tests/MurmurlyTests/RecognizeAgainTests.swift"
  - "Tests/MurmurlyTests/DictationArchiveSamplesTests.swift"
  - "Tests/MurmurlyTests/AudioIntegrityTests.swift"
---

# Dictation archive

Services layer: `DictationHistoryStore`; the Dictations section of the main window is a Feature. The line format
(`DictationHistoryEntry`) is Core, shared with the agents' helper.

- **Private by mode.** The root and its year and month folders are created `0700`, files `0600`; audio files and the
  rewrite's temporary file with `O_EXCL`.
- **A dictation only appends.** A line changes only by an explicit action (delete, Clear All, Recognize Again), and
  every rewrite goes through `rewriteHistory`: a temporary file in the root, `fsync`, `rename`, `fsync` of the folder.
- **Lines not being changed are copied as bytes**, unreadable ones and a tail without a newline included; never decode
  and re-encode a line that stays.
- **No `await` inside a store method that writes.** `saveDictation` archives the audio and appends its line in one
  actor turn, so `clearAll` and `delete` see a dictation whole or not at all.
- **Audio first, then the line, on a save; the index first, then the audio, on a delete or a clear.** A line never
  points at audio the app removed. The store never deletes the source CAF: the caller does, after the save answered.
- **Post `dictationHistoryDidChange` with the store as `object` after every completed change of the index**, even when
  removing the audio then failed. A consumer creates its `DictationHistoryChanges` before its first read and reads
  again on `revision`: a list is replaced by a fresh read, never patched by hand.
- **Clear All removes only what `ownedFiles(in:)` names** (`<yyyy>/<MM>/<UUID>.caf|m4a`, `.history-<UUID>.tmp`),
  follows no link, and fails on a folder it cannot list instead of taking it for empty.
- **No absolute paths in the JSONL.** `audio_path` is empty or relative to the root, so moving the folder to another
  Mac is enough; resolve it only through `resolvedAudioURL`, which keeps the result inside the root.
- **A new key is optional and left out when unset**, so ordinary lines stay byte for byte within `schema_version` 1.
  `at` is ISO 8601 UTC with fractional seconds; a line that does not decode is skipped by readers and kept by rewrites.
- **One audio format, checked before encoding.** `dictationArchiveFormatID` is the only place it is named;
  `requireLosslessRange` sees every block first, and anything but Float32 in `[-1, 1]` keeps the source CAF byte for
  byte, because 24-bit ALAC would clip it silently.

How it works: `reference/dictation-archive.md`.
