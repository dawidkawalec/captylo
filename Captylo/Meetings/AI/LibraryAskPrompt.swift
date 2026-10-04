import Foundation

/// The data of "Zapytaj wszystkie spotkania" (`CaptyloAITask.Kind.libraryAsk`): the excerpts of
/// the picked meetings (`LibraryAskContext`), numbered `S1`...`S8`, with today's date for
/// "ostatnio" or "w zeszłym tygodniu". The relay holds the instructions; the answer cites each
/// claim as `[S1 12:34]` (parsed by `LibraryCitation`) and is exactly `notFound` when the
/// meetings have no answer.
enum LibraryAskPrompt {
    /// The exact answer when the meetings do not contain one (asked in Polish); the relay asks
    /// the model for exactly this text, so change both sides together.
    static let notFound = "Nie znalazłem tego w spotkaniach."
    /// The same, asked in English.
    static let notFoundEnglish = "I couldn't find that in your meetings."

    /// Today's date, every source as "S1: Tytuł, data, uczestnicy: ..." with its notes and
    /// excerpts, then the question.
    static func user(context: LibraryAskContext, question: String, now: Date) -> String {
        let notesLimit = context.notesOnly || context.byDate ? LibraryAskRetrieval.notesOnlyPrefix : LibraryAskRetrieval.notesPrefix
        let meetings = context.sources.enumerated().map { offset, source in
            block(source, number: offset + 1, notesLimit: notesLimit)
        }
        return [
            "Dzisiaj: \(MeetingAskPrompt.promptDate(now))",
            "<meetings>\n\(meetings.joined(separator: "\n\n"))\n</meetings>",
            "<question>\n\(question.trimmingCharacters(in: .whitespacesAndNewlines))\n</question>",
        ].joined(separator: "\n")
    }

    private static func block(_ source: LibraryAskSource, number: Int, notesLimit: Int) -> String {
        let meeting = source.meeting
        var header = "S\(number): \(oneLine(meeting.title)), \(MeetingAskPrompt.promptDate(meeting.createdAt))"
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            header += ", uczestnicy: " + participants.joined(separator: ", ")
        }
        var parts = [header]
        let summary = (meeting.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append("<ai_notes>\n\(prefix(summary, notesLimit))\n</ai_notes>")
        }
        if source.includesUserNotes {
            let notes = MeetingAskPrompt.notes(meeting)
            if !notes.isEmpty {
                parts.append("<user_notes>\n\(prefix(notes, notesLimit))\n</user_notes>")
            }
        }
        let runs = source.excerpts.filter { !$0.isEmpty }.map { run in
            run.map { "\(MeetingTime.stamp($0.start)) \(meeting.promptLabel(for: $0)): \(oneLine($0.text))" }
                .joined(separator: "\n")
        }
        if !runs.isEmpty {
            parts.append("<excerpts>\n\(runs.joined(separator: "\n...\n"))\n</excerpts>")
        }
        return parts.joined(separator: "\n")
    }

    /// The first `limit` characters, "..." when cut.
    private static func prefix(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    /// A title or a line on one line, so it never breaks the "[mm:ss] Mówca: tekst" layout.
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
