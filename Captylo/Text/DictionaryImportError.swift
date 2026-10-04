import Foundation

/// Failures of `DictionaryStore.importJSON`, shown as a toast or alert.
enum DictionaryImportError: LocalizedError, Sendable, Equatable {
    case unreadable
    case invalidFormat
    /// `dictionary.json` could not be written: the change works until quit only.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "Nie udało się odczytać pliku.")
        case .invalidFormat:
            return String(localized: "To nie jest plik słownika Captylo.")
        case .saveFailed:
            return String(localized: "Nie udało się zapisać słownika. Zmiany działają tylko do zamknięcia aplikacji.")
        }
    }
}
