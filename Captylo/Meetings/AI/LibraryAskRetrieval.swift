import Foundation

/// The pure steps of "Zapytaj wszystkie spotkania" retrieval (`LibraryAsker.context`): which
/// words of the question to look for, which meetings to keep and which transcript lines of each
/// to send. Only excerpts ever go to the AI, never whole transcripts.
enum LibraryAskRetrieval {
    /// Meetings sent to the AI (`S1`...`S8`).
    static let maxMeetings = 8
    /// Notes sent to the AI (`N1`...`N5`).
    static let maxNotes = 5
    /// Meetings the index ranks before the eight are picked by the sum of their hits.
    static let candidateMeetings = 24
    /// Hit lines per meeting (its best), each with one neighbor before and after.
    static let segmentsPerMeeting = 12
    /// Characters of the AI notes (and the user's notes) per meeting.
    static let notesPrefix = 600
    /// The same while the index is built: the notes are all there is to answer from.
    static let notesOnlyPrefix = 2_000
    /// Newest meetings read for the notes-only fallback (those without AI notes are skipped).
    static let notesOnlyScan = 50

    /// Lines from the end of a meeting picked by date with no hit (the wrap-up: decisions and
    /// next steps), sent next to its AI notes.
    static let closingLines = 12

    /// Folded words that make a question about time ("ostatnio", "wczoraj", "temu"): the
    /// meetings are then picked by date (`period`), not only by topic. A week or a month
    /// (`weekWords`, `monthWords`) does so only with a qualifier next to it ("w zeszłym
    /// tygodniu", `qualifiedUnit`); alone ("miesiąc licencji", "za tydzień") it is a topic.
    /// None of them is ever a search term.
    static let timeWords: Set<String> = [
        // Polish
        "ostatnio", "niedawno", "ostatni", "ostatnia", "ostatnie", "ostatnim", "ostatniej",
        "ostatnich", "ostatniego", "zeszly", "zeszla", "zeszle", "zeszlym", "zeszlej", "zeszlego",
        "poprzedni", "poprzednia", "poprzednie", "poprzednim", "poprzedniej", "poprzedniego",
        "ubiegly", "ubiegla", "ubiegle", "ubieglym", "ubieglej", "ubieglego",
        "tydzien", "tygodnia", "tygodniu", "miesiac", "miesiaca", "miesiacu", "wczoraj",
        "przedwczoraj", "dzisiaj", "dzis", "dzisiejsze", "dzisiejszym", "dzisiejszej", "temu",
        // English
        "recent", "recently", "lately", "latest", "last", "previous", "past", "week", "month",
        "yesterday", "today", "ago",
    ]

    static let weekWords: Set<String> = ["tydzien", "tygodnia", "tygodniu", "week"]
    static let monthWords: Set<String> = ["miesiac", "miesiaca", "miesiacu", "month"]

    /// Right before a week or a month: the one of `now` ("w tym tygodniu", "this month").
    private static let thisWords: Set<String> = ["ten", "tym", "biezacy", "biezacym", "this"]
    /// Right before: the one before ("w zeszłym tygodniu", "last month").
    private static let previousWords: Set<String> = [
        "zeszly", "zeszla", "zeszle", "zeszlym", "zeszlej", "zeszlego", "poprzedni", "poprzednia",
        "poprzednie", "poprzednim", "poprzedniej", "poprzedniego", "ubiegly", "ubiegla", "ubiegle",
        "ubieglym", "ubieglej", "ubieglego", "last", "previous",
    ]
    /// Right before: the last 7 / 30 days ("w ostatnim tygodniu", "the past month").
    private static let rollingWords: Set<String> = [
        "ostatni", "ostatnia", "ostatnie", "ostatnim", "ostatniej", "ostatnich", "ostatniego", "past",
    ]
    /// Right after: the one before ("miesiąc temu", "a week ago").
    private static let agoWords: Set<String> = ["temu", "ago"]

    private enum Reach { case current, previous, rolling }

    /// The first week or month in `words` with a qualifier next to it, and what the qualifier
    /// says. Nil for a bare unit ("miesiąc licencji", "za tydzień") or none.
    private static func qualifiedUnit(_ words: [String]) -> (unit: Calendar.Component, days: Int, reach: Reach)? {
        for (index, word) in words.enumerated() {
            let unit: (Calendar.Component, Int)
            if weekWords.contains(word) {
                unit = (.weekOfYear, 7)
            } else if monthWords.contains(word) {
                unit = (.month, 30)
            } else {
                continue
            }
            let before = index > 0 ? words[index - 1] : ""
            let after = index + 1 < words.count ? words[index + 1] : ""
            if previousWords.contains(before) || agoWords.contains(after) { return (unit.0, unit.1, .previous) }
            if rollingWords.contains(before) { return (unit.0, unit.1, .rolling) }
            if thisWords.contains(before) { return (unit.0, unit.1, .current) }
        }
        return nil
    }

    /// Folded (`MeetingSearch.fold`) question words that say nothing about the topic: Polish
    /// function and question words, the verbs of "what did X say" and English basics (time
    /// words are `timeWords`). Words under 3 letters never reach the index anyway.
    static let stopwords: Set<String> = [
        // Polish
        "i", "a", "o", "w", "z", "na", "do", "ze", "sie", "jak", "co", "czy", "to", "ten", "ta",
        "jest", "byl", "byla", "bylo", "byly", "byli", "mamy", "nam", "nas", "dla", "przez",
        "przy", "po", "od", "ale", "lub", "oraz", "ktory", "ktora", "ktore", "ktorzy", "kiedy",
        "gdzie", "ile", "jaki", "jaka", "jakie", "jakis", "czym", "kto", "kogo", "komu", "tym",
        "tej", "tego", "jego", "jej", "ich", "mnie", "mi", "moj", "moja", "moje", "nasz", "nasza",
        "nasze", "tam", "tu", "juz", "jeszcze", "tez", "tylko", "wszystkie", "wszystko",
        "mowil", "mowila", "mowili", "mowilismy", "mowiles", "powiedzial", "powiedziala",
        "powiedzieli", "rozmawialismy", "spotkanie", "spotkania", "spotkaniu", "spotkaniach",
        "biezacym", "biezacy",
        // English
        "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "what",
        "who", "whom", "when", "where", "which", "how", "why", "did", "does", "do", "is", "are",
        "was", "were", "we", "our", "my", "me", "you", "it", "that", "this", "these", "those",
        "any", "said", "say", "says", "talk", "talked", "meeting", "meetings", "have", "has",
        "had", "there", "from",
    ]

    /// The folded words of `question`.
    private static func words(_ question: String) -> [String] {
        MeetingSearch.fold(question)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The question's search terms (`SearchQuery.terms`) without stopwords and time words; nil
    /// when nothing is left to look for.
    static func terms(_ question: String) -> [String]? {
        let words = words(question).filter { !stopwords.contains($0) && !timeWords.contains($0) }
        return SearchQuery.terms(words.joined(separator: " "))
    }

    /// The question is about time: its meetings are picked by date. A bare week or month does
    /// not count ("Ile kosztuje miesiąc licencji?" stays a topic search).
    static func isAboutTime(_ question: String) -> Bool {
        let words = words(question)
        let units = weekWords.union(monthWords)
        return words.contains { timeWords.contains($0) && !units.contains($0) } || qualifiedUnit(words) != nil
    }

    /// The period a question names: "dziś", "wczoraj", "przedwczoraj" (that day), "w tym
    /// tygodniu" / "miesiącu" (the calendar week or month of `now`), "w zeszłym" / "poprzednim"
    /// / "ubiegłym" and "tydzień" / "miesiąc temu" (the one before), "w ostatnim tygodniu" /
    /// "miesiącu" (the last 7 / 30 days up to `now`). Nil for "ostatnio", a bare week or month
    /// ("za tydzień") and other questions without one: the newest meetings.
    static func period(_ question: String, now: Date, calendar: Calendar) -> DateInterval? {
        let ordered = words(question)
        let words = Set(ordered)
        func day(_ offset: Int) -> DateInterval? {
            calendar.date(byAdding: .day, value: offset, to: now).flatMap { calendar.dateInterval(of: .day, for: $0) }
        }
        if !words.isDisjoint(with: ["dzis", "dzisiaj", "dzisiejsze", "dzisiejszym", "dzisiejszej", "today"]) {
            return day(0)
        }
        if words.contains("przedwczoraj") { return day(-2) }
        if !words.isDisjoint(with: ["wczoraj", "yesterday"]) { return day(-1) }

        guard let (unit, days, reach) = qualifiedUnit(ordered) else { return nil }
        switch reach {
        case .previous:
            return calendar.date(byAdding: unit, value: -1, to: now).flatMap { calendar.dateInterval(of: unit, for: $0) }
        case .rolling:
            return calendar.date(byAdding: .day, value: -days, to: now).map { DateInterval(start: $0, end: now) }
        case .current:
            return calendar.dateInterval(of: unit, for: now)
        }
    }

    /// Weeks from Monday, the user's time zone: what "w tym tygodniu" means in Polish.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = .current
        return calendar
    }

    /// For a question picked by date: the meetings with hits, newest first, then (when `fill`)
    /// the newest of the rest, `limit` in all. `meetings` is newest first.
    static func pickByDate(_ meetings: [MeetingRecord], hits: Set<UUID>, fill: Bool, limit: Int) -> [MeetingRecord] {
        let withHits = meetings.filter { hits.contains($0.id) }
        let rest = fill ? meetings.filter { !hits.contains($0.id) } : []
        return Array((withHits + rest).prefix(max(limit, 0)))
    }

    /// The last `count` spoken lines (echo left out) as one run in time order; empty when there
    /// are none.
    static func closing(_ segments: [MeetingSegmentRecord], count: Int) -> [[MeetingSegmentRecord]] {
        let spoken = segments
            .filter { !$0.isEcho }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString }
        let tail = Array(spoken.suffix(max(count, 0)))
        return tail.isEmpty ? [] : [tail]
    }

    /// The `limit` meetings whose hits add up best (the sum of their ranks, lower is better, so
    /// many good hits beat one), a newer meeting first on a tie. Meetings missing from `dates`
    /// (gone from the store) are left out.
    static func pickMeetings(_ hits: [SearchHit], dates: [UUID: Date], limit: Int) -> [UUID] {
        var sums: [UUID: Double] = [:]
        for hit in hits where dates[hit.meetingID] != nil {
            sums[hit.meetingID, default: 0] += hit.rank
        }
        let ordered = sums.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let left = dates[lhs.key] ?? .distantPast
            let right = dates[rhs.key] ?? .distantPast
            if left != right { return left > right }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        return ordered.prefix(max(limit, 0)).map(\.key)
    }

    /// The hit lines with one line before and after each, as runs of adjacent lines in time
    /// order (runs that touch or overlap merge). Echo is left out first, so it is never a
    /// neighbor.
    static func excerpts(hitSegmentIDs: Set<UUID>, in segments: [MeetingSegmentRecord]) -> [[MeetingSegmentRecord]] {
        guard !hitSegmentIDs.isEmpty else { return [] }
        let spoken = segments
            .filter { !$0.isEcho }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString }
        var keep = Set<Int>()
        for (index, segment) in spoken.enumerated() where hitSegmentIDs.contains(segment.id) {
            keep.formUnion(max(index - 1, 0)...min(index + 1, spoken.count - 1))
        }
        var runs: [[MeetingSegmentRecord]] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index == previous + 1, !runs.isEmpty {
                runs[runs.count - 1].append(spoken[index])
            } else {
                runs.append([spoken[index]])
            }
            previous = index
        }
        return runs
    }
}
