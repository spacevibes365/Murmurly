---
paths:
  - "Sources/SettingsStore.swift"
  - "Sources/Settings/Settings*.swift"
  - "Sources/Settings/StorageSettingsView.swift"
  - "Tests/MurmurlyTests/PermissionsAndSettingsTests.swift"
---

# Settings

Services layer (`SettingsStore`, `SettingsSnapshot`) and Shell layer (the Settings window, Storage).

- **No stored flag decides whether a window is shown.** A persisted "show the window" flag once looped open and
  closed forever. Getting Started shows because `meeting.autoRecord` is absent, and `prepareGettingStarted`
  writes that key before the window opens.
- **Reading a setting writes nothing.** `SettingsStore.init` sets no key, and a value it cannot use (a tab that
  left, a language the engine does not know, an unreadable dictionary) stays as stored. The stage gate, and
  any test process of a Release build, run on the live domain and must leave it as they found it.
- **Keys are never renamed or translated.** `meeting.storageFolder` and `agents.*` are read by the helper
  process (`HelperContract.SettingsKey`); the folder key is a literal in both places.
- **A `$property` sink applies the value it was sent.** `@Published` sends before the property changes, so
  reading the store inside the sink gives the old value.
- **Work takes its settings as a snapshot when it starts** (`snapshot`, `dictionarySnapshot`); a change applies
  to the next job. A job's own engine and language go over it with `SettingsSnapshot.applying(_:)` and are
  never written to the store.
- **A folder becomes the meetings or the transcripts folder only through `chooseMeetingsFolder` and
  `chooseTranscriptsFolder`;** only a reset to none is written directly. They refuse the local recording root
  (the meetings folder only) and the dictation archive, links resolved.
  That check runs at the choice only: the stored path is read as it is at launch.
- **A number of days of `meeting.audioRetentionDays` is written by the queue after its question**
  (`askAudioRetention` → `writeAudioRetention`), never by a view: the write deletes audio for good.
- **Chosen folders are never touched on the main actor.** They may be on a dead network volume, which hangs
  the caller; Storage reads them in a detached task and publishes only while its task is not cancelled.
- **Every tab is built with the window and only hidden.** Its `onAppear` runs once; what must happen on a
  switch watches `settings.settingsTab`.
- **Shortcuts live in `UserDefaults.standard`, not in the store's domain** (KeyboardShortcuts reads nothing
  else); a view that records one calls `settings.objectWillChange.send()` itself.

Every key, its default, writers and readers: `reference/settings.md`.
