import AppKit
import ApplicationServices
import Foundation

/// Whether a browser shows a call, read through the Accessibility grant from the titles of its
/// windows and of its tabs. A window title is the active tab's title only, so a Meet tab in the
/// background of a window would look like no call; the tab strip (Chrome, Safari, Edge, Brave,
/// Firefox: `AXRadioButton` tabs under an `AXTabGroup`) tells. Titles are only compared, never
/// logged or kept. Every read is an IPC round trip into the browser: never on the main actor.
enum BrowserCallWindows {
    enum Check: Sendable, Equatable {
        /// A window or tab title names a call service.
        case call
        /// Tabs were read and none of them names a call: the user left the call.
        case noCall
        /// No tab strip to read (one tab per window, Arc's sidebar, a browser that does not
        /// answer): nothing is known beyond the window titles, so a browser in a call keeps
        /// counting.
        case unknown
    }

    /// Elements visited per window before giving up on its tab strip; Chrome reaches its tabs
    /// in about 50, Safari in about 30, and the page and the lists are never entered.
    static let maxElements = 200
    static let maxDepth = 12
    /// Subtrees without a tab strip: the page itself, and lists like Arc's sidebar (hundreds of
    /// rows at a few milliseconds each).
    private static let skippedRoles: Set<String> = ["AXWebArea", "AXScrollArea", "AXList", "AXOutline", "AXTable"]

    /// The windows of the browser `owner`, or of `fallbackPID` when it does not run under that
    /// bundle ID.
    nonisolated static func check(owner: String, fallbackPID: pid_t) -> Check {
        var pids = NSRunningApplication.runningApplications(withBundleIdentifier: owner).map(\.processIdentifier)
        if pids.isEmpty {
            pids = [fallbackPID]
        }
        var tabsRead = false
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            // A busy browser must not hold the scan for the default ~6 s.
            AXUIElementSetMessagingTimeout(app, AXText.messagingTimeout)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement]
            else { continue }
            for window in list {
                if let title = string(window, kAXTitleAttribute), MeetingAppCatalog.isCallTitle(title) {
                    return .call
                }
                guard let tabs = tabTitles(window: window) else { continue }
                tabsRead = true
                if tabs.contains(where: MeetingAppCatalog.isCallTitle) {
                    return .call
                }
            }
        }
        return tabsRead ? .noCall : .unknown
    }

    /// Titles of the tabs in `window`'s tab strip; nil when the window shows none (one tab,
    /// or a browser without a readable strip).
    private nonisolated static func tabTitles(window: AXUIElement) -> [String]? {
        var titles: [String] = []
        var found = false
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int, inTabGroup: Bool) {
            guard visited < maxElements, let role = string(element, kAXRoleAttribute) else { return }
            visited += 1
            if skippedRoles.contains(role) { return }
            if role == kAXRadioButtonRole,
               inTabGroup || string(element, kAXSubroleAttribute) == "AXTabButton" {
                found = true
                if let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) {
                    titles.append(title)
                }
                return
            }
            guard depth < maxDepth else { return }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement]
            else { return }
            for child in list {
                walk(child, depth: depth + 1, inTabGroup: inTabGroup || role == kAXTabGroupRole)
            }
        }
        walk(window, depth: 0, inTabGroup: false)
        return found ? titles : nil
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
