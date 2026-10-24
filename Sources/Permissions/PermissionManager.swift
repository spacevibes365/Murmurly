import AppKit
import AVFoundation

/// The last "Check…" of the system audio source. `succeeded` means a
/// process tap could be created then — not the recording permission, which
/// macOS asks for at the first meeting recording. Older stored values are read
/// with the same narrow meaning.
struct SystemAudioCheck: Codable, Equatable, Sendable {
    let succeeded: Bool
    let at: Date
}

/// Live Microphone + Accessibility permission status, with NO dead-ends
/// (no one-shot "already prompted" flag).
///
/// There is no reliable public per-app
/// notification for Accessibility-trust changes, and Microphone status has none
/// either. So we POLL `AXIsProcessTrusted()` + `AVCaptureDevice.authorizationStatus`
/// on a short timer while anything is missing, refresh on app-activation (catches
/// "granted in System Settings → Cmd-Tab back"), and the coordinator also refreshes
/// at the top of every recording. The `com.apple.accessibility.api` distributed
/// notification is observed only as an OPTIONAL extra trigger — never the source of truth.
@MainActor
final class PermissionManager: ObservableObject {
    typealias AccessibilityStatus = @MainActor () -> Bool
    typealias AccessibilityPrompt = @MainActor () -> Bool

    @Published private(set) var micGranted = false
    @Published private(set) var axTrusted = false
    /// Raw TCC microphone status — the menu uses it to decide whether to PROMPT
    /// (.notDetermined) or send the user to Settings (.denied/.restricted).
    @Published private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    var allGranted: Bool { micGranted && axTrusted }
    /// Only microphone access is required for dictation. Accessibility merely
    /// upgrades clipboard delivery to automatic paste and must not make the app
    /// look broken when it is unavailable.
    var needsAttention: Bool { !micGranted }

    private var timer: Timer?
    /// Guards against firing a second `requestAccess` while one prompt is already
    /// pending (a rapid double-tap would otherwise stack system prompts).
    private var micRequestInFlight = false
    @Published private(set) var accessibilityPromptAttempted = false
    private var hasLoggedStatus = false
    private var activated = false
    private let accessibilityStatus: AccessibilityStatus
    private let accessibilityPrompt: AccessibilityPrompt
    private let isRunningTests: Bool
    private let defaults: UserDefaults
    private let version: String
    /// The app version that last asked for Accessibility at launch. A value
    /// that steers the system prompt, not a flag for any window of ours.
    static let promptedVersionKey = "permissions.accessibilityPromptedVersion"

    init(
        accessibilityStatus: @escaping AccessibilityStatus = {
            AccessibilityAuthorization.isTrusted
        },
        accessibilityPrompt: @escaping AccessibilityPrompt = {
            AccessibilityAuthorization.requestSystemPrompt()
        },
        runningTests: Bool? = nil,
        processInfo: ProcessInfo = .processInfo,
        defaults: UserDefaults = TestIsolation.settingsDefaults(),
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    ) {
        self.accessibilityStatus = accessibilityStatus
        self.accessibilityPrompt = accessibilityPrompt
        isRunningTests = runningTests ?? TestIsolation.classify(processInfo: processInfo).testProcess
        self.defaults = defaults
        self.version = version
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshTrigger),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // Optional cheap trigger; we still re-read state ourselves in refresh().
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshTrigger),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    /// Launch hook owned by the menu-bar scene. The first launch never asks
    /// for Accessibility: Getting Started first says that it is optional. A
    /// new version without the grant asks once, since without a Developer ID
    /// every update changes the code hash and loses it. Otherwise only the
    /// buttons ask. The dictation hotkey must never call this method.
    func activate() {
        guard !activated else { return }
        activated = true
        refresh()
        guard !isRunningTests else {
            AppLog.info("permissions", "startup accessibility prompt skipped for testing")
            return
        }
        let prompted = defaults.string(forKey: Self.promptedVersionKey)
        guard prompted != version else { return }
        defaults.set(version, forKey: Self.promptedVersionKey)
        guard prompted != nil, !axTrusted else { return }
        promptAccessibility()
    }

    // @objc selector dispatch (incl. the cross-process distributed notification)
    // does NOT honor Swift actor isolation and may arrive off-main → hop explicitly.
    @objc private nonisolated func refreshTrigger() {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    /// Re-read both statuses and manage the poll timer.
    func refresh() {
        updateStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibility: accessibilityStatus()
        )
    }

    private func updateStatus(
        microphone: AVAuthorizationStatus,
        accessibility: Bool
    ) {
        let changed = microphone != micStatus || accessibility != axTrusted
        // @Published sends on every assignment, equal or not: each 3 s poll
        // would redraw the menu bar's menu, open or not, for nothing.
        if micStatus != microphone { micStatus = microphone }
        let granted = microphone == .authorized
        if micGranted != granted { micGranted = granted }
        if axTrusted != accessibility { axTrusted = accessibility }
        if changed || !hasLoggedStatus {
            hasLoggedStatus = true
            AppLog.info(
                "permissions",
                "microphone=\(Self.describe(microphone)) accessibility=\(accessibility)"
            )
        }
        if allGranted { stopPolling() } else { startPolling() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopPolling() { timer?.invalidate(); timer = nil }

    /// Request microphone (system prompt on first ask), then refresh. Returns granted.
    /// MUST be called only from explicit UI (menu/Settings button) — NEVER from the
    /// dictation hotkey hot-path: for an `.accessory` app the consent prompt does not
    /// reliably surface, and an unanswered `await` would wedge the caller's state.
    /// Re-entrancy-guarded so a double-tap can't stack two prompts.
    @discardableResult
    func requestMicrophone() async -> Bool {
        guard !micRequestInFlight else { return micGranted }
        micRequestInFlight = true
        defer { micRequestInFlight = false }
        NSApp.activate()
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        AppLog.info("permissions", "microphone request completed: granted=\(granted)")
        // The completion value is authoritative, while authorizationStatus can
        // lag briefly behind the system sheet. Publish it immediately and then
        // reconcile with TCC after the sheet has fully dismissed.
        if granted {
            updateStatus(microphone: .authorized, accessibility: accessibilityStatus())
        } else {
            refresh()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.refresh()
        }
        return granted
    }

    /// Surface the native Accessibility prompt — re-triggerable (no one-shot flag).
    func promptAccessibility() {
        accessibilityPromptAttempted = true
        let alreadyTrusted = accessibilityPrompt()
        AppLog.info("permissions", "accessibility prompt requested; trusted=\(alreadyTrusted)")
        refresh()
    }

    /// First click uses the native AX prompt. If trust is still absent, the next
    /// explicit click opens the Privacy pane as a reliable fallback.
    func requestOrOpenAccessibility() {
        if accessibilityPromptAttempted {
            openAccessibilitySettings()
        } else {
            promptAccessibility()
        }
    }

    func openMicrophoneSettings() { openSecurityPane("Privacy_Microphone") }
    func openAccessibilitySettings() { openSecurityPane("Privacy_Accessibility") }

    private func openSecurityPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
