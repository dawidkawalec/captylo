import Foundation

/// Request builders and parsers for the OpenRouter API (docs/architecture.md, AI cleanup).
/// Pure value type: no networking here, so every request and parser is unit-tested with fixtures.
struct OpenRouterClient: Sendable, Equatable {
    static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    /// App attribution headers (`X-Title`, `HTTP-Referer`) shown on openrouter.ai.
    static let appTitle = "Captylo"
    static let appReferer = "https://captylo.com"

    let baseURL: URL

    init(baseURL: URL = OpenRouterClient.defaultBaseURL) {
        self.baseURL = baseURL
    }

    // MARK: Chat completions

    /// Non-streaming cleanup call: system prompt first, the transcript alone as the user message,
    /// `temperature 0`, bounded `max_tokens`, reasoning off, provider sorted by latency.
    func chatRequest(
        model: String,
        system: String,
        transcript: String,
        maxTokens: Int,
        key: String,
        reasoning: ReasoningPolicy = .disabled
    ) -> URLRequest {
        let reasoningBody: ChatBody.Reasoning
        switch reasoning {
        case .disabled:
            reasoningBody = ChatBody.Reasoning(enabled: false, effort: nil, exclude: nil)
        case .minimal(let effort):
            reasoningBody = ChatBody.Reasoning(enabled: nil, effort: effort, exclude: true)
        }
        let body = ChatBody(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: transcript),
            ],
            temperature: 0,
            maxTokens: maxTokens,
            reasoning: reasoningBody,
            provider: ChatBody.Provider(sort: "latency")
        )
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(body)
        applyHeaders(to: &request, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// `choices[0].message.content` as an optional string plus `finish_reason` (gotcha 68).
    func parseChat(_ data: Data) throws -> (text: String?, finishReason: String?) {
        let response: ChatResponse
        do {
            response = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw OpenRouterError.decoding
        }
        if let error = response.error {
            throw Self.mapStatus(error.code ?? 500) ?? .server(error.code ?? 500)
        }
        guard let choice = response.choices?.first else {
            throw OpenRouterError.decoding
        }
        return (choice.message?.content, choice.finishReason)
    }

    /// `$.model` of a chat answer: the model that actually answered (the Pro relay picks it on
    /// the server). Nil when absent or blank.
    static func responseModel(_ data: Data) -> String? {
        struct Answer: Decodable {
            let model: String?
        }
        guard let model = (try? JSONDecoder().decode(Answer.self, from: data))?.model?
            .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return model
    }

    // MARK: Key and models

    /// `GET /auth/key`: 200 = valid, 401 = invalid. Also used as the prewarm request.
    func keyCheckRequest(key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "auth/key"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, key: key)
        return request
    }

    /// `GET /models` (public, no auth).
    func modelsRequest() -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue(Self.appTitle, forHTTPHeaderField: "X-Title")
        request.setValue(Self.appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Text-in / text-out models only; pricing strings become USD per token.
    func parseModels(_ data: Data) throws -> [OpenRouterModel] {
        let response: ModelsResponse
        do {
            response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw OpenRouterError.decoding
        }
        return response.data.compactMap { dto -> OpenRouterModel? in
            guard let architecture = dto.architecture,
                  architecture.inputModalities?.contains("text") == true,
                  architecture.outputModalities?.contains("text") == true
            else { return nil }
            return OpenRouterModel(
                id: dto.id,
                name: dto.name ?? dto.id,
                promptPrice: Self.price(dto.pricing?.prompt),
                completionPrice: Self.price(dto.pricing?.completion),
                contextLength: dto.contextLength,
                supportsReasoning: dto.supportedParameters?.contains("reasoning") ?? false,
                reasoningMandatory: dto.reasoning?.mandatory,
                reasoningEfforts: dto.reasoning?.supportedEfforts
            )
        }
    }

    /// nil for 2xx, a typed error otherwise.
    static func mapStatus(_ code: Int) -> OpenRouterError? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .server(code)
        }
    }

    // MARK: Helpers

    private func applyHeaders(to request: inout URLRequest, key: String) {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appTitle, forHTTPHeaderField: "X-Title")
        request.setValue(Self.appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private static func price(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value >= 0, value.isFinite else { return nil }
        return value
    }

    // MARK: Wire types

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatBody: Encodable {
        struct Reasoning: Encodable {
            let enabled: Bool?
            let effort: String?
            let exclude: Bool?
        }

        struct Provider: Encodable {
            let sort: String
        }

        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let maxTokens: Int
        let reasoning: Reasoning
        let provider: Provider

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, reasoning, provider
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        struct APIError: Decodable {
            let message: String?
            let code: Int?
        }

        let choices: [Choice]?
        let error: APIError?
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }

            struct Architecture: Decodable {
                let inputModalities: [String]?
                let outputModalities: [String]?

                enum CodingKeys: String, CodingKey {
                    case inputModalities = "input_modalities"
                    case outputModalities = "output_modalities"
                }
            }

            let id: String
            let name: String?
            let pricing: Pricing?
            let contextLength: Int?
            let architecture: Architecture?
            let supportedParameters: [String]?
            let reasoning: ReasoningInfo?

            struct ReasoningInfo: Decodable {
                let mandatory: Bool?
                let supportedEfforts: [String]?

                enum CodingKeys: String, CodingKey {
                    case mandatory
                    case supportedEfforts = "supported_efforts"
                }
            }

            enum CodingKeys: String, CodingKey {
                case id, name, pricing, architecture, reasoning
                case contextLength = "context_length"
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [Model]
    }
}

enum OpenRouterError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case server(Int)
    case network(String)
    case decoding
    case missingKey

    /// The error for a non-2xx status (a 2xx maps to `.server` too: callers only pass failures).
    static func forStatus(_ code: Int) -> OpenRouterError {
        OpenRouterClient.mapStatus(code) ?? .server(code)
    }

    /// HTTP status this error stands for (history notes), nil for transport errors.
    var status: Int? {
        switch self {
        case .unauthorized: return 401
        case .rateLimited: return 429
        case .server(let code): return code
        case .network, .decoding, .missingKey: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Nieprawidłowy klucz AI.")
        case .rateLimited:
            return String(localized: "AI: przekroczono limit zapytań. Spróbuj za chwilę.")
        case .server(let code):
            return String(localized: "AI: błąd serwera (kod \(String(code))).")
        case .network(let detail):
            return String(localized: "Błąd sieci: \(detail)")
        case .decoding:
            return String(localized: "Nieoczekiwana odpowiedź AI.")
        case .missingKey:
            return Self.missingKeyMessage
        }
    }

    /// The one no-key message of the app ("Przetwórz przez AI", "Testuj tryb", the test call):
    /// the key field lives in the "Poprawianie przez AI" panel on Modele, not in Ustawienia.
    static var missingKeyMessage: String {
        String(localized: "Brak klucza AI. Dodaj go na ekranie Modele, w panelu Poprawianie przez AI.")
    }
}
