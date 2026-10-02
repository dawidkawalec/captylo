import Foundation

/// A calendar with full access and a fixed list of events, never EventKit: what the design
/// preview and the unit-test host read instead of the user's calendar
/// (`AppStateOverrides.calendarEvents`).
final class FixedCalendarSource: CalendarEventSource, Sendable {
    private let fixed: [CalendarEvent]

    init(events: [CalendarEvent]) {
        fixed = events
    }

    func access() -> CalendarAccess { .fullAccess }

    func requestAccess() async -> CalendarAccess { .fullAccess }

    /// The fixed events overlapping the window, sorted by start, all-day events left out.
    func events(from: Date, to: Date) async -> [CalendarEvent] {
        fixed
            .filter { !$0.isAllDay && $0.end > from && $0.start < to }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Nothing ever changes: the stream ends at once.
    var changes: AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
