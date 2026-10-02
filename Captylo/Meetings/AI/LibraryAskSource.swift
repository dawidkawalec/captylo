import Foundation

/// One meeting picked for "Zapytaj wszystkie spotkania": the meeting (title, date, participants,
/// AI notes, the user's notes) and the transcript lines around its search hits. It is `S<n>` in
/// the prompt, numbered in the order of `LibraryAskContext.sources`.
struct LibraryAskSource: Sendable, Equatable {
    var meeting: MeetingRecord
    /// Runs of neighboring transcript lines around the hits (one line before and after each
    /// hit, adjacent runs merged), in time order, echo left out. Empty for a title or notes hit
    /// and in the notes-only fallback.
    var excerpts: [[MeetingSegmentRecord]]
    /// The question matched the user's notes: they go along (cut like the AI notes).
    var includesUserNotes: Bool
}
