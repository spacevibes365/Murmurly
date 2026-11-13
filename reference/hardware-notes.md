# Verified on real hardware

Facts that were found by running the app on a Mac, not by reading code, and the code that exists because of
them. They do not need checking again; a change that touches the named code should keep the behaviour.

Notes about the audio capture itself (the microphone starting after the system tap, the sample rate a process
tap declares with a Bluetooth headset) are in `reference/meeting-recording.md`.

## Speech engines

- **Whisper invents subtitle phrases on silence.** Known ones are dropped after decoding
  (`WhisperSegmentDTO.removingKnownSubtitleHallucinations`), and WhisperKit runs with `chunkingStrategy: .vad`:
  with its default strategy it produced such a segment and then silently skipped real speech after it.
- **The first load of a Whisper model after its download is slow**, as Core ML builds the model for the
  device: about 100 s for large-v3 turbo on a 16 GB Apple silicon desktop, then about 2 s for every later
  load, a relaunch included. Parakeet loads in about half a second. Details: `reference/engines.md`.

## Shortcuts

- **A plain Esc registered through KeyboardShortcuts (Carbon) is taken from every app** while it is
  registered, Terminal included, and reaches them again once it is unregistered. Hence
  `DictationCoordinator` keeps it registered only while a cancel can still change something
  (`escapeCancels`).

## Windows and XCUITest

- **`.defaultLaunchBehavior(.presented)` no longer reliably shows a window under XCUITest** on current macOS.
  Both scenes are `.defaultLaunchBehavior(.suppressed)`, and UI tests open the windows through the menu bar.
- **`typeKey` and `typeText` map characters through the active keyboard layout.** On a non-Latin layout a
  shortcut such as ⌘, cannot be typed, so the UI tests that type one check the physical key first and skip.
- **`Timed out while enabling automation mode`**, with no `Executed N tests` line at all, is a hung
  `testmanagerd`. It ignores SIGTERM; `kill -9` it and launchd starts it again on demand.
- **A raw HID click from a UI test needs a runner trusted to post events.** A runner rebuilt for every run
  never is, so the one test that clicks the notepad that way skips itself there.

## Signing and privacy grants

- **macOS ties privacy grants to the exact build.** An ad-hoc build is asked for Microphone and Accessibility
  again after every rebuild; a certificate without a Team ID keeps most grants but leaves Accessibility tied
  to the binary's CDHash. Only a Developer ID build keeps them across updates.
- **A build without a Team ID cannot load the embedded `Sparkle.framework` under library validation** and
  dies at launch ("different Team IDs"), hence `com.apple.security.cs.disable-library-validation` in
  `Murmurly.entitlements`, removed again for a Developer ID release.
- **A stage-gate test bundle built into the app's own build folder breaks the next ordinary build** on code
  signing: its `.xctest` lands inside the built `.app`. Separate `-derivedDataPath` folders fix it; `clean`
  only postpones it.

## Disk images

- **A `.DS_Store` copied from another image shows no background picture on another Mac**: the picture's alias
  names the volume it was made for. `scripts/release.sh` has dmgbuild write the window for the very volume it
  creates.
- **Finder on macOS 26.5 did not resolve the bookmark dmgbuild writes beside that alias** and drew no picture
  at all, so the bookmark is turned off and Finder takes the alias.
- **Finder draws a window with a picture in the light appearance even in Dark Mode**, so the picture is light.
- **`hdiutil` now and then writes an image its own `hdiutil verify` rejects** ("chunk data starts beyond end
  of data fork"). It does not reproduce on demand; the script rebuilds the image up to three times.
- **A binary keeps the paths it was compiled at.** An image built inside a home folder carried hundreds of
  paths naming that folder; releases are therefore built in `/private/tmp` and every image is searched.

More on releases: `reference/release.md`. On tests: `reference/test-isolation.md`.
