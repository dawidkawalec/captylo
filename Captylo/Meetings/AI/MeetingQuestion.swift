import Foundation

/// One "Zapytaj" exchange about a meeting (Pro): the question, and either the AI's answer
/// (Markdown with `[mm:ss]` citations) and the model that wrote it, or why it failed (Polish).
/// Stored on the meeting row (`MeetingRecord.questions`, newest last) and in the JSON export.
struct MeetingQuestion: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var question: String
    var answer: String? = nil
    var error: String? = nil
    var model: String? = nil
    var askedAt: Date = Date()

    /// An answer worth showing, quoting in the next prompt or exporting (not blank).
    var hasAnswer: Bool {
        guard let answer else { return false }
        return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
