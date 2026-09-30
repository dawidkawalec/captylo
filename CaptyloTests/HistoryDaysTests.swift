import Foundation
import Testing
@testable import Captylo

struct HistoryDaysTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func groupsConsecutiveItemsByDayKeepingTheOrder() {
        let dates = [date(26, 9), date(26, 8), date(25, 20), date(25, 7), date(20, 12)]
        let days = HistoryDays.group(dates, date: { $0 }, calendar: calendar)
        #expect(days.map(\.items.count) == [2, 2, 1])
        #expect(days.map(\.id) == [26, 25, 20].map { calendar.startOfDay(for: date($0, 12)) })
        #expect(days[0].items == [date(26, 9), date(26, 8)])
    }

    @Test func emptyPageHasNoDays() {
        #expect(HistoryDays.group([Date](), date: { $0 }, calendar: calendar).isEmpty)
    }

    @Test func todayAndYesterdayAreNamed() {
        let now = date(26, 15)
        #expect(HistoryDays.title(for: date(26, 0), now: now, calendar: calendar) == String(localized: "Dzisiaj"))
        #expect(HistoryDays.title(for: date(25, 0), now: now, calendar: calendar) == String(localized: "Wczoraj"))
    }

    @Test func olderDaysShowTheDateAndTheYearOnlyWhenItDiffers() {
        let now = date(26, 15)
        let sameYear = HistoryDays.title(for: date(20, 0), now: now, calendar: calendar)
        let lastYear = HistoryDays.title(for: date(20, 0, year: 2025), now: now, calendar: calendar)
        #expect(sameYear.contains("20"))
        #expect(!sameYear.contains("2026"))
        #expect(lastYear.contains("2025"))
    }
}
