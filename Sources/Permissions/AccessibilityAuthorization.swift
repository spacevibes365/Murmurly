@preconcurrency import ApplicationServices
import Foundation

/// The only preconcurrency boundary for the legacy Accessibility C API.
enum AccessibilityAuthorization {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestSystemPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
