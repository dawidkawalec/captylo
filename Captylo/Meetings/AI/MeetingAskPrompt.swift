import Foundation

/// "Zapytaj" about one meeting: the model answers from this meeting's transcript and notes only,
/// cites the moments as `[mm:ss]` (the line stamps it is given, so `MeetingCitations` can play
/// them), and says `notFound` instead of guessing. Always Polish instructions, whatever the UI
/// language: the answer follows the language of the question.
enum MeetingAskPrompt {
    /// The exact answer when the meeting does not contain one (asked in Polish).
    static let notFound = "Nie znalazłem tego w tym spotkaniu."
    /// The same, asked in English.
    static let notFoundEnglish = "I couldn't find that in this meeting."
    /// Earlier answered questions of the meeting sent along, for follow-ups ("a kto to robi?").
    static let historyLimit = 3

    static let system = """
    Odpowiadasz na pytania o jedno spotkanie. Dostajesz jego tytuł, datę, uczestników, notatki użytkownika (<user_notes>), transkrypt (<transcript>, linie "[mm:ss] Mówca: tekst"), wcześniejsze pytania i odpowiedzi (<previous_questions>) i pytanie (<question>).
    Zasady:
    - Odpowiadaj wyłącznie na podstawie transkryptu i notatek tego spotkania. Nie korzystaj z wiedzy spoza nich.
    - Odpowiadaj w języku pytania.
    - Krótko i konkretnie. Gdy wymieniasz kilka rzeczy, użyj punktów ("- ").
    - Zaraz po każdym stwierdzeniu podaj czas źródła w formacie [mm:ss] (albo [h:mm:ss]), dokładnie tak jak przy liniach transkryptu albo notatek.
    - Nie wymyślaj nazwisk, liczb, kwot ani dat. Czego nie ma w spotkaniu, tego nie pisz.
    - Jeśli transkrypt i notatki nie zawierają odpowiedzi, napisz dokładnie "\(notFound)" (gdy pytanie jest po angielsku: "\(notFoundEnglish)") i nic więcej.
    - Wcześniejsze pytania służą tylko do zrozumienia, o co chodzi w nowym pytaniu.
    - "Ja" w transkrypcie to użytkownik, który zadaje pytanie.
    - Odpowiedz Markdownem, bez nagłówków.
    """

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
