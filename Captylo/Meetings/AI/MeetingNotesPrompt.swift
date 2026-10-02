import Foundation

/// Granola-style notes: the user's own notes are the skeleton, the transcript fills in the facts.
/// Always Polish, whatever the UI language: speaker labels come from `MeetingRecord.promptLabel(for:)`.
enum MeetingNotesPrompt {
    static func system(template: MeetingTemplate) -> String {
        """
        Jesteś asystentem, który robi notatki ze spotkań. Piszesz po polsku, chyba że całe spotkanie było w innym języku: wtedy w jego języku, ale nagłówki zawsze po polsku.
        Dostajesz notatki użytkownika (<user_notes>, każda linia z czasem) i transkrypt (<transcript>, linie "[mm:ss] Mówca: tekst").
        Zasady:
        - Notatki użytkownika to szkielet: zachowaj każdą jego myśl, rozwiń ją faktami z transkryptu z okolicy jej czasu. Nigdy im nie przecz.
        - Dodaj ważne rzeczy, których użytkownik nie zanotował.
        - Po każdym punkcie podaj czas źródła w formacie [mm:ss] (albo [h:mm:ss]), dokładnie tak jak w transkrypcie.
        - Nie wymyślaj faktów, nazwisk, kwot ani terminów. Jeśli czegoś nie wiadomo, nie pisz tego.
        - Nie oceniaj emocji ani zaangażowania uczestników.
        - Zwięźle: punkty, nie akapity.
        Odpowiedz wyłącznie Markdownem z dokładnie tymi sekcjami, w tej kolejności (pomiń sekcję, jeśli jest pusta):
        ## Podsumowanie
        ## Decyzje
        ## Zadania
        (format punktu: "- Kto: co, do kiedy [mm:ss]"; "Ja" to użytkownik)
        ## Otwarte pytania
        ## Następne kroki
        Rodzaj spotkania: \(template.name). \(template.instructions)
        """
    }

    /// Title, the participants from the calendar when there are any (so the names are spelled
    /// right), the user's note lines with their times, then every non-echo segment in time order.
    static func user(meeting: MeetingRecord, segments: [MeetingSegmentRecord]) -> String {
        var header = "Tytuł: \(meeting.title)"
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            header += "\nUczestnicy: " + participants.joined(separator: ", ")
        }
        let notes = meeting.noteLines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\(MeetingTime.stamp($0.at)) \($0.text)" }
            .joined(separator: "\n")
        let transcript = segments
            .filter { !$0.isEcho }
            .sorted { $0.start < $1.start }
            .map { "\(MeetingTime.stamp($0.start)) \(meeting.promptLabel(for: $0)): \($0.text)" }
            .joined(separator: "\n")
        return """
        \(header)
        <user_notes>
        \(notes)
        </user_notes>
        <transcript>
        \(transcript)
        </transcript>
        """
    }
}
