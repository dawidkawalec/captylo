import Foundation

/// Speech engine chosen once in Modele. Persisted as the raw value under `AppSettings.Key.sttEngine`.
enum STTEngine: String, Codable, CaseIterable, Hashable, Sendable {
    case parakeet
    case elevenLabs

    var isCloud: Bool { self == .elevenLabs }

    /// Model id reported in `TranscriptionResult.modelName` and shown in history.
    var modelName: String {
        switch self {
        case .parakeet: return "parakeet-tdt-0.6b-v3"
        case .elevenLabs: return "scribe_v2"
        }
    }

    var displayName: String {
        switch self {
        case .parakeet: return String(localized: "Parakeet (lokalnie)")
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
    /// True when the cloud engine failed and Parakeet produced the text.
    let usedFallback: Bool

    init(text: String, modelName: String, ms: Int, usedFallback: Bool = false) {
        self.text = text
        self.modelName = modelName
        self.ms = ms
        self.usedFallback = usedFallback
    }
}

enum STTError: Error, LocalizedError, Sendable, Equatable {
    case missingKey
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
            return String(localized: "Brak klucza API. Dodaj go w zakładce Modele.")
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
