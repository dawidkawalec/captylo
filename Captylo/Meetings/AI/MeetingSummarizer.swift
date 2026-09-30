import Foundation

enum MeetingSummaryError: LocalizedError, Sendable, Equatable {
    case noKey
    case noTranscript
    case timedOut
    case server(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey:
            return OpenRouterError.missingKeyMessage
        case .noTranscript:
            return String(localized: "Za mało rozmowy, żeby zrobić notatki.")
        case .timedOut:
            return String(localized: "AI nie odpowiedziało na czas. Spróbuj ponownie.")
        case .server(let code):
            // A wrong key or the rate limit reads the same as everywhere else in the app.
            switch OpenRouterError.forStatus(code) {
            case .unauthorized, .rateLimited:
                return OpenRouterError.forStatus(code).errorDescription
            default:
                return String(localized: "Błąd AI (kod \(code)). Spróbuj ponownie.")
            }
        case .empty:
            return String(localized: "AI zwróciło pustą odpowiedź.")
        }
    }
}

/// AI notes for one meeting: one pass over the whole transcript (a 1 h meeting is ~20-25k
/// tokens; every candidate model has 128k+ context). Non-streaming, on `HTTP.meetingLLMSession`,
/// whose timeouts are the deadline. M4 swaps the key for the Pro relay (`OpenRouterClient(baseURL:)`).
actor MeetingSummarizer {
    /// Answer cap: the five sections of a 2 h meeting fit well under it.
    static let maxTokens = 4_000
    /// Fewer spoken words than this (echo excluded) is not a conversation worth notes.
    static let minimumWords = 5

    private let client: OpenRouterClient
    private let session: URLSession
    private let keyProvider: @Sendable () async -> String?
    private let modelProvider: @Sendable () async -> String
    /// Model id -> how to send `reasoning` (mandatory-reasoning models reject `enabled: false`).
    private let reasoningProvider: @Sendable (String) -> ReasoningPolicy

    init(
        client: OpenRouterClient = OpenRouterClient(),
        session: URLSession = HTTP.meetingLLMSession,
        key: @escaping @Sendable () async -> String?,
        model: @escaping @Sendable () async -> String,
        reasoning: @escaping @Sendable (String) -> ReasoningPolicy = { _ in .disabled }
    ) {
        self.client = client
        self.session = session
        keyProvider = key
        modelProvider = model
        reasoningProvider = reasoning
    }

    func summarize(meeting: MeetingRecord, segments: [MeetingSegmentRecord], template: MeetingTemplate) async throws -> (markdown: String, model: String) {
        guard let key = await keyProvider(), !key.isEmpty else { throw MeetingSummaryError.noKey }
        let spoken = segments.filter { !$0.isEcho }
        guard spoken.reduce(0, { $0 + WordCounter.count($1.text) }) >= Self.minimumWords else {
            throw MeetingSummaryError.noTranscript
        }
        let model = await modelProvider()
        let system = MeetingNotesPrompt.system(template: template)
        let user = MeetingNotesPrompt.user(meeting: meeting, segments: spoken)
        let policy = reasoningProvider(model)
        let started = ContinuousClock.now

        var (data, status) = try await send(request(model: model, system: system, user: user, key: key, policy: policy))
        // A model missing from the cached list may still require reasoning: one retry with minimal effort.
        if policy == .disabled, Enhancer.isReasoningRejection(status: status, body: data) {
            Log.enhancement.notice("\(model, privacy: .public) requires reasoning, retrying the meeting notes with minimal effort")
            (data, status) = try await send(request(model: model, system: system, user: user, key: key, policy: .minimal(effort: "low")))
        }
        guard (200..<300).contains(status) else {
            Log.enhancement.error("Meeting notes failed: HTTP \(status) \(HTTP.shortBody(data), privacy: .public)")
            throw MeetingSummaryError.server(status)
        }
        let (content, finishReason) = try client.parseChat(data)
        let text = Enhancer.stripReasoning(content ?? "")
        guard !text.isEmpty else { throw MeetingSummaryError.empty }
        if finishReason == "length" {
            // Cut off notes still beat none; the last section may be incomplete.
            Log.enhancement.notice("Meeting notes reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting notes ok in \(ms) ms with \(model, privacy: .public)")
        return (text, model)
    }

    // MARK: Transport

    private func request(model: String, system: String, user: String, key: String, policy: ReasoningPolicy) -> URLRequest {
        let base = Self.maxTokens + (Enhancer.isReasoningModel(model) ? Enhancer.reasoningAllowance : 0)
        return client.chatRequest(
            model: model,
            system: system,
            transcript: user,
            maxTokens: Enhancer.tokens(base, for: policy),
            key: key,
            reasoning: policy
        )
    }

    /// The body and status of one attempt; a timeout becomes `.timedOut`, any other transport
    /// error the app's network message.
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenRouterError.decoding }
            return (data, http.statusCode)
        } catch let error as URLError {
            if error.code == .timedOut { throw MeetingSummaryError.timedOut }
            throw OpenRouterError.network(error.localizedDescription)
        }
    }
}
