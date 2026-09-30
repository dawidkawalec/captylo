import Foundation

/// The six templates of M1. One is picked from the meeting title; the user can pick another and
/// write the notes again.
enum BuiltInMeetingTemplates {
    static let general = MeetingTemplate(
        id: "general", name: String(localized: "Ogólne"), keywords: [],
        instructions: "Zwykłe spotkanie robocze. Skup się na ustaleniach, decyzjach i tym, kto co robi."
    )
    static let oneOnOne = MeetingTemplate(
        id: "oneOnOne", name: String(localized: "1:1"), keywords: ["1:1", "1on1", "one on one", "jeden na jeden"],
        instructions: "Rozmowa 1:1. Wyróżnij tematy osobiste i rozwojowe, feedback w obie strony, blokery i ustalenia na kolejne 1:1."
    )
    static let standup = MeetingTemplate(
        id: "standup", name: String(localized: "Standup"), keywords: ["standup", "stand-up", "daily", "codzienn"],
        instructions: "Standup. Dla każdej osoby: co zrobiła, co robi dalej, blokery. Krótko."
    )
    static let client = MeetingTemplate(
        id: "client", name: String(localized: "Rozmowa z klientem"), keywords: ["klient", "client", "demo", "ofert", "sprzedaz", "sales"],
        instructions: "Rozmowa z klientem. Wyróżnij potrzeby i problemy klienta, obiekcje, budżet i terminy, obietnice po naszej stronie i kolejny krok w procesie."
    )
    static let interview = MeetingTemplate(
        id: "interview", name: String(localized: "Rekrutacja"), keywords: ["rekrutac", "interview", "kandydat"],
        instructions: "Rozmowa rekrutacyjna. Doświadczenie kandydata, mocne strony, wątpliwości, oczekiwania (także finansowe, jeśli padły), dostępność, pytania kandydata. Bez ocen osobowości."
    )
    static let lecture = MeetingTemplate(
        id: "lecture", name: String(localized: "Wykład / webinar"), keywords: ["webinar", "wyklad", "szkoleni", "prezentac", "lecture"],
        instructions: "Wykład lub webinar. Najważniejsze tezy w kolejności, definicje, przykłady, liczby, polecane materiały. Sekcja Zadania tylko jeśli prowadzący coś zadał."
    )

    static let all: [MeetingTemplate] = [general, oneOnOne, standup, client, interview, lecture]

    /// The template with this id; `general` for nil or an unknown id (a template removed later).
    static func template(id: String?) -> MeetingTemplate {
        all.first { $0.id == id } ?? general
    }

    /// First template with a keyword in the title, in `all` order; `general` otherwise.
    static func pick(forTitle title: String) -> MeetingTemplate {
        let folded = MeetingSearch.fold(title)
        return all.first { template in
            template.keywords.contains { contains($0, in: folded) }
        } ?? general
    }

    /// `keyword` at the start of a word of `text`; a keyword ending in a digit must also end one
    /// (default titles end with the start time, and "11:15" or "1:10" is not a "1:1").
    private static func contains(_ keyword: String, in text: String) -> Bool {
        guard let last = keyword.last else { return false }
        let needsEnd = last.isNumber
        var searchStart = text.startIndex
        while let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
            let startsWord = range.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let endsWord = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            if startsWord, !needsEnd || endsWord {
                return true
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
