import Foundation
import os

/// One non-streaming AI call over meeting text, shared by the AI notes (`MeetingSummarizer`) and
/// the transcript fixes (`MeetingTranscriptCorrector`): the request, one retry with minimal
/// reasoning for a model that rejects `enabled: false`, and the errors as `MeetingSummaryError`.
/// The session's timeouts are the deadline (`HTTP.meetingLLMSession`).
struct MeetingChat: Sendable {
    let client: OpenRouterClient
    let session: URLSession
    /// Model id -> how to send `reasoning` (mandatory-reasoning models reject `enabled: false`).
    let reasoning: @Sendable (String) -> ReasoningPolicy

    struct Reply: Sendable, Equatable {
        /// The answer with any reasoning block stripped; never empty.
        let text: String
        let finishReason: String?
    }

    /// `maxTokens` is the answer cap; reasoning models get `Enhancer.reasoningAllowance` on top.
    func complete(model: String, key: String, system: String, user: String, maxTokens: Int) async throws -> Reply {
        let policy = reasoning(model)
        var (data, status) = try await send(request(model: model, system: system, user: user, key: key, policy: policy, maxTokens: maxTokens))
        // A model missing from the cached list may still require reasoning: one retry with minimal effort.
        if policy == .disabled, Enhancer.isReasoningRejection(status: status, body: data) {
            Log.enhancement.notice("\(model, privacy: .public) requires reasoning, retrying the meeting call with minimal effort")
            (data, status) = try await send(request(model: model, system: system, user: user, key: key, policy: .minimal(effort: "low"), maxTokens: maxTokens))
        }
        guard (200..<300).contains(status) else {
            Log.enhancement.error("Meeting AI call failed: HTTP \(status) \(HTTP.shortBody(data), privacy: .public)")
            throw MeetingSummaryError.server(status)
        }
        let (content, finishReason) = try client.parseChat(data)
        let text = Enhancer.stripReasoning(content ?? "")
        guard !text.isEmpty else { throw MeetingSummaryError.empty }
        return Reply(text: text, finishReason: finishReason)
    }

    private func request(model: String, system: String, user: String, key: String, policy: ReasoningPolicy, maxTokens: Int) -> URLRequest {
        let base = maxTokens + (Enhancer.isReasoningModel(model) ? Enhancer.reasoningAllowance : 0)
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
