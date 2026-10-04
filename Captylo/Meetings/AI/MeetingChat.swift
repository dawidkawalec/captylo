import Foundation
import os

/// One non-streaming "Captylo AI" call over meeting text, shared by the AI notes
/// (`MeetingSummarizer`), the transcript fixes (`MeetingTranscriptCorrector`) and the asks: the
/// data as the user message and the job as a `CaptyloAITask` on the Pro relay, which adds its own
/// instructions and picks the model (the instructions never ship in the app). An own-key route is
/// refused: the meeting AI is Pro only and runs only on the relay. Errors come back as
/// `MeetingSummaryError`; the session's timeouts are the deadline (`HTTP.meetingLLMSession`).
struct MeetingChat: Sendable {
    let session: URLSession

    struct Reply: Sendable, Equatable {
        /// The answer with any reasoning block stripped; never empty.
        let text: String
        let finishReason: String?
        /// The model that answered, as history keeps it: always the relay's `captylo-ai`.
        let model: String
    }

    /// The relay route from `provider`, or `noKey` when there is none (no Pro session) or the
    /// route is an own key's.
    static func resolve(_ provider: @Sendable () async -> AIRoute?) async throws -> AIRoute {
        guard let route = await provider(), route.isRelay, !route.key.isEmpty else { throw MeetingSummaryError.noKey }
        return route
    }

    /// `maxTokens` is the answer cap.
    func complete(route: AIRoute, task: CaptyloAITask, user: String, maxTokens: Int) async throws -> Reply {
        guard route.isRelay else { throw MeetingSummaryError.noKey }
        let request = route.client.taskRequest(task, user: user, maxTokens: maxTokens, key: route.key)
        let (data, status) = try await send(request)
        if let refusal = Self.relayRefusal(status) {
            Log.enhancement.error("Meeting AI relay refused the request: HTTP \(status)")
            throw refusal
        }
        guard (200..<300).contains(status) else {
            Log.enhancement.error("Meeting AI call failed: HTTP \(status)")
            throw MeetingSummaryError.server(status)
        }
        let (content, finishReason) = try route.client.parseChat(data)
        let text = Enhancer.stripReasoning(content ?? "")
        guard !text.isEmpty else { throw MeetingSummaryError.empty }
        return Reply(text: text, finishReason: finishReason, model: Enhancer.servedModel(route: route))
    }

    /// The relay's 402 is the monthly AI limit; 401 (revoked session) and 403 (no longer Pro) are no access.
    static func relayRefusal(_ status: Int) -> MeetingSummaryError? {
        switch status {
        case 402: return .quotaExceeded
        case 401, 403: return .noKey
        default: return nil
        }
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
