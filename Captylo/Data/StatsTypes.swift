import Foundation

// Value types crossing from the `Database` actor to the dashboard. Formulas live in `Stats`.

/// One day of the trend chart. `date` is `startOfDay` in the local calendar.
struct DayBucket: Sendable, Equatable, Identifiable {
    let date: Date
    var words: Int
    var minutes: Double
    var sessions: Int

    var id: Date { date }

    init(date: Date, words: Int = 0, minutes: Double = 0, sessions: Int = 0) {
        self.date = date
        self.words = words
        self.minutes = minutes
        self.sessions = sessions
    }

    func value(for metric: TrendMetric) -> Double {
        switch metric {
        case .words: return Double(words)
        case .minutes: return minutes
        case .sessions: return Double(sessions)
        }
    }
}

/// Everything the dashboard shows, recomputed on every `AppState.statsVersion` change.
struct DashboardSnapshot: Sendable, Equatable {
    /// Typing speed the "time saved" hero assumes (brief section 6, same as the 1.64 dashboard).
    static let typingWordsPerMinute = 35
    static let keystrokesPerWord = 5
    /// Trend ranges offered by the picker, in days.
    static let rangeOptions: [Int] = [7, 14, 30]
    /// Whole calendar weeks in the "Aktywność" grid, this week included.
    static let activityWeeks = 5

    var sessions: Int
    var words: Int
    var audioSeconds: Double
    /// nil when no audio was recorded yet (shown as "-").
    var wpm: Double?
    var keystrokesSaved: Int
    var timeSavedSeconds: Double
    var days: [DayBucket]
    /// "Aktywność": every day from the Monday `activityWeeks - 1` weeks back through today
    /// (29...35 buckets), independent of the trend range.
    var activity: [DayBucket]
    /// Consecutive days with at least one session, ending today (or yesterday while today has
    /// none yet, so the streak does not read 0 every morning).
    var streakDays: Int

    init(
        sessions: Int = 0,
        words: Int = 0,
        audioSeconds: Double = 0,
        wpm: Double? = nil,
        keystrokesSaved: Int = 0,
        timeSavedSeconds: Double = 0,
        days: [DayBucket] = [],
        activity: [DayBucket] = [],
        streakDays: Int = 0
    ) {
        self.sessions = sessions
        self.words = words
        self.audioSeconds = audioSeconds
        self.wpm = wpm
        self.keystrokesSaved = keystrokesSaved
        self.timeSavedSeconds = timeSavedSeconds
        self.days = days
        self.activity = activity
        self.streakDays = streakDays
    }

    /// Today's bucket (the last activity day), empty before the first load.
    var today: DayBucket? { activity.last }

    static let empty = DashboardSnapshot()
}

/// Trend chart series. Persisted as the raw value under `AppSettings.Key.dashboardMetric`.
enum TrendMetric: String, Codable, CaseIterable, Sendable {
    case words
    case minutes
    case sessions

    var displayName: String {
        switch self {
        case .words: return String(localized: "Słowa")
        case .minutes: return String(localized: "Minuty")
        case .sessions: return String(localized: "Sesje")
        }
    }
}

/// "Dziennie" = one bar per day, "Łącznie" = running sum over the window.
enum TrendMode: String, Codable, CaseIterable, Sendable {
    case daily
    case cumulative

    var displayName: String {
        switch self {
        case .daily: return String(localized: "Dziennie")
        case .cumulative: return String(localized: "Łącznie")
        }
    }
}
