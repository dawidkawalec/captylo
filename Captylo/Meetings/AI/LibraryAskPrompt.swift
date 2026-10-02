import Foundation

/// "Zapytaj wszystkie spotkania": the model answers from the excerpts of the picked meetings only
/// (`LibraryAskContext`), numbered `S1`...`S8`, cites each claim as `[S1 12:34]` (meeting number
/// and the line stamp, parsed by `LibraryCitation`), takes the dates into account for "ostatnio"
/// or "w zeszłym tygodniu" (today's date is in the message) and says `notFound` instead of
/// guessing. Polish instructions whatever the UI language; the answer follows the question's.
enum LibraryAskPrompt {
    /// The exact answer when the meetings do not contain one (asked in Polish).
    static let notFound = "Nie znalazłem tego w spotkaniach."
    /// The same, asked in English.
    static let notFoundEnglish = "I couldn't find that in your meetings."

    static let system = """
    Odpowiadasz na pytania o spotkania użytkownika. Dostajesz dzisiejszą datę, kilka spotkań (<meetings>) i pytanie (<question>). Każde spotkanie ma numer (S1, S2...) i nagłówek z tytułem, datą i uczestnikami; pod nim mogą być początek notatek AI (<ai_notes>), notatki użytkownika (<user_notes>) i fragmenty transkryptu (<excerpts>, linie "[mm:ss] Mówca: tekst", "..." oddziela fragmenty z różnych miejsc spotkania).
    Zasady:
    - Odpowiadaj wyłącznie na podstawie tych spotkań. Nie korzystaj z wiedzy spoza nich. To są tylko wycinki: nie zgaduj, co było poza nimi.
    - Odpowiadaj w języku pytania.
    - Krótko i konkretnie. Gdy wymieniasz kilka rzeczy, użyj punktów ("- ").
    - Zaraz po każdym stwierdzeniu podaj źródło w formacie [S1 12:34] (albo [S1 1:02:03]): numer spotkania i czas linii transkryptu lub notatek, dokładnie tak jak w danych. Gdy czasu nie ma, napisz samo [S1]. Każde źródło w osobnych nawiasach.
    - Gdy pytanie dotyczy czasu ("ostatnio", "w zeszłym tygodniu", "wczoraj"), porównaj daty spotkań z dzisiejszą datą i podaj datę spotkania przy odpowiedzi.
    - Gdy kilka spotkań mówi o tym samym, zaznacz, z którego jest która informacja, a przy sprzecznych podaj nowszą i jej datę.
    - Nie wymyślaj nazwisk, liczb, kwot ani dat. Czego nie ma w spotkaniach, tego nie pisz.
    - Jeśli spotkania nie zawierają odpowiedzi, napisz dokładnie "\(notFound)" (gdy pytanie jest po angielsku: "\(notFoundEnglish)") i nic więcej.
    - "Ja" w transkrypcie to użytkownik, który zadaje pytanie.
    - Odpowiedz Markdownem, bez nagłówków.
    """

    /// Today's date, every source as "S1: Tytuł, data, uczestnicy: ..." with its notes and
    /// excerpts, then the question.
    static func user(context: LibraryAskContext, question: String, now: Date) -> String {
        let notesLimit = context.notesOnly ? LibraryAskRetrieval.notesOnlyPrefix : LibraryAskRetrieval.notesPrefix
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
