import Foundation

/// Result of one AI call. Raw text is delivered whenever `text` is nil.
enum EnhancementOutcome: Sendable, Equatable {
    case enhanced(text: String, ms: Int, model: String)
    /// The model was not called.
    case skipped(EnhancementSkip)
    case failed(EnhancementFailure, ms: Int)

    var text: String? {
        if case .enhanced(let text, _, _) = self { return text }
        return nil
    }

    var ms: Int? {
        switch self {
        case .enhanced(_, let ms, _), .failed(_, let ms): return ms
        case .skipped: return nil
        }
    }

    /// Short Polish note for the history row when AI produced no text, nil on success.
    var note: String? {
        switch self {
        case .enhanced: return nil
        case .skipped(let skip): return skip.note
        case .failed(let failure, _): return failure.note
        }
    }

    /// Full Polish message for toasts and inline errors, nil on success.
    var errorMessage: String? {
        switch self {
        case .enhanced: return nil
        case .skipped(let skip): return skip.errorDescription
        case .failed(let failure, _): return failure.errorDescription
        }
    }
}

/// What one AI call sends and how its answer is judged (built from an `AIMode`).
struct EnhancementJob: Sendable, Equatable {
    var systemPrompt: String
    var kind: AIModeKind
    /// Hard deadline of the call; nil = the enhancer's own (3 s dictation, 15 s files).
    var deadline: Duration?

    init(systemPrompt: String, kind: AIModeKind = .cleanup, deadline: Duration? = nil) {
        self.systemPrompt = systemPrompt
        self.kind = kind
        self.deadline = deadline
    }
}

/// Why the model was not called.
enum EnhancementSkip: LocalizedError, Sendable, Equatable {
    /// Empty text, or 3 words or fewer for a cleanup mode.
    case tooShort
    /// No OpenRouter key in the Keychain.
    case noKey

    var errorDescription: String? {
        switch self {
        case .tooShort:
            return String(localized: "Tekst jest za krótki dla tego trybu (3 słowa lub mniej).")
        case .noKey:
            return OpenRouterError.missingKey.errorDescription
        }
    }

    var note: String {
        switch self {
        case .tooShort: return String(localized: "Za krótkie (3 słowa lub mniej)")
        case .noKey: return String(localized: "Brak klucza AI")
        }
    }
}

/// Why the model's answer was not used.
enum EnhancementFailure: LocalizedError, Sendable, Equatable {
    /// The Keychain read did not finish within the deadline (ACL prompt).
    case keychainTimeout
    /// No answer within the deadline, in seconds.
    case deadline(seconds: Double)
    /// OpenRouter answered with an error status (401, 429, 5xx...).
    case http(status: Int)
    case network(String)
    /// The answer could not be decoded.
    case invalidResponse
    /// The sanity guard threw the answer away.
    case rejected(EnhancementRejection)

    var errorDescription: String? {
        switch self {
        case .keychainTimeout:
            return String(localized: "Pęk kluczy nie odpowiedział na czas.")
        case .deadline:
            return EnhancerError.deadline.errorDescription
        case .http(let status):
            return OpenRouterError.forStatus(status).errorDescription
        case .network(let detail):
            return OpenRouterError.network(detail).errorDescription
        case .invalidResponse:
            return OpenRouterError.decoding.errorDescription
        case .rejected(let rejection):
            return rejection.errorDescription
        }
    }

    var note: String {
        switch self {
        case .keychainTimeout:
            return String(localized: "Pęk kluczy nie odpowiedział na czas")
        case .deadline(let seconds):
            let limit = seconds.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocale.current))
            return String(localized: "Przekroczono limit \(limit) s")
        case .http(let status):
            return String(localized: "Błąd AI \(String(status))")
        case .network:
            return String(localized: "Błąd sieci")
        case .invalidResponse:
            return String(localized: "Nieoczekiwana odpowiedź AI")
        case .rejected(let rejection):
            return rejection.note
        }
    }
}

/// Sanity guard verdicts (gotcha 68).
enum EnhancementRejection: Sendable, Equatable {
    case empty
    /// `finish_reason == "length"`.
    case truncated
    /// Cleanup output below 0.4 x the transcript length.
    case tooShort
    /// Cleanup output above 2.5 x the transcript length.
    case tooLong

    var errorDescription: String {
        switch self {
        case .empty: return String(localized: "Model zwrócił pustą odpowiedź.")
        case .truncated: return String(localized: "Odpowiedź modelu została ucięta.")
        case .tooShort, .tooLong: return String(localized: "Odpowiedź modelu ma podejrzaną długość.")
        }
    }

    var note: String {
        switch self {
        case .empty: return String(localized: "Odrzucono: pusta odpowiedź")
        case .truncated: return String(localized: "Odrzucono: odpowiedź ucięta")
        case .tooShort: return String(localized: "Odrzucono: wynik podejrzanie krótki")
        case .tooLong: return String(localized: "Odrzucono: wynik podejrzanie długi")
        }
    }
}

/// One entry of the OpenRouter model list, as cached in `AppSettings.openRouterModelsCache`.
/// The API DTO (`pricing.prompt` strings, `context_length`, `supported_parameters`) is mapped
/// into this type by `OpenRouterModels`.
struct OpenRouterModel: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// USD per prompt token, nil when unknown.
    var promptPrice: Double?
    /// USD per completion token, nil when unknown.
    var completionPrice: Double?
    var contextLength: Int?
    var supportsReasoning: Bool
    /// True when the model cannot turn reasoning off (`reasoning.mandatory`); sending
    /// `reasoning.enabled = false` to such a model makes OpenRouter answer 400.
    /// Optional so caches written by older builds still decode.
    var reasoningMandatory: Bool?
    /// `reasoning.supported_efforts`, e.g. ["max", "high", "low"].
    var reasoningEfforts: [String]?

    init(
        id: String,
        name: String,
        promptPrice: Double? = nil,
        completionPrice: Double? = nil,
        contextLength: Int? = nil,
        supportsReasoning: Bool = false,
        reasoningMandatory: Bool? = nil,
        reasoningEfforts: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.promptPrice = promptPrice
        self.completionPrice = completionPrice
        self.contextLength = contextLength
        self.supportsReasoning = supportsReasoning
        self.reasoningMandatory = reasoningMandatory
        self.reasoningEfforts = reasoningEfforts
    }

    /// How a chat request for this model sets the `reasoning` field.
    var reasoningPolicy: ReasoningPolicy {
        guard reasoningMandatory == true else { return .disabled }
        return .minimal(effort: ReasoningPolicy.lowestEffort(from: reasoningEfforts ?? []))
    }
}

/// The `reasoning` object sent to OpenRouter. Cleanup wants no thinking at all, but some
/// models (111 of ~460 on 2026-09-26, e.g. z-ai/glm-5.3-flash) reject `enabled: false`.
enum ReasoningPolicy: Equatable, Sendable {
    /// `{"enabled": false}`: the default, works for every model that allows it.
    case disabled
    /// `{"effort": <lowest supported>, "exclude": true}` for models with mandatory reasoning.
    case minimal(effort: String)

    static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// The cheapest effort the model lists; "low" when the list is empty or unknown.
    static func lowestEffort(from supported: [String]) -> String {
        effortOrder.first { supported.contains($0) } ?? "low"
    }

    /// Model id -> policy from the cached model list (`AppSettings.openRouterModelsCache`).
    static func lookup(_ modelID: String, inCache data: Data?) -> ReasoningPolicy {
        guard let data, let models = try? JSONDecoder().decode([OpenRouterModel].self, from: data),
              let model = models.first(where: { $0.id == modelID })
        else { return .disabled }
        return model.reasoningPolicy
    }
}

extension OpenRouterModel {
    static let defaultID = "openai/gpt-4.1-mini"

    /// Quick picks shown above the full list in Modele (docs/architecture.md).
    static let quickPickIDs: [String] = [
        "openai/gpt-4.1-mini",
        "openai/gpt-oss-120b",
        "google/gemini-2.5-flash-lite",
        "anthropic/claude-haiku-4.5",
        "mistralai/mistral-small-3.2-24b-instruct",
    ]

    /// The cached model list is refreshed after this age.
    static let cacheMaxAge: TimeInterval = 24 * 60 * 60
}
