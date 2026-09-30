import Foundation

/// Why the import from the old app could not run or stopped.
enum LegacyImportError: LocalizedError, Sendable, Equatable {
    /// No old store on this Mac.
    case noSources
    /// The old app is running: its store may be mid-write (name of the app).
    case oldAppRunning(String)
    /// Another Captylo process writes to the same store.
    case otherCaptyloRunning
    /// The history store is the in-memory fallback: imported rows would be lost at quit.
    case storeUnavailable
    /// Copying or reading the old store failed (SQLite or file message).
    case readFailed(String)
    /// Saving a batch failed (the rows saved before stay, a new run continues).
    case saveFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSources:
            return String(localized: "Nie znaleziono danych starego VocaType na tym Macu.")
        case .oldAppRunning(let name):
            return String(localized: "Zamknij najpierw starą aplikację (\(name)), a potem spróbuj ponownie.")
        case .otherCaptyloRunning:
            return String(localized: "Działa inna kopia Captylo z tą samą bazą. Zamknij ją i spróbuj ponownie.")
        case .storeUnavailable:
            return String(localized: "Baza historii nie jest dostępna, więc import nie zostałby zapisany.")
        case .readFailed(let message):
            return String(localized: "Nie udało się odczytać starej bazy: \(message)")
        case .saveFailed(let message):
            return String(localized: "Nie udało się zapisać zaimportowanych wpisów: \(message)")
        case .cancelled:
            return String(localized: "Import przerwany. Zapisane wpisy zostają, kolejny import dokończy resztę.")
        }
    }
}
