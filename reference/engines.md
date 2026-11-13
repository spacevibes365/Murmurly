# Engines, the engine cache, language and models

Speech recognition runs on one of two engines, loaded one at a time by a single cache that every part of the app
goes through. This file covers the engines, the cache and its queue, who holds the engine against whom, how the
language setting becomes a request, and how models reach the disk.

## Where things are

| Thing | Type | File |
|---|---|---|
| Engine choice | `DictationEngine` (`whisper`, `parakeet`; the stored `rawValue`) | `Sources/SettingsStore.swift`, extended in `WhisperKitService.swift` (languages) and `ModelDownloader.swift` (models, name) |
| Engine + model folder | `EngineDescriptor` | `Sources/SettingsStore.swift` |
| Settings as a job sees them | `SettingsSnapshot`, `Choice`, `applying(_:)`, `dictationDescriptor` | `Sources/SettingsStore.swift` |
| Language → request | `SettingsSnapshot.decodeRequest`, `EngineDecodeRequest`, `WhisperDecodeRequest` | `Sources/WhisperKitService.swift` |
| The cache | `WhisperKitCache` (serves both engines despite its name), `WhisperModelState` | `Sources/WhisperKitService.swift` |
| Whisper | `WhisperEngine`, `LiveWhisperEngineFactory`, `WhisperKitEngine`, `WhisperTokenizerLocator` | `Sources/WhisperKitService.swift` |
| Parakeet | `ParakeetEngine`, `LiveParakeetEngineFactory`, `FluidParakeetEngine` | `Sources/Dictation/ParakeetEngine.swift` |
| Result | `EngineTranscriptDTO`, `WhisperSegmentDTO` (both engines) | `Sources/WhisperKitService.swift` |
| Errors | `TranscriptionError` | `Sources/TranscriptionService.swift` |
| Models | `ModelSource`, `ModelDownloader` | `Sources/ModelDownloader.swift` |

## The two engines

| | Parakeet | Whisper |
|---|---|---|
| Model | Parakeet TDT 0.6b v3, Core ML, int8 encoder | Whisper large-v3 turbo, Core ML |
| Package | FluidAudio | WhisperKit |
| Default | yes, when `dictation.engine` is not set | no |
| Languages | 25 European ones, listed in `DictationEngine.languages` | WhisperKit's `Constants.languageCodes` |
| What the language does | a script filter (`ru` forbids Latin letters); nil is no filter | the decoding language; nil detects it, once per request |
| Segments returned | one, with `start` 0 | WhisperKit's own, each with its start |
| Language reported | the code asked for, or `"auto"` | the code asked for, or the one detected |

Both packages are pinned with `exactVersion` in `project.yml`.

**Whisper.** `WhisperKitEngine` is the only owner of the `WhisperKit` instance; decoding options and results are
created and consumed inside that actor. It loads with `download: false` and an explicit `tokenizerFolder`. Decoding
uses `chunkingStrategy: .vad`. Segments are trimmed, empty ones dropped, and a segment that is, as a whole, one of
the known subtitle phrases is removed (`WhisperSegmentDTO.removingKnownSubtitleHallucinations`: lower case, runs of
whitespace joined, trailing `.`, `…`, `!` dropped; nothing is logged for a removed segment).

**The Whisper tokenizer** is a Hugging Face repository of its own. `WhisperTokenizerLocator.folder(for:)` looks next
to the model, at `<models folder>/openai/whisper-large-v3`, and accepts the folder when `config.json` and
`tokenizer.json` are there as files; without them the load fails with "only partly downloaded" before WhisperKit is
created. The check is of presence only: WhisperKit itself falls back to the Hub when a local tokenizer does not load.

**Parakeet.** `LiveParakeetEngineFactory.make` sets `ModelHub.offlineMode = true` before every load, then
`AsrModels.load(from:version:encoderPrecision:)`. FluidAudio takes the folder's parent and its own name for the
repository, which is why `ModelSource.parakeet.destination` is `parakeet-tdt-0.6b-v3`. Each request gets a fresh
decoder state. The token `<unk>`, which the model writes for characters it has no token for (the Russian letter yo,
angle quotes), is always cut from the text, with or without a filter.

## The cache

`WhisperKitCache.shared` is an actor with one loaded engine (`loaded`), at most one load under way (`loading`), a
`generation` counter and a FIFO of waiters. Every public call is one operation (`withEngine`):

1. `acquire`: take the queue, or report `.waiting` and wait in arrival order. A waiter that is cancelled leaves the
   queue and never runs.
2. `engine(for:)`: if the loaded descriptor is the one asked for, use it. Otherwise bump `generation`, drop the
   loaded engine, report `.loading`, and build the new one through the factory in a task of its own.
3. Report `.ready`, check cancellation, run the operation on the engine.
4. On any exit, hand the queue to the next waiter.

| State (`WhisperModelState`) | Sent by the cache when |
|---|---|
| `.waiting` | the queue is taken by another request |
| `.loading` | this operation starts a load |
| `.ready` | the engine is there, right before the work |
| `.cold` | never; it is the dictation's own "not prepared" |

Things that follow from this shape:

- A failed load leaves the cache empty. The engine that was there before is already gone.
- Cancelling an operation that is loading bumps `generation` and cancels the load's task, but the operation still
  waits for that task to return, and so does the queue behind it. A load that finishes after its cancel is thrown
  away, and the next request for that engine loads it again.
- `decodeDuration` in the result covers the decode only, not the wait or the load.
- Progress goes only to the caller of the operation. Nothing announces that the resident engine changed, so
  `DictationCoordinator.modelState` is the state of the dictation's own last request: it can read `.ready` while a
  job in another engine has the cache.
- There are no deadlines. A wait ends when the request ahead returns or the waiter is cancelled.

| Caller | Call | What it does with the states |
|---|---|---|
| Dictation (`DictationCoordinator.transcribe`) | `transcribe(audioPath:descriptor:request:progress:)` | sets `modelState` and the indicator, each state on its own main-actor hop, guarded by the selection and `modelGeneration` |
| Dictation warm-up (`startModelWarmup`) | `updateDesired(_:generation:)`, then `prepareDesired` (a prewarmed load) | sets `modelState` |
| Recognize Again | `transcribe`, with no progress | none |
| Meeting job and Files run (`MeetingTranscriber.recognize`) | `transcribe`, states through an `AsyncStream` | `.waiting` → `.waitingForEngine`, `.loading` → `.preparingModel`, `.ready` → `.recognizing` |
| Live transcript (`LiveTranscript`) | `transcribe` | `.waiting` and `.loading` both show as preparing the model |

`updateDesired` ignores a generation older than the last one it took, and `prepareDesired` loads until the loaded
descriptor is the desired one, so a warm-up ends on the latest selection.

## Who holds the engine

The cache keeps one engine, so work in another engine than the one someone is using would make that user load its
model back before every request. Two holds prevent it. Both live outside the cache: each waiting side polls every
250 ms, and none of the waits has a deadline.

| Hold | Value | From | Until |
|---|---|---|---|
| Dictation: `DictationCoordinator.heldEngine(at:)` | the descriptor of `recordingSnapshot`, else of the settings | `state` leaves `.idle` | `engineHold` (30 s) after the dictation ends, then by the settings' descriptor; nil before the first dictation of a launch |
| Live transcript: `MeetingRecorder.liveTranscriptEngine` | the engine taken as the live transcript starts | the live transcript is created | `takeLiveTranscript`, at the recording's stop or a cancelled start |

| Who waits | For which hold | Where | What shows |
|---|---|---|---|
| Meeting job, Files run | both | `MeetingTranscriber.engine(for:progress:)`, right before each chunk's request; the engine is read again after every wait | `.waitingForEngine` |
| Dictation warm-up | live transcript | `DictationCoordinator.startModelWarmup` | no state of its own: `modelState` stays as it was |
| Recognize Again | live transcript | `DictationCoordinator`, before its request | nothing |

A job in the held engine never waits for a hold; it only takes its turn in the cache's queue. The wait is inside the
job's own task, so quit and `AppUpdater.busy` see a job that waits as a job that runs, and Stop or Cancel end it.
Dictation and meeting recording exclude each other, so a dictation never meets the live transcript's hold.

The holds reach the two pipelines by different routes. `MeetingRecorder.transcripts` hands the queue
`heldByDictation`, `heldByLiveTranscript` and `prepareDictationEngine` when the queue is set. `FilesModel.live` takes
them from the dictation itself (`dictation.heldEngine()`, `dictation.meetingPeer?.liveTranscriptEngine`,
`dictation.prepareAfterOtherEngineJob()`).

**Giving the engine back.** A job with a choice of its own may leave its engine in the cache. The queue remembers
that (`returnsDictationEngine`) and, once no transcription is left in `pending`, whatever the last job was, calls
`DictationCoordinator.prepareAfterOtherEngineJob()`. That comes after the transcript and its copy. The Files section
calls the same after every run that had a choice, whatever its end, once the result is shown. The call is the
ordinary warm-up: it does nothing while a dictation is under way (that one warms its selection as it ends), nothing
without the model on disk, and runs under the selection's `modelGeneration`, so a change of the settings wins. Its
failure shows as any warm-up's (`modelFailure`).

What the holds do not cover:

- A dictation started between a job's check and its request waits for that one chunk, or for one load.
- A dictation started while a job prepares Whisper for the first time waits for that whole preparation.
- The Files section and the meeting queue do not give way to each other. A meeting in one engine and a file in
  another take the cache by turns and load the models again, and the warm-up after a file may come in the middle of
  a series of meetings.
- Recognize Again is not a hold: a job in another engine does not wait for it.

## Language

One setting, `SettingsStore.dictationLanguage` (`dictation.language`: `"auto"` or an ISO code, `"auto"` when unset),
and one function that turns it into an engine request, `SettingsSnapshot.decodeRequest`, which dictation, meetings,
files and the live transcript all start from. `DictationEngine.language(for:)` returns the code when the engine knows
it and nil otherwise, so a code of the other engine acts as Auto and the stored value stays.

| Setting | Parakeet request | Whisper request |
|---|---|---|
| `"auto"` or a code the engine does not know | `.parakeet(nil)`: no script filter | `.whisper(language: nil)`: detect |
| a code the engine knows | `.parakeet(code)`: the filter for that language | `.whisper(language: code)` |

**A job's own engine and language.** A meeting job or a Files run may carry a `SettingsSnapshot.Choice`. Its
initializer keeps a code the engine does not know as `"auto"`, so two choices that ask the engine the same are
equal. `SettingsSnapshot.applying(_:)` lays the choice over the snapshot wherever the job reads the settings (engine,
request, model check, the dictionary's word forms); the settings themselves are never written. Without a choice a job
reads the settings again before every chunk.

**Whisper on Auto in meetings, files and the live transcript.** While the request is exactly "Whisper, detect", each
chunk is sent with the job's fixed language, nil at first, so Whisper detects per chunk. The first chunk that gave
text and is longer than `MeetingTranscriber.languageFixSeconds` (5 s) fixes its language for the rest of the job. A
meeting's chunks go track by track, microphone first, so this is not a detector of language changes during a call.
A dictation is one request: its language is detected once, from its first 30 s.

**In the interface.** The pickers list `DictationEngine.languageChoices` of the selected engine. Settings has a
search by name and code (`DictationSettingsView.filteredLanguages`) that never hides Auto or the current choice, and
a note under the picker when the stored code is not the selected engine's (`fallbackNote`). The menu shows Auto, the
current language and "More Languages…", which opens Settings on Dictation.

## Models and the downloader

Models live in one folder, `ModelDownloader.defaultRoot` (`Models` in the app's Application Support folder). The
paths the engines load from are constants of that folder (`SettingsStore.modelPath(for:)`); there is nothing to
choose.

| `ModelSource` | Repository | Folder under `Models/` | Size |
|---|---|---|---|
| `.parakeet` | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | `parakeet-tdt-0.6b-v3` | 483 MB |
| `.whisper` | `argmaxinc/whisperkit-coreml`, one folder of it | `openai_whisper-large-v3-v20240930_turbo` | 1.64 GB |
| `.whisperTokenizer` | `openai/whisper-large-v3`, the json files and merges only | `openai/whisper-large-v3` | 4.4 MB |
| `.vad` | `FluidInference/silero-vad-coreml`, one compiled model | `silero-vad-unified-256ms-v6.2.1.mlmodelc` | 1.1 MB |

Each source is pinned to a revision. `paths` names the files and folders taken; a path ending in `/` takes
everything below it. `required` is what must exist for the model to count as installed: `coremldata.bin` for a
compiled model, the file itself otherwise.

| Question | Answer |
|---|---|
| `DictationEngine.models` | tokenizer then model for Whisper; the model for Parakeet |
| `isReady(engine)` | the engine's own models are installed; the dictation can start |
| `missing(engine)` | the engine's models and the VAD that are not installed; what a download fetches, and what a meeting job or a Files run checks |

**A download** (`ModelDownloader.start(_:)`):

1. Refused while another download runs: `download` is one for the whole app. The four places that start one
   (Settings → Dictation's model row, the menu's "Download Model…", the Files section, the Transcribe Meeting…
   panel) show a running download under its own engine's name.
2. Leftover `.partial-<UUID>` folders in the models folder are removed, only those named exactly that way. A new
   `.partial-<UUID>` is created and removed again on every exit.
3. Each source is listed through the Hugging Face API (`api/models/<repo>/tree/<revision>`, recursive) and filtered
   to its `paths`. The total is the sum of the listed sizes.
4. Each file is fetched from `<repo>/resolve/<revision>/<path>` by a data task that writes straight into the partial
   folder and hashes on the way. The response must be 200, the size must match the listing, and for an LFS file the
   sha256 must match its `oid`; otherwise `InstallError.damaged`.
5. In the order given, each staged model is checked (`InstallError.incomplete`) and moved into place with one
   `rename(2)`. A destination that exists and is not empty is `InstallError.occupied`: the folder is never replaced.

The session is ephemeral and the only host is `huggingface.co`. Progress is reported about once a megabyte; an
update from an older attempt, or one that would move the bar back, is ignored. A cancel is not a failure; a failure
is kept with its engine (`failure`). There is no resuming: a cancelled or failed download starts over, and models
already in place stay. A download is neither a quit loss nor part of `AppUpdater.busy`, so quitting ends it; what it
left is removed when the next download starts.

After each successful install `installs` grows, and `DictationCoordinator` answers with `retryModelPreparation()`:
while idle, and only if the model is cold or its preparation failed.

**Without a model.** The dictation shortcut does not record and says where to get one. A meeting is still recorded;
its live transcript reports no model, and the transcription job fails with `Failure.modelNotDownloaded`, which says
how to come back to it. A meeting job and a Files run check `missing(engine)` for their own engine as they start.

**Readiness on screen** has two answers. `DictationCoordinator.readiness` (the menu's Dictation line, the Settings
footer) looks at the model on disk, a preparation failure, the microphone and `modelState`. `ModelRow.isReady` (the
row's green dot and the check in Getting Started) also wants the VAD on disk and no download running.

## Why it is this way

- **One engine in memory.** The models are large; the cache trades reload time for memory and for a single order of
  work.
- **Parakeet by default.** It is a third of Whisper's download, and Whisper is needed only for languages beyond
  Parakeet's 25.
- **The hold, and 30 s after a dictation.** The next dictation often follows within that time, and without the hold
  a job in another engine would make each dictation load its model back.
- **The engine goes back at the end of a series, not between jobs.** A warm-up between two jobs with a choice would
  load both models in turn.
- **Measured on 2026-10-14** on an Apple M4 Mac with 16 GB of memory, by the app's log: the first load of Whisper
  large-v3 turbo after its download took 104 s, as Core ML builds the model for the device; every later load, after
  a relaunch too, 2.3 s. Parakeet loads in 0.5 s. A 2-minute meeting (108 s of speech, 14 chunks) took 2.2 s with
  Parakeet and 13 s with Whisper, its load included. So where the holds do not cover, a dictation waits for one chunk
  (under a second) or one load (2.3 s), and right after Whisper is downloaded for up to about 100 s. The dictation's
  own delay during a job was not measured live: a test process has no global shortcuts.
- **Parakeet without a filter on Auto.** Chosen by measuring a Russian meeting recording: without the filter some
  English terms stay in Latin letters, others still come out in Cyrillic, and a few short replies come out in Latin;
  the `ru` filter would turn every term into Cyrillic. The personal dictionary fixes the terms that still come out
  wrong.
- **The language is fixed only by a chunk longer than 5 s.** A short reply must not be dropped or forced into a
  language it may not be in.
- **`chunkingStrategy: .vad`.** With WhisperKit's default strategy a 55 s monologue came back with one hallucinated
  segment over its first 13 s and nothing until second 32. Measured on the pinned WhisperKit version and model.
- **The subtitle-phrase filter.** Whisper produces stock subtitle and outro phrases on silence. The list is seeded
  from real dictations, and matches whole segments so that live speech containing such words is kept.
- **The tokenizer is checked before WhisperKit sees it.** WhisperKit would fetch a missing one from the network into
  whatever folder it was given.
- **The VAD is loaded by hand.** FluidAudio's `VadManager(modelDirectory:)` goes through `ModelHub`, which downloads
  when offline mode is off and deletes the model folder after a failed load.
- **A data task, not a download task.** A download task keeps the body in the system's temporary folder and leaves
  it there when cancelled or cut off (checked on macOS 26).
- **One rename per model.** A model folder is never half there, so "the files exist" can be the whole definition of
  installed, with no flag to go stale.
