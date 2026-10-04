import Foundation

enum MeetingSummaryError: LocalizedError, Sendable, Equatable {
    /// No route: no Pro session (or the relay refused the session). The meeting AI runs only on
    /// the relay, so an own AI key does not count.
    case noKey
    case noTranscript
    case timedOut
    case server(Int)
    case empty
    /// The Pro relay's monthly AI limit is used up (402).
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .noKey:
            return String(localized: "Brak dostępu do AI spotkań. Włącz Captylo Pro.")
        case .quotaExceeded:
            return EnhancementFailure.quotaExceeded.errorDescription
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
/// tokens). Non-streaming, on `HTTP.meetingLLMSession`, whose timeouts are the deadline. Runs
/// on the Pro relay as "Captylo AI" (`CloudRouter.relayAIRoute`), which holds the instructions
/// for the chosen template.
actor MeetingSummarizer {
    /// Answer cap: the five sections of a 2 h meeting fit well under it.
    static let maxTokens = 4_000
    /// Fewer spoken words than this (echo excluded) is not a conversation worth notes.
    static let minimumWords = 5

    private let chat: MeetingChat
    private let routeProvider: @Sendable () async -> AIRoute?

    /// - Parameter route: the Pro relay, or nil (`noKey`).
    init(session: URLSession = HTTP.meetingLLMSession, route: @escaping @Sendable () async -> AIRoute?) {
        chat = MeetingChat(session: session)
        routeProvider = route
    }

    func summarize(meeting: MeetingRecord, segments: [MeetingSegmentRecord], template: MeetingTemplate) async throws -> (markdown: String, model: String) {
        let route = try await MeetingChat.resolve(routeProvider)
        let spoken = segments.filter { !$0.isEcho }
        guard spoken.reduce(0, { $0 + WordCounter.count($1.text) }) >= Self.minimumWords else {
            throw MeetingSummaryError.noTranscript
        }
        let user = MeetingNotesPrompt.user(meeting: meeting, segments: spoken)
        let task = CaptyloAITask(kind: .meetingNotes, template: template.id)
        let started = ContinuousClock.now

        let reply = try await chat.complete(route: route, task: task, user: user, maxTokens: Self.maxTokens)
        if reply.finishReason == "length" {
            // Cut off notes still beat none; the last section may be incomplete.
            Log.enhancement.notice("Meeting notes reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting notes ok in \(ms) ms with \(reply.model, privacy: .public)")
        return (reply.text, reply.model)
    }
}
