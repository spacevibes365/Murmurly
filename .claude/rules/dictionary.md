---
paths:
  - "Sources/PersonalDictionary.swift"
  - "Sources/Settings/DictionarySettingsView.swift"
  - "Sources/SettingsStore.swift"
  - "Tests/MurmurlyTests/PersonalDictionaryTests.swift"
  - "Tests/MurmurlyTests/SnippetTests.swift"
  - "Tests/MurmurlyUITests/DictionaryTransferTests.swift"
  - "Tests/MurmurlyUITests/SnippetSheetTests.swift"
---

# Personal dictionary and snippets

Services layer: the entries, their document in `SettingsStore` and `DictionaryReplacer`. The Dictionary section of the
main window and `DictionaryEntrySheet` are Features.

- **One document, saved whole.** `dictionary.entries` is written only by `saveDictionary(_:)` (data first, then the
  published value) and removed only by `clearDictionary()`; nothing seeds, repairs or migrates a dictionary by itself.
- **An unreadable key is kept byte for byte.** Another version, an unknown `kind` or damaged data: jobs run without
  replacements and editing waits for an explicit "Clear Dictionary…".
- **A new field of an entry needs a new document version.** Unknown keys are dropped by the next save, and the
  document stays version 1, byte for byte, while it holds no snippet, so an older app still reads it.
- **One encoder for the settings and the file** (`SettingsStore.encodedDictionary`). An import takes only a file this
  app could have saved (`importedDictionary(from:)`), refuses it whole, and merges once, at the answer, in the
  synchronous `importDictionary(_:replacing:)`; the same id with other content stays the user's.
- **Close nothing from `onChange(of: section)`.** A panel, a question or the sheet stays up over a changed section;
  only a file still being read is dropped. Closing one there ran a nested run loop inside the window's layout and
  crashed AppKit.
- **One snapshot per job**, taken as the job starts; a saved history line or transcript is never redone. Build and run
  the replacer off the main actor: both call macOS's tagger.
- **Where the replacement runs.** Dictation: right after the segments are joined, before the trim, the history and the
  paste. Meetings and files: in `MeetingTranscriber.finished`, after echo removal and merging, which need the words as
  recognized.
- **Snippets are for dictation only.** Only `replacer(for: .dictation)` includes them; one fires on the whole text,
  never by word form, and one with no text is skipped rather than erase a dictation.
- **One fold for conflicts and for matching** (`DictionaryReplacer.words`, `folded`): case and the Russian letters yo
  and ye never tell words apart. One pass, left to right, the written form inserted literally.
- **Logs get the number of replacements and entries, never the words.**

How it works: `reference/dictionary.md`.
