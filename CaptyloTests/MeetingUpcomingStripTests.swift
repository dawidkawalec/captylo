import Foundation
import Testing
@testable import Captylo

/// The "Nadchodzące" strip's pure helpers: which events it shows and how it writes the time.
struct MeetingUpcomingStripTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, startsIn minutes: Double, lasts length: Double = 30, allDay: Bool = false, callApp: String? = nil) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(
            id: id, title: "Wydarzenie \(id)", start: start, end: start.addingTimeInterval(length * 60),
            isAllDay: allDay, calendarTitle: "Praca", participants: [], callApp: callApp
        )
    }

    @Test func showsTheSoonestThreeThatHaveNotEnded() {
        let events = [
            event("ended", startsIn: -60, lasts: 30),
            event("running", startsIn: -10),
            event("soon", startsIn: 25),
            event("later", startsIn: 120),
            event("evening", startsIn: 300),
        ]
        #expect(UpcomingMeetingsStrip.visible(events.shuffled(), now: now).map(\.id) == ["running", "soon", "later"])
    }

    @Test func leavesOutAllDayEventsAndAnythingBeyondTwelveHours() {
        let events = [
            event("allday", startsIn: 10, lasts: 24 * 60, allDay: true),
            event("tomorrow", startsIn: 13 * 60),
            event("soon", startsIn: 25),
        ]
        #expect(UpcomingMeetingsStrip.visible(events, now: now).map(\.id) == ["soon"])
        #expect(UpcomingMeetingsStrip.visible([], now: now).isEmpty)
    }

    @Test func timeReadsAsHoursAndMinutes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 5))!
        #expect(UpcomingMeetingsStrip.time(date, locale: Locale(identifier: "pl_PL"), calendar: calendar) == "14:05")
        #expect(UpcomingMeetingsStrip.time(date, locale: Locale(identifier: "en_GB"), calendar: calendar) == "14:05")
    }

    @Test func inProgressIsDecidedByTheStart() {
        #expect(UpcomingMeetingsStrip.isInProgress(event("running", startsIn: -1), now: now))
        #expect(!UpcomingMeetingsStrip.isInProgress(event("soon", startsIn: 1), now: now))
    }

    /// The settings row explains every state in which the calendar cannot be read.
    @Test func settingsExplainEveryBlockedAccessState() {
        #expect(MeetingsSettingsPanel.calendarStatusText(for: .fullAccess) == nil)
        #expect(MeetingsSettingsPanel.calendarStatusText(for: .notDetermined) == nil)
        #expect(MeetingsSettingsPanel.calendarStatusText(for: .denied) == String(localized: "Brak dostępu do kalendarza. Zezwól w Ustawieniach systemowych."))
        #expect(MeetingsSettingsPanel.calendarStatusText(for: .restricted) == String(localized: "Brak dostępu do kalendarza. Zezwól w Ustawieniach systemowych."))
        #expect(MeetingsSettingsPanel.calendarStatusText(for: .writeOnly) == String(localized: "Captylo ma tylko dostęp do zapisu. Włącz pełny dostęp."))
        #expect(MeetingsSettingsPanel.reminderMinutesTitle(0) == String(localized: "W chwili startu"))
        #expect(MeetingsSettingsPanel.reminderMinutesTitle(5) == String(localized: "5 min"))
        #expect(CalendarAccess.settingsURL.scheme == "x-apple.systempreferences")
    }
}
