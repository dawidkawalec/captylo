import Foundation

/// Where `MeetingCalendar` reads events from: `EventKitSource` in the app, a fake in tests and
/// the design preview (which never touch the real calendar).
protocol CalendarEventSource: Sendable {
    /// The current permission; never prompts.
    func access() -> CalendarAccess
    /// Shows the system prompt when the user has not decided yet; returns the new state.
    func requestAccess() async -> CalendarAccess
    /// Events overlapping the window, sorted by start, all-day events left out. Empty without
    /// full access.
    func events(from: Date, to: Date) async -> [CalendarEvent]
    /// Fires when the calendar database changed (`EKEventStoreChanged`).
    var changes: AsyncStream<Void> { get }
}
