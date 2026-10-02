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
}
