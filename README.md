# Murmurly

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/hero-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/hero-light.png">
  <img alt="Murmurly's settings window on the Dictation tab, with the speech model ready, next to the Murmurly menu open in the macOS menu bar" src="docs/hero-light.png">
</picture>

Murmurly is a dictation and meeting recorder for your Mac. Speech is recognized
on your Mac: Murmurly never uploads your recordings or text to be transcribed.

- **Dictate into other apps.** Press ⌥Space, speak, press ⌥Space again: the
  text is pasted where your cursor is.
- **Record calls on their own.** When another app starts using the microphone,
  Murmurly records two separate tracks: your microphone, and the sound of the
  call.
- **Get a transcript.** When the call ends, Murmurly transcribes it into a text
  file with timestamps, where your microphone and the call audio are labeled
  separately.

## Features

- Dictation into any text field that accepts pasting, with a keyboard shortcut
  or a double press of ⌘ or ⌥.
- Automatic meeting recording when another app takes the microphone, or manual
  recording with ⌥⇧R.
- Your microphone and the call audio are saved as separate tracks, so the
  transcript can tell them apart.
- Automatic transcription after meetings, on by default.
- Transcription of audio and video files: mp3, m4a, wav, mp4, mov.
- Dictation history with search.
- Two speech engines: Parakeet (25 European languages) and Whisper (about 100
  languages).
- Finished recordings are stored as 24-bit Apple Lossless.
- Optional: move finished meetings to an external drive or a network folder, and
  copy each transcript into your notes folder.
- Interface in 12 languages.
- Automatic updates.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia or later. Tested on macOS 26.
- Free disk space for the speech model: about 0.5 GB for Parakeet or 1.6 GB
  for Whisper, plus room for your recordings.

**How long transcription takes.** One measurement on one Mac (Apple M4, 16 GB,
macOS 26.5): a 97-minute meeting recording, two tracks, was transcribed in
1 min 49 s with Parakeet and in 13 min 2 s with Whisper large-v3 turbo. Other
Macs and recordings will take different times.

**The first start of a model.** Before a downloaded model is first used, macOS
prepares it for your Mac. Murmurly starts this in the background right after
the download and at each launch, for the selected engine. On the same Mac this
took about 15 seconds for Parakeet and about 2 minutes for Whisper large-v3
turbo; later starts take a few seconds at most. After an update, macOS may
prepare the model again. Until it is ready, the menu says so and the first
dictation waits for it.

## Installation

1. Download the latest `.dmg` from the
   [Releases](https://github.com/spacevibes365/Murmurly/releases) page.
2. Open it and, in its window, drag the **Murmurly** icon onto the
   **Applications** icon.
3. Open Murmurly from Applications. macOS blocks the first launch: see
   [If macOS won't open the app](#if-macos-wont-open-the-app).

**On a standard (non-administrator) account**, copying into Applications asks
for an administrator's name and password. Click **Cancel** and use an
Applications folder in your home folder instead: in Finder, choose **Go →
Home**; if there is no **Applications** folder, choose **File → New Folder**
and name it `Applications`. Drag **Murmurly** from the disk image into it and
open it from there. Murmurly works the same from either folder.

Murmurly lives in the menu bar. It has no Dock icon: one appears only while one
of its windows is open.

### If macOS won't open the app

Murmurly releases are not signed with a Developer ID or notarized by Apple yet;
their file names end in `-unsigned`. macOS blocks the first launch of such an
app. To allow it:

1. Open Murmurly once. macOS says *“Murmurly” Not Opened*: click **Done**.
   Not **Move to Trash**: it is the default button, so pressing Return moves
   the app to the Trash.
2. Open **System Settings → Privacy & Security**, scroll down to *“Murmurly”
   was blocked to protect your Mac.* and click **Open Anyway**.
3. macOS asks *Open “Murmurly”?*: click **Open Anyway**. Here too, **Move to
   Trash** is the default button.
4. Enter your password. On a standard account, macOS asks for an
   administrator's name and password instead.

**Without an administrator password.** If you installed Murmurly in the
Applications folder of your home folder, you can allow it in Terminal instead
(**Applications → Utilities → Terminal**):

```sh
xattr -dr com.apple.quarantine ~/Applications/Murmurly.app
```

Then open Murmurly as usual. The command removes the mark that macOS puts on
downloaded files and that makes it check the app before the first launch, so do
this only with a copy from the Releases page.

Without a Developer ID, macOS also treats each update as a new app. You may
need to grant the microphone, Accessibility and system audio permissions again
after an update: if recording or pasting stops working, check **System
Settings → Privacy & Security**.

### Updates

Murmurly checks for updates right after its first launch and then once a day,
without asking first, and offers to install a new version with one click.
**Check for Updates…** in the menu checks right away. To turn automatic checks
off, use the **Check automatically** switch in **Settings → Permissions →
Updates**; your version of Murmurly is shown there too.

A check downloads the list of releases (`appcast.xml`) from GitHub; installing
downloads the new version from there too. Murmurly does not send a profile of
your Mac (the optional system profile of Sparkle, the update library, is off).
As with any download, GitHub sees your IP address and the request's standard
headers, which name Murmurly, its version and the version of Sparkle. Your
recordings, dictations and transcripts are never part of an update. Updates are
signed, and Murmurly refuses one whose signature does not match.

**Installing during work.** If you choose **Install and Relaunch** while a
meeting is being recorded or transcribed (its transcript copy included), a
dictation is running or a file is being transcribed in **Settings → Files**,
Murmurly does not restart. The update window closes, and the menu and
**Settings → Permissions → Updates** say "The update will be installed when you
quit the app". It is installed the next time you quit Murmurly, or you can
choose **Check for Updates…** again when the work is done and pick **Install and
Relaunch** or **Install on Quit**. If **Files** holds text you have not saved,
the quit that would install the update stops with the usual warning, and the
menu says the same; save the text, then quit.

## Getting started

On the first launch Murmurly opens a **Getting Started** screen with five
numbered steps. The model step is checked once the model is ready, and each
permission shows whether it is granted:

1. **Download a speech model.** Parakeet (about 0.5 GB) is the default and
   covers 25 European languages. Whisper (about 1.6 GB) is for other languages.
   You can switch engines at any time in **Settings → Dictation**; each engine
   needs its own model. A small speech-detection model (1 MB) comes along with
   either one.
2. **Permissions.**
   - **Microphone.** Without it, neither dictation nor meeting recording works.
   - **Accessibility (optional).** Murmurly needs it to paste the text into the
     app you are typing in. Without it, the text stays on the clipboard and you
     paste it with ⌘V. On the first launch Murmurly does not ask on its own;
     click **Grant…** when you want it.
   - **System audio recording.** Recording the other side of a call needs a
     macOS permission, which macOS asks for at the first meeting recording.
     **Check…** only shows that Murmurly can create an audio source; it does not
     confirm the permission.
3. **Try dictation.** The screen shows the shortcut or double press you set.
4. **Automatic recording** of meetings is on. Read what it records (see below),
   and turn it off right there if you don't want it.
5. **Startup:** Open at login is on. On the first launch Murmurly adds itself
   to the login items, and macOS shows a “Login Item Added” notification. Turn
   it off right there or in **Settings → Permissions**.

Models download from Hugging Face only when you ask. The first time a model is
used, macOS prepares it for your Mac, which takes a while. If that fails,
**Settings → Dictation** and the menu say so; **Try Again** prepares it again,
and if it keeps failing, move the model folder (**Show in Finder**) to the
Trash and download the model again.

After an update, macOS may drop the Accessibility permission (see
[If macOS won't open the app](#if-macos-wont-open-the-app)). If it did, Murmurly
asks for it once, at the first launch of the new version.

Murmurly starts when you log in. You can turn that off in **Settings →
Permissions**.

## Dictation

- Press **⌥Space**, speak, and press **⌥Space** again. The text is pasted into
  the app that was in front. Murmurly then puts back what was on your clipboard,
  unless you copied something else in the meantime.
- If the text does not appear (the field does not accept pasting), it is in the
  history and, without auto-paste, on the clipboard.
- One dictation can last up to 5 minutes; the last 30 seconds are counted down
  on the recording indicator. At the limit the recording stops, what you said
  is recognized and pasted, and Murmurly says it stopped at the 5-minute limit;
  start a new dictation to go on.
- Dictation is not available while a meeting is being recorded, and a meeting
  recording does not start during a dictation: both need the microphone.
- To change the shortcut, open **Settings → Dictation**. You can also start
  dictation with a double press of the left or right ⌘ or ⌥ key, and stop it
  with a single press. This mode needs Accessibility; until it is granted, only
  the backup shortcut works, if you set one, and Settings says so.
- Choose the language in the menu (**Dictation Language**: Auto, the current
  language, **More Languages…**) or in **Settings → Dictation**, where you can
  search the list. **Auto** lets the engine decide.
- The text of each recognized dictation is saved to the history (**Settings →
  History**), where you can search it. **Clear history** (the trash button
  above the list) deletes all dictations and their audio.

### Dictation audio

By default Murmurly keeps the text of your dictations, but not the audio. To
keep the audio too, turn on **Save dictation audio** in **Settings → Dictation**.

Even with this switch off, Murmurly tries to keep the audio when recognition fails,
when the recording is cut off, or when you quit during a dictation. A dictation
that could not be recognized appears in the history as "— not recognized —"
with its audio, so you can listen to it or transcribe it again: **Show in
Finder** (the folder button in its row) shows the audio file, which you can drop
into **Settings → Files**. Nothing is pasted in that case.

If the history itself cannot be written, the dictation stays under **Unsaved
Dictations** in the menu until you quit: a recognized one with its text, which
is still pasted, an unrecognized one with its audio.

## Meeting recording

**When it records.** Recording starts on its own when another app starts using
the microphone: a call in Zoom, Google Meet, Telegram or a browser. Any app that
takes the microphone counts, including a voice message or another dictation app.
System Settings is the exception: checking your microphone in **System Settings
→ Sound** does not start a recording.

**When it stops.** An automatic recording stops 30 seconds after no app (other
than excluded ones) is using the microphone any more, when the Mac goes to
sleep, or after 4 hours. At the 4-hour limit the recording is saved, and the
menu says it stopped at the limit; start a new recording to go on. **Settings →
Meetings** explains these limits too.

**What it records.** Your microphone, and all sound your Mac plays — not only
the call app.

**Manual recording.** Press **⌥⇧R** or choose **Record Meeting** in the menu.
A recording you started yourself has no time limit and does not stop when the
call ends: it stops when you stop it or when the Mac goes to sleep. You can
change the shortcut in **Settings → Meetings**.

> **Consent.** In many countries, recording a conversation requires the consent
> of everyone in it. Murmurly does not notify other participants. Obtain any
> required consent before you turn on automatic recording or join a call.
>
> To turn automatic recording off, use the switch in the menu or in
> **Settings → Meetings**.

**System audio permission.** macOS asks for permission to record system audio
the first time Murmurly records a meeting. The recording starts only after you
allow it: nothing is recorded while the request is on screen. If a recording
fails (for example, because this permission was denied), the menu says why and
what to do: check **Settings → Permissions**, then choose **Record Meeting** to
record the current call. Murmurly does not retry on its own for an app whose
recording failed.

**Excluding an app.** While an app is being recorded, the menu offers **Exclude
<app> from Auto-Recording**; the list of excluded apps is in **Settings →
Meetings**. Excluding an app keeps it from starting future recordings, and can
stop the current automatic recording if no other app needs the microphone. It
does not filter that app's sound out of other recordings, because system audio
is recorded as a whole.

### Where recordings are kept

By default each meeting is a folder in
`~/Library/Application Support/Murmurly/Meetings/`, named by date and time:

| File | What it is |
|---|---|
| `microphone.m4a` (or `.caf`) | Your microphone |
| `system.m4a` (or `.caf`) | Everything your Mac played: the call |
| `transcript.md` | The transcript, when speech was recognized and transcription finished. Check it for warnings about missing parts. |
| `metadata.json` | Technical details of the recording |

Tracks are written as `.caf` during the call. Finished tracks are stored as
24-bit Apple Lossless (`.m4a`); if compression cannot be completed safely, the
original `.caf` is kept.

**Show Last Recording…** in the menu opens the folder of the latest recording,
and **Show Meetings Folder** opens the folder with all of them: the one you
chose in **Settings → Storage**, or, if it is not available right now, Storage
settings, so you can see why.

In **Settings → Storage** you can have finished meetings moved to another
folder, such as an external drive or a network share, and have each new
transcript copied into a folder of your choice, such as your notes app's
folder. The copy is named after the meeting, for example
`2026-10-09 14-30-00 Meeting.md`, whatever the interface language. Neither
folder can be the dictations folder or a folder inside it. **Show in Finder**
next to each chosen folder shows it, when Murmurly last found it available; it
checks again when you come back to Murmurly or connect or eject a disk.
Recording itself always happens on your Mac. While the other folder
is not available, meetings wait on your Mac and Storage says why; they move by
themselves at launch, when a disk is connected and after each recording, and
**Move Now** tries right away.

### Transcripts

After a meeting, Murmurly transcribes it automatically (you can turn this off
in **Settings → Meetings**). `transcript.md` is plain text with timestamps. It
labels speech by where it was recorded, not by who spoke:

- **Me** — what your microphone heard;
- **Others** — what came through system audio.

Murmurly does not tell the other participants' voices apart: everyone on the
other side is "Others".

If you use speakers instead of headphones, your microphone also hears the other
side. Murmurly tries to remove this duplicated speech from the microphone's part
of the transcript; the recorded audio is not changed.

**Keep Murmurly running until the transcription finishes.** A transcription
that quitting interrupts does not resume on its own, and a meeting that was
still recording when you quit is saved but not transcribed. So when you quit
during a meeting transcription, while a finished transcript is being copied to
your transcript folder (**Settings → Storage**; that copy is not made again
later), or while recording a meeting that would be transcribed afterwards,
Murmurly stays open and says what would be lost; quit again within 10 seconds
to quit anyway. Logging out, restarting or shutting down the Mac does not wait
for this. To transcribe such a meeting later, choose **Transcribe Meeting…** in
the menu and pick the meeting's folder; a stopped copy is not redone, but the
transcript stays in the meeting folder.

If no model is downloaded yet, the recording is still saved. Download a model,
then use **Transcribe Meeting…** the same way.

## Transcribing files

Choose **Transcribe a File…** in the menu (it opens **Settings → Files**) and
drop in an audio or video file (mp3, m4a, wav, mp4, mov), or click **Choose
File…** or the drop area to choose one, then **Transcribe**. Murmurly uses the
same engine and language as for dictation (the tab's header names them), shows
each step (the first preparation of a model can take a couple of minutes), and
then the text with timestamps. To transcribe another file, drop it onto the
text or choose it again.

The result is not added to the dictation history or saved automatically. It is
kept in the app until you quit, as the note under the text reminds you; save
it as a `.md` file to keep it. Copying it does not count as saving. Closing the
window neither stops a transcription nor loses its text; open **Files** again
to find it. Before a new file or a new run replaces text you have not saved,
Murmurly asks: **Save .md…**, **Replace** or **Cancel**. Cancelling a
transcription in progress discards what it had recognized so far.

Quitting while a file is being transcribed, or while **Files** holds text you
have not saved, warns first; quit again within 10 seconds to quit anyway.
Logging out, restarting or shutting down the Mac does not wait for this.

If parts of a file cannot be recognized, or a recognition error stops the
transcription partway, the text recognized so far is kept, with a note at the
top that says what is missing. If nothing was recognized yet, you see the error
instead. Transcription never writes beside the input file; you choose where to
save the `.md`.

## Languages

**Interface.** English, Russian, Spanish, German, French, Portuguese (Brazil),
Italian, Ukrainian, Polish, Chinese (Simplified), Japanese and Korean. English
is the original, and the Russian translation has been checked by a native
speaker. The other ten are machine translations that no native speaker has
checked yet; if you can help, see [Contributing](#contributing). Murmurly
follows the language of macOS. To use a different language for Murmurly alone,
open **System Settings → General → Language & Region → Applications**.

**Speech recognition.**

- **Parakeet** (default): 25 European languages — Bulgarian, Croatian, Czech,
  Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian,
  Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian,
  Slovak, Slovenian, Spanish, Swedish and Ukrainian.
- **Whisper**: about 100 languages.

With **Auto**, the engine decides. In meetings and files, Whisper uses Auto
until the first successfully recognized stretch of speech longer than 5 seconds,
then keeps that language for the rest of the transcription. "First" means
processing order: for a meeting, the microphone track is processed before the
system audio track. Until then, shorter stretches still get transcribed on Auto;
if no such long stretch is found, Auto is used throughout. This does not detect
language changes during a conversation. If you always speak one language,
choosing it explicitly gives the most reliable result.

With Parakeet, choosing a language also limits the alphabet. With **Russian**,
for example, English words and names come out in Cyrillic. **Auto** has no such
limit, so a mixed conversation keeps English terms in Latin letters, but a few
short replies may come out in the wrong alphabet.

If you switch to an engine that does not know the language you chose, it uses
Auto; your choice is kept for the other engine, and **Settings → Dictation**
says so under the language list.

## Privacy

- Speech is recognized on your Mac. Murmurly does not upload recordings or text
  to be transcribed. There are no accounts and no analytics.
- Murmurly itself goes online only for two things: to download a model from
  Hugging Face when you ask, and to check GitHub for updates once a day and
  download them. The update check is on by default and can be turned off; see
  [Updates](#updates) for what it reveals.
- Your files go only where you put them. Murmurly keeps them in these default
  locations on your Mac:
  - dictations: `~/Library/Application Support/Murmurly/Dictations/`
    (the history is a plain `history.jsonl` file, one dictation per line);
  - meetings: `~/Library/Application Support/Murmurly/Meetings/`;
  - models: `~/Library/Application Support/Murmurly/Models/`.

  If you choose a network or cloud-synced folder for meetings or transcript
  copies in **Settings → Storage**, recordings and transcripts go there too.
- Automatic pasting and the clipboard fallback use a clipboard restricted to
  this Mac. Once pasted, text is handled by the destination app, which may sync
  or send it. Text you copy yourself with a **Copy** button uses the regular
  clipboard, which macOS may share with your other devices through Universal
  Clipboard.
- The log (`~/Library/Logs/Murmurly/`, also **Show Log in Finder** in **Settings
  → Permissions**) contains file names and folder paths. Check it before you
  attach it to a bug report.

## Known limitations

- The other participants' voices are not told apart: everyone on the other side
  is "Others".
- Removing duplicated speech does not work for languages written without spaces
  between words, such as Chinese and Japanese.
- Dictation and meeting recording never run at the same time.
- One dictation lasts at most 5 minutes; an automatic meeting recording at most
  4 hours.
- A meeting transcription that was interrupted by quitting does not resume on
  its own; start it again with **Transcribe Meeting…**. Logging out, restarting
  or shutting down the Mac interrupts it without a warning.
- File transcripts are kept only until you quit Murmurly (it warns about
  unsaved text when you choose Quit); save them as `.md`.
- A meeting records the microphone that was the default when it started.
  Switching audio devices during a recording (for example, putting on AirPods)
  is not followed. A dictation cut off by such a switch is saved to the history
  but not pasted.
- If a meeting's microphone drops out for a moment, as Bluetooth headsets
  sometimes do, that moment is left out of both tracks so they stay in step.
  The recording is saved with a warning that says about how many seconds are
  missing, and is transcribed as usual. If the microphone disconnects and does
  not come back, nothing more is recorded, not even the system audio, until
  the recording stops, although Murmurly still shows it as recording. It is
  saved with a warning that gives the time the microphone dropped out, and
  what was recorded before that is transcribed as usual. If another device
  takes the headset over (for example, the same AirPods connect to another
  Mac), the microphone may send only silence instead; the recording is then
  saved with a warning that says how long the silence lasted and when.
- ⌥Space is also the default shortcut of ChatGPT for Mac. If you use both,
  change one of them (**Settings → Dictation**).
- Excluding an app from automatic recording does not remove its sound from
  recordings started by another app.
- Excluding an app stops the current recording at once only when no other app
  holds the microphone. If one does, the recording either goes on for that app
  or stops about 30 seconds later.
- In browsers, the microphone belongs to a helper process shared by all tabs
  (for example `com.apple.WebKit.GPU` for Safari, or a Chrome helper). The menu
  may show that helper instead of the browser's name, and excluding it excludes
  every call in that browser.
- Releases without a Developer ID may need the permissions granted again after
  each update.

## Building from source

You need a Mac with Apple silicon, the full Xcode 26 or later (not only the
Command Line Tools; Xcode 26 itself needs macOS 15.6 or later) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/spacevibes365/Murmurly.git
cd Murmurly
xcodegen generate
open Murmurly.xcodeproj
```

The Xcode project is generated from `project.yml` and is not stored in git. Run
`xcodegen generate` again after changing `project.yml` or adding files.

**Signing.** A fresh clone signs ad-hoc, so it builds for anyone. The catch:
macOS ties permissions to the exact build, so you may need to grant them again
after every rebuild. To keep them, create a code signing certificate in your
login keychain (Keychain Access → Certificate Assistant → Create a
Certificate…, type "Code Signing") and name it in a `Local.xcconfig` next to
`Signing.xcconfig` (git ignores it):

```
MURMURLY_CODE_SIGN_IDENTITY = My Code Signing Certificate
```

Without an Apple Team ID, Accessibility may still need to be turned on again
after a rebuild.

**Updates in your own build.** `Signing.xcconfig` also holds three update
settings: the feed address (`MURMURLY_SU_FEED_URL`), the download address
(`MURMURLY_SU_DOWNLOAD_BASE`) and the public key that updates must be signed
with (`MURMURLY_SU_PUBLIC_KEY`). With an empty key, the updater does not
start. If you publish your own builds, set all three to your own values;
otherwise your builds would offer the official Murmurly releases as updates.
`scripts/release.sh` explains how to create a key. To keep updates off in a
build for yourself, put an empty `MURMURLY_SU_PUBLIC_KEY =` into
`Local.xcconfig`.

**Tests.**

```sh
xcodebuild -project Murmurly.xcodeproj -scheme Murmurly \
  -destination 'platform=macOS,arch=arm64' -only-testing:MurmurlyTests test
```

Without `-only-testing` the UI tests run too. The separate `MurmurlyStageGate`
scheme runs the app as shipped, with real models, the real microphone and system
audio and real global shortcuts. It is not part of the regular run; its
real-audio tests also need downloaded models and audio files that are not in the
repository.

**Scripts.**

- `scripts/install.sh` builds a Release copy and installs it into
  `~/Applications`, replacing the previous copy after it has quit. It refuses to
  run if a copy is already installed in `/Applications`.
- `scripts/release.sh` builds the DMG. Without arguments it is ad-hoc signed and
  named `…-unsigned.dmg`. With `DEVELOPER_ID` and `NOTARY_PROFILE` set, it is
  signed, notarized and stapled, and any failure stops the release. It also
  writes the signed `appcast.xml` to publish next to the DMG, but only when the
  build has a public update key, the matching private key is available and
  Sparkle's tools were fetched; then it prints `Appcast ready`. Otherwise it
  prints `No appcast` and the reason, and the DMG alone is ready: check for
  `Appcast ready` before you publish an update.

**Build settings.** Swift 6 with strict concurrency checking, and warnings are
errors: a build with any warning in the project's code fails. App Sandbox is
off: the system audio tap and pasting into other apps need a design of their own
before it can be turned on.

### How it works

- A menu bar app with two recording modes that never run at once: dictation and
  meetings.
- Meetings use a Core Audio process tap for system audio, with the microphone in
  the same device, so both tracks run on one clock.
- Automatic recording watches which processes use audio input. Watching needs no
  permission; recording itself still needs the microphone and system audio
  permissions.
- Speech recognition: [FluidAudio](https://github.com/FluidInference/FluidAudio)
  runs Parakeet and the speech detector, [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
  runs Whisper. Both work offline; models are downloaded by the app's own small
  downloader, pinned to exact revisions and checked after download.

More detail for contributors is in [CLAUDE.md](CLAUDE.md).

## Contributing

Bug reports and pull requests are welcome. For a bug, use the bug report
template: it asks for your macOS version, Mac model, app version, the speech
engine, and the relevant part of the log with personal names and paths removed.
Before opening a pull request, run the unit tests and make sure the build has no
warnings. Code comments are in English and explain *why*, not *what*.

**Translations.** Interface translations live in
`Resources/Localizable.xcstrings` (and `Resources/InfoPlist.xcstrings` for the
permission prompts) and can be edited in Xcode. The machine translations are
marked *Needs Review*. If you are a native speaker, correct the strings of your
language and mark them as reviewed; a pull request for one language is welcome.

## Security

Please do not report security issues in public issues. Report them privately
through GitHub: the repository's **Security** tab → **Report a vulnerability**.

## License

Murmurly is released under the [MIT License](LICENSE). Copyright © 2026 Denis
Andryushin.

The speech models are not part of Murmurly. They are downloaded from Hugging
Face and keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

Murmurly is built on the work of others:

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference
- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by
  NVIDIA, licensed under CC BY 4.0
- [Whisper](https://github.com/openai/whisper) by OpenAI
- [Silero VAD](https://github.com/snakers4/silero-vad) by the Silero Team
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre
  Sorhus
- [Sparkle](https://sparkle-project.org)

Full license texts and attributions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
