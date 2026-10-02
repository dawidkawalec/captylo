import Foundation

/// The pure steps of "Zapytaj wszystkie spotkania" retrieval (`LibraryAsker.context`): which
/// words of the question to look for, which meetings to keep and which transcript lines of each
/// to send. Only excerpts ever go to the AI, never whole transcripts.
enum LibraryAskRetrieval {
    /// Meetings sent to the AI (`S1`...`S8`).
    static let maxMeetings = 8
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

    /// Folded (`MeetingSearch.fold`) question words that say nothing about the topic: Polish
    /// function and question words, the verbs of "what did X say", time words (the prompt has
    /// the dates) and English basics. Words under 3 letters never reach the index anyway.
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
        "ostatnio", "ostatni", "ostatnie", "ostatnim", "ostatniej", "zeszlym", "zeszlej",
        "tygodniu", "miesiacu", "wczoraj", "dzisiaj", "dzis",
        // English
        "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "what",
        "who", "whom", "when", "where", "which", "how", "why", "did", "does", "do", "is", "are",
        "was", "were", "we", "our", "my", "me", "you", "it", "that", "this", "these", "those",
        "any", "last", "week", "month", "yesterday", "today", "said", "say", "says", "talk",
        "talked", "meeting", "meetings", "have", "has", "had", "there", "from",
    ]

    /// The question's search terms (`SearchQuery.terms`) without stopwords; nil when nothing is
    /// left to look for.
    static func terms(_ question: String) -> [String]? {
        let words = MeetingSearch.fold(question)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) }
        return SearchQuery.terms(words.joined(separator: " "))
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
