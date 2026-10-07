import Foundation

/// Speech engine chosen once in Modele. Persisted as the raw value under `AppSettings.Key.sttEngine`.
enum STTEngine: String, Codable, CaseIterable, Hashable, Sendable {
    /// The on-device engine (`WhisperEngine`). The raw value is from the Parakeet era and stays,
    /// so the stored setting keeps meaning "local" without a migration.
    case local = "parakeet"
    case elevenLabs

    var isCloud: Bool { self == .elevenLabs }

    /// Model id reported in `TranscriptionResult.modelName` and shown in history. History rows
    /// from before the switch keep "parakeet-tdt-0.6b-v3".
    var modelName: String {
        switch self {
        case .local: return "whisper-large-v3-turbo"
        case .elevenLabs: return "scribe_v2"
        }
    }

    var displayName: String {
        switch self {
        case .local: return String(localized: "Lokalnie")
        case .elevenLabs: return String(localized: "Chmura")
        }
    }

    /// What history and the CSV export show for a stored model id: the cloud model reads
    /// "Chmura", never the vendor's name or model id.
    static func label(forModelName name: String) -> String {
        name == STTEngine.elevenLabs.modelName ? STTEngine.elevenLabs.displayName : name
    }
}

struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let modelName: String
    let ms: Int
    /// True when the cloud engine failed and the local engine produced the text.
    let usedFallback: Bool
    /// Why the cloud was not used when `usedFallback` (no route, the Pro limit, a timeout...).
    let fallbackError: STTError?
    /// The local engine was chosen but its model was still being prepared, so the cloud did this take.
    let cloudWhileLocalPrepares: Bool

    init(
        text: String,
        modelName: String,
        ms: Int,
        usedFallback: Bool = false,
        fallbackError: STTError? = nil,
        cloudWhileLocalPrepares: Bool = false
    ) {
        self.text = text
        self.modelName = modelName
        self.ms = ms
        self.usedFallback = usedFallback
        self.fallbackError = fallbackError
        self.cloudWhileLocalPrepares = cloudWhileLocalPrepares
    }

    /// The toast after a fallback, saying why; nil when the cloud (or the local engine by
    /// choice) produced the text.
    var fallbackNotice: String? {
        if cloudWhileLocalPrepares {
            return String(localized: "Model lokalny jeszcze się przygotowuje, tym razem użyto chmury.")
        }
        guard usedFallback else { return nil }
        switch fallbackError {
        case .quotaExceeded:
            return STTError.quotaExceeded.errorDescription
        case .missingKey:
            return String(localized: "Chmura nie jest dostępna bez klucza albo Pro, użyto modelu lokalnego.")
        default:
            return String(localized: "Chmura nie odpowiedziała, użyto modelu lokalnego.")
        }
    }
}

enum STTError: Error, LocalizedError, Sendable, Equatable {
    /// No route to the cloud: no own key and no Pro session (or the relay refused the session).
    case missingKey
    /// The Pro relay's monthly cloud limit is used up (402); the take falls back to the local engine.
    case quotaExceeded
    /// The Keychain did not answer in time (an ACL prompt is open or was denied); the take falls back.
    case keychainTimeout
    case unauthorized
    case rateLimited
    case tooLarge
    case timeout
    case server(Int, String)
    case empty
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return String(localized: "Brak dostępu do chmury. Dodaj klucz albo włącz Pro w Ustawieniach.")
        case .quotaExceeded:
            return String(localized: "Limit chmury w tym miesiącu jest wyczerpany. Captylo użyje modelu lokalnego.")
        case .keychainTimeout:
            return String(localized: "Pęk kluczy nie odpowiedział na czas.")
        case .unauthorized:
            return String(localized: "Nieprawidłowy klucz API")
        case .rateLimited:
            return String(localized: "Przekroczono limit zapytań. Spróbuj ponownie za chwilę.")
        case .tooLarge:
            return String(localized: "Nagranie jest za duże, aby wysłać je do chmury.")
        case .timeout:
            return String(localized: "Przekroczono czas oczekiwania na odpowiedź serwera.")
        case .server(let code, _):
            return String(localized: "Błąd serwera (\(code)).")
        case .empty:
            return String(localized: "Serwer zwrócił pustą transkrypcję.")
        case .network(let message):
            return String(localized: "Błąd sieci: \(message)")
        }
    }
}

/// One cloud upload. `wav` is 16 kHz mono Int16 WAV, `fileName` is `<id>.wav`.
struct STTRequest: Sendable, Equatable {
    var wav: Data
    var fileName: String
    var model: String
    /// ISO code, "pl" by default; nil = auto detect.
    var language: String?
    var vocabulary: [String]
    var audioSeconds: Double

    init(wav: Data, fileName: String, model: String, language: String? = "pl", vocabulary: [String] = [], audioSeconds: Double) {
        self.wav = wav
        self.fileName = fileName
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        self.audioSeconds = audioSeconds
    }
}
