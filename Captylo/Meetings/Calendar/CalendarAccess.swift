import AppKit
import EventKit
import Foundation

/// The calendar permission as Captylo shows it. Only `fullAccess` lets events be read: on
/// macOS 14 a user who picked "Add only" in another app's prompt has `writeOnly`, which must be
/// explained, never treated as granted.
enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted

    /// `EKEventStore.authorizationStatus(for: .event)`; never prompts.
    static func current() -> CalendarAccess {
        CalendarAccess(status: EKEventStore.authorizationStatus(for: .event))
    }

    init(status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        // The deprecated `.authorized` shares `.fullAccess`'s value, so only a future state
        // lands here; treating it as undecided makes the UI ask instead of assuming.
        default: self = .notDetermined
        }
    }

    var isGranted: Bool { self == .fullAccess }

    /// The Calendars pane of Privacy & Security, where a denied or write-only grant is changed.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")!
    /// Privacy & Security itself, when the settings app refuses the anchor.
    static let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!

    @MainActor
    static func openSettings() {
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}
