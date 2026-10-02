import Foundation

/// What "Zapytaj wszystkie spotkania" sends the AI for one question (`LibraryAsker.context`):
/// the picked meetings, best first. No sources means nothing matched: the answer is
/// `LibraryAsker.noHitsAnswer` without an AI call.
struct LibraryAskContext: Sendable, Equatable {
    var sources: [LibraryAskSource]
    /// The search index was still being built: the newest meetings' AI notes only, and the
    /// answer says so.
    var notesOnly: Bool
    /// Picked by date (a question about time, or one with no topic words left): the AI notes go
    /// longer (`notesOnlyPrefix`), with no index line in the answer.
    var byDate = false
}
