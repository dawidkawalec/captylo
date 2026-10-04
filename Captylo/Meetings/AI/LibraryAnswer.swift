import Foundation

/// One "Zapytaj wszystkie spotkania" exchange (Pro): the question, the meetings it was answered
/// from (`S1` first) and either the AI's answer (Markdown with `[S1 12:34]` citations) or why it
/// failed (Polish). Kept for the session only (`MeetingAskRuns.libraryAnswers`), never stored.
struct LibraryAnswer: Sendable, Equatable, Identifiable {
    /// A meeting the answer used: its row in "Źródła".
    struct Source: Sendable, Equatable {
        var meetingID: UUID
        var title: String
        var createdAt: Date
    }

    var id: UUID = UUID()
    var question: String
    var answer: String? = nil
    var error: String? = nil
    var model: String? = nil
    var sources: [Source] = []
    /// The search index was still being built: answered from the newest AI notes only.
    var notesOnly: Bool = false
    var askedAt: Date = Date()

    /// An answer worth showing (not blank).
    var hasAnswer: Bool {
        guard let answer else { return false }
        return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The valid citations of the answer, mapped to `sources`.
    var citations: [LibraryCitation] {
        LibraryCitation.parse(answer ?? "", meetings: sources.map(\.meetingID))
    }

    /// The sources the answer actually cites, with their `S` number, in number order: "Źródła"
    /// never lists a meeting the answer did not use (e.g. under "Nie znalazłem...").
    var citedSources: [(number: Int, source: Source)] {
        let numbers = Set(citations.map(\.number))
        return sources.enumerated().compactMap { offset, source in
            numbers.contains(offset + 1) ? (offset + 1, source) : nil
        }
    }
}
