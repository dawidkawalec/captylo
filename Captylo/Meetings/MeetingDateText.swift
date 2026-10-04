import Foundation

/// When a meeting took place, in the app's locale: "30 wrz, 14:00" on the list, "30 września,
/// 14:00" in the details. A meeting from another year adds the year.
enum MeetingDateText {
    static func short(_ date: Date, now: Date = Date(), locale: Locale = AppLocale.current, calendar: Calendar = .current) -> String {
        format(date, month: .abbreviated, now: now, locale: locale, calendar: calendar)
    }

    static func long(_ date: Date, now: Date = Date(), locale: Locale = AppLocale.current, calendar: Calendar = .current) -> String {
        format(date, month: .wide, now: now, locale: locale, calendar: calendar)
    }

    private static func format(_ date: Date, month: Date.FormatStyle.Symbol.Month, now: Date, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day()
            .month(month)
            .hour()
            .minute()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
