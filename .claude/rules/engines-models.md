---
paths:
  - "Sources/WhisperKitService.swift"
  - "Sources/Dictation/ParakeetEngine.swift"
  - "Sources/ModelDownloader.swift"
  - "Sources/TranscriptionService.swift"
  - "Tests/MurmurlyTests/WhisperKitCacheTests.swift"
  - "Tests/MurmurlyTests/ModelDownloaderTests.swift"
---

# Engines, models and language

Services layer. Parakeet (FluidAudio) and Whisper (WhisperKit) behind one cache, the language request, the downloader.

- **One resident engine, one operation at a time.** `WhisperKitCache` holds a single loaded engine for the whole app
  and runs loads and decodes in arrival order. Never call an engine around the cache or keep a second one: two
  models would sit in memory, and dictation, meetings, Files and the live transcript would decode over each other.
- **Another `EngineDescriptor` is a hard boundary.** The old engine is released before the new load starts and never
  becomes a fallback when that load fails; a load whose operation was cancelled must not fill the cache.
- **WhisperKit types never leave the `WhisperKitEngine` actor**: they are not Sendable. Callers see only DTOs.
- **Request and descriptor come from one snapshot** (`decodeRequest` with `dictationDescriptor`); a mismatch fails at
  run time. A job's own engine and language go through `SettingsSnapshot.applying(_:)`, never by writing the settings.
- **`SettingsSnapshot.decodeRequest` is the one place the language setting becomes a request.** A code the engine
  does not know is Auto, and the stored setting is not rewritten. Parakeet's language is a script filter, not a
  hint (`ru` forbids Latin letters), so on Auto it gets nil.
- **Keep `chunkingStrategy: .vad` for Whisper**: the default strategy hallucinated a segment and skipped the speech
  after it. The subtitle-phrase filter drops whole segments only; never match a substring of live speech.
- **Callers end their own requests.** The cache has no deadline and cannot remove another caller's operation; its
  `progress` runs on the cache actor, so it must return at once.
- **Do not load over a held engine.** Work in another engine than `DictationCoordinator.heldEngine()` or
  `MeetingRecorder.liveTranscriptEngine` waits before each request, inside its job, so quit and updates see the wait.
- **Only `ModelDownloader` fetches models, one download for the whole app.** WhisperKit loads with `download: false`
  and the tokenizer `WhisperTokenizerLocator` found; `LiveParakeetEngineFactory.make` sets `ModelHub.offlineMode`
  before each load; the VAD is loaded by hand, as FluidAudio's own path downloads and deletes a folder that fails.
- **A model folder appears by one `rename(2)`, whole or not at all**, the tokenizer before Whisper. Readiness is the
  presence of the files (`ModelSource.required`), never a stored flag.
- **`ModelSource.paths` and `destination` change together**: a file added under the same `destination` makes installed
  copies read as missing, and each download then ends in `InstallError.occupied`. Parakeet's name is FluidAudio's own.

How it works: `reference/engines.md`.
