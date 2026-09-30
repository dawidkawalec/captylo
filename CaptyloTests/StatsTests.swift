import Foundation
import Testing
@testable import Captylo

struct StatsTests {
    private static var warsaw: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        calendar.locale = Locale(identifier: "pl_PL")
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        warsaw.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Localization

    /// The app's compiled catalog for one language (the test host is the app).
    private static func catalog(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func heroSubtitleUsesPolishPluralForms() throws {
        let pl = try Self.catalog("pl")
        func subtitle(_ words: Int, _ sessions: Int) -> String {
            String(localized: "Podyktowano \(words) słów w \(sessions) sesjach", bundle: pl, locale: Locale(identifier: "pl"))
        }
        #expect(subtitle(1, 1) == "Podyktowano 1 słowo w 1 sesji")
        #expect(subtitle(2, 3) == "Podyktowano 2 słowa w 3 sesjach")
        #expect(subtitle(5, 12) == "Podyktowano 5 słów w 12 sesjach")
        #expect(subtitle(22, 22) == "Podyktowano 22 słowa w 22 sesjach")
    }

    @Test func heroSubtitleHasAnEnglishTranslation() throws {
        let en = try Self.catalog("en")
        func subtitle(_ words: Int, _ sessions: Int) -> String {
            String(localized: "Podyktowano \(words) słów w \(sessions) sesjach", bundle: en, locale: Locale(identifier: "en"))
        }
        #expect(subtitle(1, 1) == "Dictated 1 word in 1 session")
        #expect(subtitle(5, 2) == "Dictated 5 words in 2 sessions")
        let imported = String(localized: "Zaimportowano \(1) nowych pozycji.", bundle: en, locale: Locale(identifier: "en"))
        #expect(imported == "Imported 1 new item.")
    }

    @Test func importCountUsesPolishPluralForms() throws {
        let pl = try Self.catalog("pl")
        func message(_ count: Int) -> String {
            String(localized: "Zaimportowano \(count) nowych pozycji.", bundle: pl, locale: Locale(identifier: "pl"))
        }
        #expect(message(1) == "Zaimportowano 1 nową pozycję.")
        #expect(message(3) == "Zaimportowano 3 nowe pozycje.")
        #expect(message(5) == "Zaimportowano 5 nowych pozycji.")
    }

    // MARK: Formulas

    @Test func totalsFollowBriefSectionSix() {
        let now = Self.date(2026, 9, 25)
        let samples = [
            UsageSample(createdAt: now, wordCount: 100, audioDuration: 60),
            UsageSample(createdAt: now, wordCount: 250, audioDuration: 90),
        ]
        let snapshot = Stats.snapshot(samples: samples, days: 7, now: now, calendar: Self.warsaw)

        #expect(snapshot.sessions == 2)
        #expect(snapshot.words == 350)
        #expect(snapshot.audioSeconds == 150)
        // 350 words / 2.5 minutes
        #expect(snapshot.wpm == 140)
        #expect(snapshot.keystrokesSaved == 350 * DashboardSnapshot.keystrokesPerWord)
        // 350 / 35 * 60 - 150 = 600 - 150
        #expect(snapshot.timeSavedSeconds == 450)
        #expect(snapshot.days.count == 7)
    }

    @Test func emptyAndSlowSpeechEdgeCases() {
        let now = Self.date(2026, 9, 25)
        let empty = Stats.snapshot(samples: [], days: 14, now: now, calendar: Self.warsaw)
        #expect(empty.wpm == nil)
        #expect(empty.timeSavedSeconds == 0)
        #expect(empty.days.count == 14)
        #expect(empty.days.allSatisfy { $0.words == 0 && $0.sessions == 0 && $0.minutes == 0 })

        // 10 words in 60 s would take 17 s to type: time saved clamps at zero.
        let slow = Stats.snapshot(
            samples: [UsageSample(createdAt: now, wordCount: 10, audioDuration: 60)],
            days: 7, now: now, calendar: Self.warsaw
        )
        #expect(slow.timeSavedSeconds == 0)
        #expect(slow.wpm == 10)
    }

    @Test func totalsAreAllTimeButBucketsAreWindowed() {
        let now = Self.date(2026, 9, 25)
        let old = Self.date(2026, 1, 1)
        let samples = [
            UsageSample(createdAt: old, wordCount: 500, audioDuration: 100),
            UsageSample(createdAt: now, wordCount: 20, audioDuration: 30),
        ]
        let snapshot = Stats.snapshot(samples: samples, days: 7, now: now, calendar: Self.warsaw)
        #expect(snapshot.words == 520)
        #expect(snapshot.sessions == 2)
        #expect(snapshot.days.map(\.words).reduce(0, +) == 20)
        #expect(snapshot.days.last?.date == Self.warsaw.startOfDay(for: now))
        #expect(snapshot.days.last?.sessions == 1)
        #expect(snapshot.days.last?.minutes == 0.5)
    }

    // MARK: DST

    @Test func bucketsSurviveTheSpringDSTChange() {
        // Europe/Warsaw switches to summer time on 2026-03-29 at 02:00.
        let now = Self.date(2026, 3, 30, 15)
        let samples = [
            UsageSample(createdAt: Self.date(2026, 3, 28, 23, 30), wordCount: 1, audioDuration: 60),
            UsageSample(createdAt: Self.date(2026, 3, 29, 0, 30), wordCount: 10, audioDuration: 60),
            UsageSample(createdAt: Self.date(2026, 3, 29, 23, 45), wordCount: 100, audioDuration: 60),
            UsageSample(createdAt: Self.date(2026, 3, 30, 0, 15), wordCount: 1000, audioDuration: 60),
        ]
        let buckets = Stats.dayBuckets(samples: samples, days: 3, now: now, calendar: Self.warsaw)

        #expect(buckets.count == 3)
        #expect(buckets[0].date == Self.date(2026, 3, 28, 0))
        #expect(buckets[1].date == Self.date(2026, 3, 29, 0))
        #expect(buckets[2].date == Self.date(2026, 3, 30, 0))
        // The DST day is 23 hours long, the day before it is 24.
        #expect(buckets[1].date.timeIntervalSince(buckets[0].date) == 24 * 3600)
        #expect(buckets[2].date.timeIntervalSince(buckets[1].date) == 23 * 3600)
        #expect(buckets.map(\.words) == [1, 110, 1000])
        #expect(buckets.map(\.sessions) == [1, 2, 1])
        #expect(buckets.map(\.date) == buckets.map { Self.warsaw.startOfDay(for: $0.date) })
    }

    // MARK: Activity and streak

    @Test func activityStartsOnMondayFourWeeksBack() {
        let now = Self.date(2026, 9, 27, 18) // a Sunday
        let samples = [
            UsageSample(createdAt: Self.date(2026, 8, 24, 9), wordCount: 7, audioDuration: 10),
            UsageSample(createdAt: Self.date(2026, 8, 23, 9), wordCount: 99, audioDuration: 10),
        ]
        let activity = Stats.activityBuckets(samples: samples, weeks: 5, now: now, calendar: Self.warsaw)
        #expect(activity.count == 35)
        #expect(activity.first?.date == Self.date(2026, 8, 24, 0))
        #expect(activity.first?.words == 7)
        #expect(activity.last?.date == Self.warsaw.startOfDay(for: now))

        // Midweek: the grid ends on today, the rest of the row stays empty.
        let wednesday = Stats.activityBuckets(samples: [], weeks: 5, now: Self.date(2026, 9, 23), calendar: Self.warsaw)
        #expect(wednesday.count == 31)
        #expect(wednesday.first?.date == Self.date(2026, 8, 24, 0))
    }

    @Test func streakCountsBackFromTodayOrYesterday() {
        let now = Self.date(2026, 9, 27, 18)
        let run = [26, 25, 24].map { UsageSample(createdAt: Self.date(2026, 9, $0), wordCount: 1, audioDuration: 1) }
        let gap = UsageSample(createdAt: Self.date(2026, 9, 22), wordCount: 1, audioDuration: 1)

        // Nothing today yet: the run up to yesterday still counts.
        #expect(Stats.streak(samples: run + [gap], now: now, calendar: Self.warsaw) == 3)
        let today = UsageSample(createdAt: Self.date(2026, 9, 27, 8), wordCount: 1, audioDuration: 1)
        #expect(Stats.streak(samples: run + [gap, today], now: now, calendar: Self.warsaw) == 4)
        // A missed yesterday breaks it.
        #expect(Stats.streak(samples: [gap, today], now: now, calendar: Self.warsaw) == 1)
        #expect(Stats.streak(samples: [], now: now, calendar: Self.warsaw) == 0)

        let snapshot = Stats.snapshot(samples: run + [today], days: 7, now: now, calendar: Self.warsaw)
        #expect(snapshot.streakDays == 4)
        #expect(snapshot.today?.sessions == 1)
    }

    @Test func todayIsAlwaysTheLastBucket() {
        let now = Self.date(2026, 10, 25, 3) // autumn DST change day
        let buckets = Stats.dayBuckets(samples: [], days: 30, now: now, calendar: Self.warsaw)
        #expect(buckets.count == 30)
        #expect(buckets.last?.date == Self.warsaw.startOfDay(for: now))
        #expect(buckets.first?.date == Self.warsaw.date(byAdding: .day, value: -29, to: Self.warsaw.startOfDay(for: now)))
        #expect(Set(buckets.map(\.date)).count == 30)
    }

    // MARK: Cumulative

    @Test func cumulativeIsARunningSum() {
        let base = Self.date(2026, 9, 20, 0)
        let daily = (0..<4).map { i in
            DayBucket(date: Self.warsaw.date(byAdding: .day, value: i, to: base)!, words: 10 * (i + 1), minutes: 1.5, sessions: 1)
        }
        let cumulative = Stats.cumulative(daily)
        #expect(cumulative.map(\.words) == [10, 30, 60, 100])
        #expect(cumulative.map(\.sessions) == [1, 2, 3, 4])
        #expect(cumulative.map(\.minutes) == [1.5, 3.0, 4.5, 6.0])
        #expect(cumulative.map(\.date) == daily.map(\.date))
        #expect(Stats.cumulative([]).isEmpty)
    }

    // MARK: Strings

    @Test func summaryTexts() {
        let base = Self.date(2026, 9, 20, 0)
        let daily = [10, 20, 30, 0].enumerated().map { i, words in
            DayBucket(date: Self.warsaw.date(byAdding: .day, value: i, to: base)!, words: words, minutes: Double(words) / 10, sessions: words / 10)
        }
        #expect(Stats.summaryText(buckets: daily, metric: .words, mode: .daily) == "śr. 15/dzień · najlepiej 30")
        #expect(Stats.summaryText(buckets: daily, metric: .words, mode: .cumulative) == "razem 60 · śr. 15/dzień")
        #expect(Stats.summaryText(buckets: daily, metric: .sessions, mode: .daily) == "śr. 2/dzień · najlepiej 3")
        // Minutes: 6 total over 4 days = 1.5 avg, one decimal with a Polish comma below 10.
        #expect(Stats.summaryText(buckets: daily, metric: .minutes, mode: .daily) == "śr. 1,5/dzień · najlepiej 3,0")
        #expect(Stats.summaryText(buckets: daily, metric: .minutes, mode: .cumulative) == "razem 6,0 · śr. 1,5/dzień")
        #expect(Stats.summaryText(buckets: [], metric: .words, mode: .daily) == "śr. 0/dzień · najlepiej 0")
    }

    @Test func minutesDropTheDecimalFromTen() {
        #expect(Stats.format(9.96, metric: .minutes) == "10,0")
        #expect(Stats.format(10, metric: .minutes) == "10")
        #expect(Stats.format(123.4, metric: .minutes) == "123")
        #expect(Stats.format(12.5, metric: .words) == "13")
    }

    @Test func abbreviations() {
        #expect(Stats.abbreviate(0) == "0")
        #expect(Stats.abbreviate(850) == "850")
        #expect(Stats.abbreviate(2.5) == "2,5")
        #expect(Stats.abbreviate(1_000) == "1 tys.")
        #expect(Stats.abbreviate(1_234) == "1,2 tys.")
        #expect(Stats.abbreviate(999_949) == "999,9 tys.")
        #expect(Stats.abbreviate(3_400_000) == "3,4 mln")
    }

    @Test func timeSavedZeroState() {
        #expect(Stats.timeSavedText(seconds: 0) == "Zacznij dyktować, aby zobaczyć zaoszczędzony czas")
        #expect(Stats.timeSavedText(seconds: 0.4) == "Zacznij dyktować, aby zobaczyć zaoszczędzony czas")
    }

    @Test func timeSavedUsesTwoUnitsInPolish() {
        let short = Stats.timeSavedText(seconds: 125)
        #expect(short.contains("2 min"))
        #expect(short.contains("5 sek"))
        #expect(!short.contains("godz"))

        let long = Stats.timeSavedText(seconds: 3600 + 5 * 60 + 30)
        #expect(long.contains("1 godz"))
        #expect(long.contains("5 min"))
        #expect(!long.contains("sek"))
    }

    @Test func timeSavedPartsForTheBigNumber() {
        #expect(Stats.timeSavedParts(seconds: 30) == nil)
        let minutes = Stats.timeSavedParts(seconds: 42 * 60 + 50)
        #expect(minutes?.value == "42")
        #expect(minutes?.unit == "min")
        let hours = Stats.timeSavedParts(seconds: 166 * 3600 + 59 * 60)
        #expect(hours?.value == "166")
        #expect(hours?.unit == "godz.")
    }

    @Test func heroSubtitle() {
        #expect(Stats.heroSubtitle(words: 12, sessions: 3) == "Podyktowano 12 słów w 3 sesjach")
    }
}
