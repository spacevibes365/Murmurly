# Murmurly 0.1.0

The first public release.

Murmurly is a dictation and meeting recorder for your Mac. Speech is recognized
on your Mac: Murmurly never uploads your recordings or text to be transcribed.

## What it does

- **Dictation into other apps.** Press ⌥Space, speak, press ⌥Space again: the
  text is pasted where your cursor is. You can change the shortcut or use a
  double press of ⌘ or ⌥ instead.
- **Meeting recording.** Recording starts on its own when another app starts
  using the microphone, or when you press ⌥⇧R. Your microphone and the call
  audio are saved as two separate tracks.
- **Transcripts.** After a meeting, Murmurly writes a transcript with
  timestamps, with your microphone and the call audio labeled separately.
- **Files.** Transcribe audio and video files: mp3, m4a, wav, mp4, mov.
- **History.** Every recognized dictation is kept in a searchable history.
- **Two speech engines.** Parakeet (about 0.5 GB, 25 European languages) or
  Whisper (about 1.6 GB, about 100 languages). Models download from Hugging
  Face only when you ask.
- **Interface in 12 languages.** All translations except English and Russian
  were made by machine; corrections are welcome.
- **Automatic updates.** Murmurly checks GitHub for a new version once a day;
  you can turn this off in Settings → Permissions. An update you choose while a
  meeting is being recorded or transcribed, a file is being transcribed, or
  during a dictation, is installed when you quit instead of restarting the app.

## Requirements

- A Mac with Apple silicon.
- macOS 15 Sequoia or later.

## Before you start

- **Automatic meeting recording is on by default.** In many countries,
  recording a conversation requires the consent of everyone in it, and Murmurly
  does not notify other participants. You can turn automatic recording off on
  the first screen or in Settings → Meetings.
- **If macOS won't open the app,** this release is not signed with a Developer
  ID. Try to open it once, then open System Settings → Privacy & Security and
  click **Open Anyway**. With such a release you may need to grant the
  permissions again after each update.

## Known limitations

- The other participants' voices are not told apart: everyone on the other side
  is "Others".
- Dictation and meeting recording never run at the same time. One dictation
  lasts at most 5 minutes; an automatic meeting recording at most 4 hours.
- A meeting transcription does not resume after quitting. Choosing Quit during
  a transcription, or while its transcript is copied to your transcript folder,
  warns first; logging out, restarting or shutting down the Mac interrupts it
  without a warning. Use **Transcribe Meeting…** to transcribe it
  later.
- Removing duplicated speech from the transcript does not work for languages
  written without spaces, such as Chinese and Japanese.
- ⌥Space is also the default shortcut of ChatGPT for Mac. If you use both,
  change one of them.

The full list is in the
[README](https://github.com/spacevibes365/Murmurly#known-limitations).
