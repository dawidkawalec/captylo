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

    private let chat: MeetingChat
    private let keyProvider: @Sendable () async -> String?
    private let modelProvider: @Sendable () async -> String

    /// - Parameter reasoning: model id -> how to send `reasoning` (mandatory-reasoning models
    ///   reject `enabled: false`).
    init(
        client: OpenRouterClient = OpenRouterClient(),
        session: URLSession = HTTP.meetingLLMSession,
        key: @escaping @Sendable () async -> String?,
        model: @escaping @Sendable () async -> String,
        reasoning: @escaping @Sendable (String) -> ReasoningPolicy = { _ in .disabled }
    ) {
        chat = MeetingChat(client: client, session: session, reasoning: reasoning)
        keyProvider = key
        modelProvider = model
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
        let started = ContinuousClock.now

        let reply = try await chat.complete(model: model, key: key, system: system, user: user, maxTokens: Self.maxTokens)
        if reply.finishReason == "length" {
            // Cut off notes still beat none; the last section may be incomplete.
            Log.enhancement.notice("Meeting notes reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting notes ok in \(ms) ms with \(model, privacy: .public)")
        return (reply.text, model)
    }
}
