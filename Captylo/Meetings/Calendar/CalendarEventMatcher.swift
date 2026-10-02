import Foundation

/// Which calendar event a recording that starts "now" belongs to. Pure, so the recorder, the
/// detector and the upcoming strip agree.
enum CalendarEventMatcher {
    /// An event still counts this long after its end (calls run over).
    nonisolated static let overrun: TimeInterval = 5 * 60
    /// An event counts this long before its start (people join early).
    nonisolated static let lookAhead: TimeInterval = 10 * 60

    /// The best event for a recording at `now`: in progress (`start <= now < end + overrun`) or
    /// starting within `lookAhead`. Prefer one with a call link, then one in progress over one
    /// still to come, then the one that started most recently (or, among upcoming ones, the one
    /// that starts first), then the shorter one, then the id. All-day events never match.
    static func match(_ events: [CalendarEvent], at now: Date) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay && $0.start <= now.addingTimeInterval(lookAhead) && now < $0.end.addingTimeInterval(overrun) }
            .min { a, b in
                if a.hasCallLink != b.hasCallLink { return a.hasCallLink }
                let aRunning = a.start <= now
                let bRunning = b.start <= now
                if aRunning != bRunning { return aRunning }
                if a.start != b.start { return aRunning ? a.start > b.start : a.start < b.start }
                let aLength = a.end.timeIntervalSince(a.start)
                let bLength = b.end.timeIntervalSince(b.start)
                if aLength != bLength { return aLength < bLength }
                return a.id < b.id
            }
    }
}
