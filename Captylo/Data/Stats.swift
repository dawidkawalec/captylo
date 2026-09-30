import Foundation

/// One `UsageStat` row as a value, the only input the dashboard formulas need.
struct UsageSample: Sendable, Equatable {
    var createdAt: Date
    var wordCount: Int
    var audioDuration: Double

    init(createdAt: Date, wordCount: Int, audioDuration: Double) {
        self.createdAt = createdAt
        self.wordCount = wordCount
        self.audioDuration = audioDuration
    }
}

/// Pure dashboard formulas (brief section 6). Totals are all-time, day buckets cover the trend window.
enum Stats {
    /// Locale every number and duration on the dashboard is rendered in.
    static var locale: Locale { AppLocale.current }

    // MARK: - Snapshot

    /// `days` = trend window (7 / 14 / 30); `now` and `calendar` decide which local day is "today".
    static func snapshot(samples: [UsageSample], days: Int, now: Date, calendar: Calendar) -> DashboardSnapshot {
        let sessions = samples.count
        let words = samples.reduce(0) { $0 + $1.wordCount }
        let audioSeconds = samples.reduce(0.0) { $0 + $1.audioDuration }
        let wpm: Double? = audioSeconds > 0 ? Double(words) / (audioSeconds / 60) : nil
        let keystrokes = words * DashboardSnapshot.keystrokesPerWord
        let typingSeconds = Double(words) / Double(DashboardSnapshot.typingWordsPerMinute) * 60
        let timeSaved = max(typingSeconds - audioSeconds, 0)

        return DashboardSnapshot(
            sessions: sessions,
            words: words,
            audioSeconds: audioSeconds,
            wpm: wpm,
            keystrokesSaved: keystrokes,
            timeSavedSeconds: timeSaved,
            days: dayBuckets(samples: samples, days: days, now: now, calendar: calendar),
            activity: activityBuckets(samples: samples, weeks: DashboardSnapshot.activityWeeks, now: now, calendar: calendar),
            streakDays: streak(samples: samples, now: now, calendar: calendar)
        )
    }

    /// Day buckets from the first day of the week `weeks - 1` weeks back through today, so the
    /// activity grid starts on a full row (the calendar's `firstWeekday`, Monday on the Pulpit).
    static func activityBuckets(samples: [UsageSample], weeks: Int, now: Date, calendar: Calendar) -> [DayBucket] {
        guard weeks > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek),
              let span = calendar.dateComponents([.day], from: start, to: today).day
        else { return [] }
        return dayBuckets(samples: samples, days: span + 1, now: now, calendar: calendar)
    }

    /// Consecutive local days with at least one sample, counted back from today; while today has
    /// none yet the count starts at yesterday.
    static func streak(samples: [UsageSample], now: Date, calendar: Calendar) -> Int {
        let active = Set(samples.map { calendar.startOfDay(for: $0.createdAt) })
        var day = calendar.startOfDay(for: now)
        if !active.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while active.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// `D_i = startOfDay(today) - (days - 1 - i)` days, i = 0..<days; samples bucket by `startOfDay(createdAt)`.
    /// Day arithmetic goes through the calendar, so DST days (23 h / 25 h) keep their own bucket.
    static func dayBuckets(samples: [UsageSample], days: Int, now: Date, calendar: Calendar) -> [DayBucket] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        var buckets: [DayBucket] = []
        buckets.reserveCapacity(days)
        var indexByDay: [Date: Int] = [:]
        for i in 0..<days {
            let offset = -(days - 1 - i)
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today.addingTimeInterval(Double(offset) * 86_400)
            indexByDay[day] = buckets.count
            buckets.append(DayBucket(date: day))
        }
        for sample in samples {
            let day = calendar.startOfDay(for: sample.createdAt)
            guard let index = indexByDay[day] else { continue }
            buckets[index].words += sample.wordCount
            buckets[index].minutes += sample.audioDuration / 60
            buckets[index].sessions += 1
        }
        return buckets
    }

    /// Running sums over the window ("Łącznie"), starting with the first day's own value.
    static func cumulative(_ buckets: [DayBucket]) -> [DayBucket] {
        var words = 0
        var minutes = 0.0
        var sessions = 0
        return buckets.map { bucket in
            words += bucket.words
            minutes += bucket.minutes
            sessions += bucket.sessions
            return DayBucket(date: bucket.date, words: words, minutes: minutes, sessions: sessions)
        }
    }

    // MARK: - Text

    /// Summary pill under the trend chart. `buckets` are the daily (non-cumulative) buckets of the window;
    /// the average divides by the number of days, zero days included.
    static func summaryText(buckets: [DayBucket], metric: TrendMetric, mode: TrendMode) -> String {
        let values = buckets.map { $0.value(for: metric) }
        let total = values.reduce(0, +)
        let average = values.isEmpty ? 0 : total / Double(values.count)
        switch mode {
        case .daily:
            let best = values.max() ?? 0
            let averageText = format(average, metric: metric)
            let bestText = format(best, metric: metric)
            return String(localized: "śr. \(averageText)/dzień · najlepiej \(bestText)")
        case .cumulative:
            let totalText = format(total, metric: metric)
            let averageText = format(average, metric: metric)
            return String(localized: "razem \(totalText) · śr. \(averageText)/dzień")
        }
    }

    /// Hero value: "1 godzina, 5 minut" style through `DateComponentsFormatter`; zero shows the call to action.
    static func timeSavedText(seconds: Double) -> String {
        guard seconds >= 1 else {
            return String(localized: "Zacznij dyktować, aby zobaczyć zaoszczędzony czas")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? ""
    }

    /// The Pulpit's big number: whole hours from one hour ("166" + "godz."), whole minutes below
    /// ("42" + "min"); nil under a minute (the view shows the call to action instead).
    static func timeSavedParts(seconds: Double) -> (value: String, unit: String)? {
        if seconds >= 3600 {
            let hours = Int(seconds / 3600)
            return (hours.formatted(.number.locale(locale)), String(localized: "godz.", comment: "Unit after the Pulpit's big saved-hours number"))
        }
        if seconds >= 60 {
            return (String(Int(seconds / 60)), String(localized: "min", comment: "Unit after the Pulpit's big saved-minutes number"))
        }
        return nil
    }

    /// Axis labels: plain below 1000, "1,2 tys." below a million, "3,4 mln" above.
    static func abbreviate(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 {
            return String(localized: "\(decimal(value / 1_000_000, maxFraction: 1)) mln")
        }
        if magnitude >= 1_000 {
            return String(localized: "\(decimal(value / 1_000, maxFraction: 1)) tys.")
        }
        return decimal(value, maxFraction: 1)
    }

    /// "Podyktowano 12 słów w 3 sesjach"; the catalog holds the plural variants for both counts.
    static func heroSubtitle(words: Int, sessions: Int) -> String {
        String(localized: "Podyktowano \(words) słów w \(sessions) sesjach")
    }

    // MARK: - Number formatting

    /// Minutes keep one decimal below 10, everything else is a whole number.
    static func format(_ value: Double, metric: TrendMetric) -> String {
        switch metric {
        case .minutes:
            return value < 10 ? decimal(value, maxFraction: 1, minFraction: 1) : decimal(value, maxFraction: 0)
        case .words, .sessions:
            return decimal(value, maxFraction: 0)
        }
    }

    private static func decimal(_ value: Double, maxFraction: Int, minFraction: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = maxFraction
        formatter.minimumFractionDigits = minFraction
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
