import Foundation
import os

/// One non-streaming AI call over meeting text, shared by the AI notes (`MeetingSummarizer`), the
/// transcript fixes (`MeetingTranscriptCorrector`) and the asks: the request on the route (own key
/// with the meetings model, or the Pro relay that picks the model itself), one retry with minimal
/// reasoning for an own-key model that rejects `enabled: false`, and the errors as
/// `MeetingSummaryError`. The session's timeouts are the deadline (`HTTP.meetingLLMSession`).
struct MeetingChat: Sendable {
    let session: URLSession
    /// Model id -> how to send `reasoning` (mandatory-reasoning models reject `enabled: false`).
    /// Not asked for the relay, whose model is unknown here (reasoning off).
    let reasoning: @Sendable (String) -> ReasoningPolicy

    struct Reply: Sendable, Equatable {
        /// The answer with any reasoning block stripped; never empty.
        let text: String
        let finishReason: String?
        /// The model that answered: the chosen one with an own key, the relay's otherwise.
        let model: String
    }

    /// The route from `provider`, or `noKey` when there is none (no own key and no Pro session).
    static func resolve(_ provider: @Sendable () async -> AIRoute?) async throws -> AIRoute {
        guard let route = await provider(), !route.key.isEmpty else { throw MeetingSummaryError.noKey }
        return route
    }

    /// `maxTokens` is the answer cap; reasoning models get `Enhancer.reasoningAllowance` on top.
    func complete(route: AIRoute, system: String, user: String, maxTokens: Int) async throws -> Reply {
        let model = route.model ?? Enhancer.relayModelPlaceholder
        let policy = route.isRelay ? .disabled : reasoning(model)
        var (data, status) = try await send(request(route: route, model: model, system: system, user: user, policy: policy, maxTokens: maxTokens))
        // A model missing from the cached list may still require reasoning: one retry with minimal effort.
        if !route.isRelay, policy == .disabled, Enhancer.isReasoningRejection(status: status, body: data) {
            Log.enhancement.notice("\(model, privacy: .public) requires reasoning, retrying the meeting call with minimal effort")
            (data, status) = try await send(request(route: route, model: model, system: system, user: user, policy: .minimal(effort: "low"), maxTokens: maxTokens))
        }
        if route.isRelay, let refusal = Self.relayRefusal(status) {
            Log.enhancement.error("Meeting AI relay refused the request: HTTP \(status)")
            throw refusal
        }
        guard (200..<300).contains(status) else {
            Log.enhancement.error("Meeting AI call failed: HTTP \(status) \(HTTP.shortBody(data), privacy: .public)")
            throw MeetingSummaryError.server(status)
        }
        let (content, finishReason) = try route.client.parseChat(data)
        let text = Enhancer.stripReasoning(content ?? "")
        guard !text.isEmpty else { throw MeetingSummaryError.empty }
        return Reply(text: text, finishReason: finishReason, model: Enhancer.servedModel(route: route, answer: data))
    }

    /// The relay's 402 is the monthly AI limit; 401 (revoked session) and 403 (no longer Pro) are no access.
    static func relayRefusal(_ status: Int) -> MeetingSummaryError? {
        switch status {
        case 402: return .quotaExceeded
        case 401, 403: return .noKey
        default: return nil
        }
    }

    private func request(route: AIRoute, model: String, system: String, user: String, policy: ReasoningPolicy, maxTokens: Int) -> URLRequest {
        let base = maxTokens + (Enhancer.isReasoningModel(model) ? Enhancer.reasoningAllowance : 0)
        return route.client.chatRequest(
            model: model,
            system: system,
            transcript: user,
            maxTokens: Enhancer.tokens(base, for: policy),
            key: route.key,
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
