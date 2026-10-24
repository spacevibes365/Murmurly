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

    /// Whether the focused element is one macOS itself calls a password field.
    /// nil: no trust, no focused element, an error or a timeout — macOS did not
    /// say, and the caller pastes as before (the promise is only about fields
    /// macOS names as secure). Never `IsSecureEventInputEnabled`: Terminal's
    /// Secure Keyboard Entry or a password manager turn it on for every field.
    static func focusedFieldIsSecure() -> Bool? {
        guard isTrusted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the process-wide timeout; this is
        // the app's only AX query. A hung app must not hold the paste, a normal
        // answer takes milliseconds.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success: return isSecureTextField(subrole: subrole as? String)
        default: return nil   // .noValue, .attributeUnsupported, .cannotComplete (timeout), .apiDisabled, …
        }
    }

    static func isSecureTextField(subrole: String?) -> Bool {
        subrole == kAXSecureTextFieldSubrole   // "AXSecureTextField"
    }
}
