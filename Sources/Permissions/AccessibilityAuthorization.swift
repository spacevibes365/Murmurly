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
        // On the system-wide element this sets the process-wide timeout. A hung
        // app must not hold the paste, a normal answer takes milliseconds;
        // `MeetingPageReader.readLive` sets the same short timeout on a
        // browser's own connection for the same reason.
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

/// The live `AccessibilityPageNode`: a thin, read-only wrapper over one
/// `AXUIElement`. Kept beside `AccessibilityAuthorization` as the app's other
/// AX boundary. Every attribute read can fail or time out; a failure is
/// `nil`/empty, never thrown, so `MeetingPageReader`'s traversal reads a
/// half-answering page the same way it reads one that was never there.
struct AXPageNode: AccessibilityPageNode, @unchecked Sendable {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
        // Short-lived, like `AccessibilityAuthorization`'s own query on the
        // system-wide element: a hung tab must not hold any attribute read
        // past it, a normal answer takes milliseconds. Every page node —
        // window or descendant — is built through this initializer, so one
        // place covers every live question `MeetingPageReader` asks.
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

    var role: String {
        stringAttribute(kAXRoleAttribute as CFString) ?? ""
    }

    var axURL: String? {
        guard let value = copyAttribute(kAXURLAttribute as CFString) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    var domClassList: [String] {
        guard let value = copyAttribute("AXDOMClassList" as CFString) else { return [] }
        return (value as? [String]) ?? []
    }

    var title: String? { stringAttribute(kAXTitleAttribute as CFString) }
    var value: String? { stringAttribute(kAXValueAttribute as CFString) }
    var description: String? { stringAttribute(kAXDescriptionAttribute as CFString) }
    var identifier: String? { stringAttribute(kAXIdentifierAttribute as CFString) }
    var domIdentifier: String? { stringAttribute("AXDOMIdentifier" as CFString) }

    var children: [AccessibilityPageNode] {
        guard let value = copyAttribute(kAXChildrenAttribute as CFString),
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXPageNode(element: unsafeDowncast(item, to: AXUIElement.self))
        }
    }

    private func copyAttribute(_ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success, let result else { return nil }
        return result
    }

    private func stringAttribute(_ attribute: CFString) -> String? {
        guard let value = copyAttribute(attribute) else { return nil }
        return value as? String
    }
}
