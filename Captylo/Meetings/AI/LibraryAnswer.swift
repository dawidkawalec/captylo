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

    /// A note the answer used: its row in "Źródła" (`N` numbers).
    struct NoteSource: Sendable, Equatable {
        var noteID: UUID
        var title: String
        var createdAt: Date
    }

    var id: UUID = UUID()
    var question: String
    var answer: String? = nil
    var error: String? = nil
    var model: String? = nil
    var sources: [Source] = []
    /// The notes sent with the question, `N1` first.
    var noteSources: [NoteSource] = []
    /// The search index was still being built: answered from the newest AI notes only.
    var notesOnly: Bool = false
    var askedAt: Date = Date()

    /// An answer worth showing (not blank).
    var hasAnswer: Bool {
        guard let answer else { return false }
        return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The valid citations of the answer, mapped to `sources` and `noteSources`.
    var citations: [LibraryCitation] {
        LibraryCitation.parse(answer ?? "", meetings: sources.map(\.meetingID), notes: noteSources.map(\.noteID))
    }

    /// The notes the answer actually cites, with their `N` number, in number order.
    var citedNotes: [(number: Int, source: NoteSource)] {
        let numbers = Set(citations.filter { $0.kind == .note }.map(\.number))
        return noteSources.enumerated().compactMap { offset, source in
            numbers.contains(offset + 1) ? (offset + 1, source) : nil
        }
    }

    /// The sources the answer actually cites, with their `S` number, in number order: "Źródła"
    /// never lists a meeting the answer did not use (e.g. under "Nie znalazłem...").
    var citedSources: [(number: Int, source: Source)] {
        let numbers = Set(citations.filter { $0.kind == .meeting }.map(\.number))
        return sources.enumerated().compactMap { offset, source in
            numbers.contains(offset + 1) ? (offset + 1, source) : nil
        }
    }
}
