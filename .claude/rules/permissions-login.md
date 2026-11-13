---
paths:
  - "Sources/Permissions/*.swift"
  - "Sources/LoginItemManager.swift"
  - "Sources/Settings/PermissionsSettingsView.swift"
  - "Tests/MurmurlyTests/LoginItemManagerTests.swift"
  - "Tests/MurmurlyUITests/SystemAudioStatusTests.swift"
---

# Permissions and the login item

Services layer. `PermissionManager` publishes the microphone and Accessibility status,
`AccessibilityAuthorization` is the one boundary to the Accessibility C API, `LoginItemManager` keeps the
login item in step with the Open at login setting.

- **Never trigger a system prompt from the dictation shortcut or any hot path.** An `.accessory` app cannot
  present one reliably, and an unanswered `await` wedges the caller. The shortcut only calls `refresh()` and
  shows a flash that points at the menu.
- **`requestMicrophone()` is called only from an explicit button.** From the menu, open Settings and await
  `AppWindowController.waitUntilPermissionPromptCanBePresented()` first: the menu's popup is still closing.
- **The Accessibility prompt at launch is steered by `permissions.accessibilityPromptedVersion` alone:** never
  at a first launch, once at the first launch of a new `CFBundleVersion` without the grant. That key is a
  value for the system prompt, not a flag for a window of ours.
- **Poll, do not subscribe.** There is no reliable notification for Accessibility trust;
  `com.apple.accessibility.api` and app activation only trigger a fresh read, and the read is the truth.
- **Assign a `@Published` status only when it changed.** Each assignment redraws the menu, and the poll runs
  every 3 s while something is missing.
- **Only the microphone makes the app need attention** (`needsAttention`). Accessibility is not part of
  dictation's readiness: without it the text stays on the clipboard.
- **System audio is never shown as granted.** "Check…" only proves that a process tap can be created; macOS
  asks for the permission at the first meeting recording.
- **Code that acts on Accessibility reads `AccessibilityAuthorization.isTrusted` itself.**
  `PermissionManager.axTrusted` is for the interface and may lag once the poll has stopped.
- **`LoginItemManager` neither reads nor changes `SMAppService` outside an installed copy or in a test
  process.** A build elsewhere shares the bundle identifier and would disturb the installed copy's item.
- **`refreshStatus()` only reads; `reconcile(desired:)` changes the system.** Back from System Settings the
  view shows what the person decided there.

How it works: `reference/app-shell.md`, "Permissions" and "Login item".
