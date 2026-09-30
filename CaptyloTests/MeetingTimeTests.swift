import Foundation
import Testing
@testable import Captylo

struct MeetingTimeTests {
    @Test func clockUsesHoursOnlyWhenNeeded() {
        #expect(MeetingTime.clock(0) == "0:00")
        #expect(MeetingTime.clock(59.9) == "0:59")
        #expect(MeetingTime.clock(754) == "12:34")
        #expect(MeetingTime.clock(3723) == "1:02:03")
        #expect(MeetingTime.clock(7200) == "2:00:00")
    }

    @Test func stampIsTheBracketedClock() {
        #expect(MeetingTime.stamp(754) == "[12:34]")
        #expect(MeetingTime.stamp(3723) == "[1:02:03]")
    }

    @Test func negativeAndNonFiniteValuesClampToZero() {
        #expect(MeetingTime.clock(-3) == "0:00")
        #expect(MeetingTime.clock(.nan) == "0:00")
        #expect(MeetingTime.clock(.infinity) == "0:00")
    }

    @Test func meetingDatesNameTheYearOnlyWhenItDiffers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        let polish = Locale(identifier: "pl_PL")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 18)))
        let meeting = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 14)))
        let older = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 3, hour: 9, minute: 5)))

        let short = MeetingDateText.short(meeting, now: now, locale: polish, calendar: calendar)
        #expect(short.contains("30") && short.contains("wrz") && short.contains("14:00"))
        #expect(!short.contains("2026"))
        #expect(MeetingDateText.long(meeting, now: now, locale: polish, calendar: calendar).contains("września"))
        #expect(MeetingDateText.short(older, now: now, locale: polish, calendar: calendar).contains("2025"))
    }
}
