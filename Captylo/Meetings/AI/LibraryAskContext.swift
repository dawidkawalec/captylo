import Foundation

/// What "Zapytaj wszystkie spotkania" sends the AI for one question (`LibraryAsker.context`):
/// the picked meetings, best first, and the user's notes that match (`N1`...). No meetings and
/// no notes means nothing matched: the answer is `LibraryAsker.noHitsAnswer` without an AI call.
struct LibraryAskContext: Sendable, Equatable {
    var sources: [LibraryAskSource]
    /// The search index was still being built: the newest meetings' AI notes only, and the
    /// answer says so.
    var notesOnly: Bool
    /// Picked by date (a question about time, or one with no topic words left): the AI notes go
    /// longer (`notesOnlyPrefix`), with no index line in the answer.
    var byDate = false
    /// The notes to answer from, best first (at most `LibraryAskRetrieval.maxNotes`).
    var notes: [NoteRecord] = []

    /// Nothing to send: no meeting and no note.
    var isEmpty: Bool { sources.isEmpty && notes.isEmpty }
}
