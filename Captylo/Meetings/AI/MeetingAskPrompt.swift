import Foundation

/// The data of "Zapytaj" about one meeting (`CaptyloAITask.Kind.meetingAsk`): the relay holds the
/// instructions. The answer cites moments as `[mm:ss]` (the line stamps it is given, so
/// `MeetingCitations` can play them) and is exactly `notFound` when the meeting has no answer.
enum MeetingAskPrompt {
    /// The exact answer when the meeting does not contain one (asked in Polish); the relay asks
    /// the model for exactly this text, so change both sides together.
    static let notFound = "Nie znalazłem tego w tym spotkaniu."
    /// The same, asked in English.
    static let notFoundEnglish = "I couldn't find that in this meeting."
    /// Earlier answered questions of the meeting sent along, for follow-ups ("a kto to robi?").
    static let historyLimit = 3

    /// Title, date, participants, the user's notes (line times when there are any), every
    /// non-echo segment in time order, the last `historyLimit` answered questions, the question.
    static func user(meeting: MeetingRecord, segments: [MeetingSegmentRecord], question: String, history: [MeetingQuestion]) -> String {
        var header = "Tytuł: \(meeting.title)\nData: \(promptDate(meeting.createdAt))"
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            header += "\nUczestnicy: " + participants.joined(separator: ", ")
        }
        let transcript = segments
            .filter { !$0.isEcho }
            .sorted { $0.start < $1.start }
            .map { "\(MeetingTime.stamp($0.start)) \(meeting.promptLabel(for: $0)): \($0.text)" }
            .joined(separator: "\n")
        var parts = [
            header,
            "<user_notes>\n\(notes(meeting))\n</user_notes>",
            "<transcript>\n\(transcript)\n</transcript>",
        ]
        let previous = history.filter(\.hasAnswer).suffix(historyLimit)
        if !previous.isEmpty {
            let exchanges = previous
                .map { "Pytanie: \($0.question)\nOdpowiedź: \(($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines))" }
                .joined(separator: "\n\n")
            parts.append("<previous_questions>\n\(exchanges)\n</previous_questions>")
        }
        parts.append("<question>\n\(question.trimmingCharacters(in: .whitespacesAndNewlines))\n</question>")
        return parts.joined(separator: "\n")
    }

    /// "2 października 2026 14:00": always Polish and with the year (the prompt is Polish).
    static func promptDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(locale: Locale(identifier: "pl_PL"), calendar: calendar, timeZone: timeZone)
            .day()
            .month(.wide)
            .year()
            .hour()
            .minute()
        return date.formatted(style)
    }

    /// The note lines with their meeting times; notes typed before lines had times as they are.
    /// Also the user's notes in `LibraryAskPrompt`.
    static func notes(_ meeting: MeetingRecord) -> String {
        let lines = meeting.noteLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.isEmpty {
            return lines.map { "\(MeetingTime.stamp($0.at)) \($0.text)" }.joined(separator: "\n")
        }
        return meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
