import Foundation

/// One calendar event as the notetaker sees it; never the `EKEvent` itself (not Sendable, tied
/// to its store). Built by `EventKitSource`, matched by `CalendarEventMatcher`, kept on the
/// meeting as `calendarEventID` and `participants`. Titles and names stay on this Mac: they are
/// never logged.
struct CalendarEvent: Sendable, Equatable, Hashable, Identifiable {
    /// `EKEvent.eventIdentifier`.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarTitle: String
    /// Attendee display names, the organizer first and the user left out, at most `maxParticipants`.
    var participants: [String]
    /// "Zoom", "Meet", "Teams", ... from the URL, location and notes (`CallLinkDetector`), nil
    /// for a meeting without a video link.
    var callApp: String?

    var hasCallLink: Bool { callApp != nil }

    nonisolated static let maxParticipants = 50
}
