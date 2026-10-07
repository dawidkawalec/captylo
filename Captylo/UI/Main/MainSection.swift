import Foundation

/// Sidebar sections of the main window, in display order.
enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case pulpit
    case spotkania
    case notatki
    case historia
    case plik
    case slownik
    case modele
    case ustawienia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulpit: return String(localized: "Pulpit")
        case .spotkania: return String(localized: "Spotkania")
        case .notatki: return String(localized: "Notatki")
        case .historia: return String(localized: "Historia")
        case .plik: return String(localized: "Transkrypcja pliku")
        case .slownik: return String(localized: "Słownik")
        case .modele: return String(localized: "Modele")
        case .ustawienia: return String(localized: "Ustawienia")
        }
    }

    var symbol: String {
        switch self {
        case .pulpit: return "chart.bar.xaxis"
        case .spotkania: return "person.2.wave.2"
        case .notatki: return "note.text"
        case .historia: return "clock.arrow.circlepath"
        case .plik: return "doc.badge.plus"
        case .slownik: return "character.book.closed"
        case .modele: return "cpu"
        case .ustawienia: return "gearshape"
        }
    }
}
