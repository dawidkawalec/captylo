import Foundation

/// SF Symbols offered by the "Ikona" grid of the mode editor (all available on macOS 14).
enum AIModeSymbols {
    static let all: [String] = [
        "sparkles",
        "wand.and.stars",
        "globe",
        "character.bubble",
        "list.bullet.indent",
        "checklist",
        "envelope",
        "text.bubble",
        "doc.text",
        "pencil.line",
        "text.quote",
        "lightbulb",
        "briefcase",
        "person.2",
        "calendar",
        "bubble.left.and.bubble.right",
    ]

    /// The grid for a mode: its current symbol first when it is not one of the offered ones.
    static func options(including current: String) -> [String] {
        all.contains(current) || current.isEmpty ? all : [current] + all
    }

    /// Polish name of a symbol for the tooltip and VoiceOver ("Ikona" for one we do not offer).
    static func label(for symbol: String) -> String {
        switch symbol {
        case "sparkles": return String(localized: "Iskry")
        case "wand.and.stars": return String(localized: "Różdżka")
        case "globe": return String(localized: "Globus")
        case "character.bubble": return String(localized: "Litera w dymku")
        case "list.bullet.indent": return String(localized: "Lista")
        case "checklist": return String(localized: "Lista zadań")
        case "envelope": return String(localized: "Koperta")
        case "text.bubble": return String(localized: "Dymek")
        case "doc.text": return String(localized: "Dokument")
        case "pencil.line": return String(localized: "Ołówek")
        case "text.quote": return String(localized: "Cytat")
        case "lightbulb": return String(localized: "Żarówka")
        case "briefcase": return String(localized: "Teczka")
        case "person.2": return String(localized: "Osoby")
        case "calendar": return String(localized: "Kalendarz")
        case "bubble.left.and.bubble.right": return String(localized: "Rozmowa")
        default: return String(localized: "Ikona")
        }
    }
}
