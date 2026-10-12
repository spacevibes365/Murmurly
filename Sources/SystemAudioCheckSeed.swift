#if DEBUG
import Foundation

/// UI-test seed for the stored system audio check, enabled only with
/// `-SeedSystemAudioCheck none|created|failed`. It writes the stored result
/// into the isolated settings before any view reads them, with a fixed date.
/// It holds no display logic, so the same file builds on the tree before the
/// fix for the red check.
@MainActor
enum SystemAudioCheckSeed {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func apply(to settings: SettingsStore) {
        // Only an isolated test copy: one stray argument must never write the
        // preferences of an ordinary DEBUG build.
        guard TestIsolation.isEnabled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SeedSystemAudioCheck"),
              index + 1 < arguments.count else { return }
        switch arguments[index + 1] {
        case "created": settings.systemAudioCheck = SystemAudioCheck(succeeded: true, at: date)
        case "failed": settings.systemAudioCheck = SystemAudioCheck(succeeded: false, at: date)
        default: settings.systemAudioCheck = nil
        }
    }
}
#endif
