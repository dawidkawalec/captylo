import AppKit
import ApplicationServices

/// An `AXUIElement` handed to a background task. AX elements are CF objects the Accessibility
/// API accepts from any thread; Swift just cannot see that.
struct AXElementRef: @unchecked Sendable {
    let element: AXUIElement
}

/// Read-only access to the text field that has keyboard focus, through the Accessibility API
/// (the grant Captylo already needs for Cmd+V). Used by `--ax-probe` and the self-learning edit
/// watcher. Secure fields are never read. Not tied to the main actor: every call is an IPC round
/// trip to another app, so `EditWatcher` runs them off the main actor with a deadline.
enum AXText {
    /// Fields longer than this are reported but their text is not copied.
    static let maxLength = 50_000
    /// Per-call limit for every AX request of this process. The default is about 6 s, and a
    /// busy or closed web view (a Safari tab that just closed) would hold the main actor that long.
    static let messagingTimeout: Float = 0.5

    private static let timeoutApplied: Bool = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout) == .success
    }()

    /// Applies `messagingTimeout` once (setting it on the system-wide element covers all elements).
    private static func applyTimeout() {
        _ = timeoutApplied
    }

    struct Snapshot: Sendable, Equatable {
        var pid: pid_t
        var bundleID: String?
        var appName: String?
        var role: String?
        var subrole: String?
        var isSecure: Bool
        /// Character count from `AXNumberOfCharacters`, or of `value` when the app does not report it.
        var length: Int?
        /// Nil for secure fields, fields over `maxLength` and elements without a string value.
        var value: String?
        /// `AXSelectedTextRange` in UTF-16 units (the caret when `length == 0`).
        var selection: NSRange?
    }

    /// The focused UI element: asked of the frontmost app first (Electron apps answer there once
    /// `enableManualAccessibility` ran), then of the system-wide element.
    static func focusedElement() -> AXUIElement? {
        focusedElement(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// The focused element of the app `pid` (the frontmost app, read by the caller on the main
    /// actor), else of the system-wide element.
    static func focusedElement(pid: pid_t?) -> AXUIElement? {
        applyTimeout()
        if let pid, let element = focusedChild(of: AXUIElementCreateApplication(pid)) {
            return element
        }
        return focusedChild(of: AXUIElementCreateSystemWide())
    }

    /// Only `AXValue` (one round trip), for polling a field already known not to be secure.
    static func value(of element: AXUIElement) -> String? {
        applyTimeout()
        guard let text = copyAttribute(element, kAXValueAttribute) as? String, text.utf16.count <= maxLength else { return nil }
        return text
    }

    private static func focusedChild(of element: AXUIElement) -> AXUIElement? {
        guard let ref = copyAttribute(element, kAXFocusedUIElementAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Snapshot of the focused element; nil when there is none.
    static func focusedSnapshot() -> Snapshot? {
        guard let element = focusedElement() else { return nil }
        return snapshot(of: element)
    }

    static func snapshot(of element: AXUIElement) -> Snapshot {
        applyTimeout()
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let role = copyAttribute(element, kAXRoleAttribute) as? String
        let subrole = copyAttribute(element, kAXSubroleAttribute) as? String
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String)

        var length = (copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        var value: String?
        if !isSecure, (length ?? 0) <= maxLength, let text = copyAttribute(element, kAXValueAttribute) as? String {
            if text.utf16.count <= maxLength {
                value = text
            }
            length = length ?? text.utf16.count
        }

        return Snapshot(
            pid: pid,
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            role: role,
            subrole: subrole,
            isSecure: isSecure,
            length: length,
            value: value,
            selection: isSecure ? nil : selectedRange(of: element)
        )
    }

    /// Asks an Electron / Chromium app to build its accessibility tree (Slack, VS Code, Discord
    /// only expose text fields after this). Returns true when the app accepted the attribute.
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        applyTimeout()
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// Chrome and Edge ignore `AXManualAccessibility` and build their web accessibility tree only
    /// for `AXEnhancedUserInterface` (what VoiceOver sets). Returns true when accepted.
    @discardableResult
    static func enableEnhancedUserInterface(pid: pid_t) -> Bool {
        applyTimeout()
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
    }

    /// The element's own `AXFocused`; nil when it does not answer (dead or unsupported).
    /// Chrome keeps reporting a closed tab's field as the app's focused element, but the field
    /// itself stops saying it is focused.
    static func isFocused(_ element: AXUIElement) -> Bool? {
        applyTimeout()
        return (copyAttribute(element, kAXFocusedAttribute) as? NSNumber)?.boolValue
    }

    // MARK: - Helpers

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let ref = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
