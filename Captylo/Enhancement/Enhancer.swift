import Foundation

/// OpenRouter cleanup with one hard deadline (gotchas 64, 65, 68). Never throws: any failure
/// yields `.failed` and the caller pastes the raw transcript.
actor Enhancer: TextEnhancing {
    /// Transcripts with this many words or fewer skip the model.
    static let minimumWords = 4
    /// Budget that must remain for the single connection-lost retry.
    static let retryBudget: Duration = .milliseconds(800)
    /// Budget for the settings "Test" call and the key check (not on the hot path).
    static let utilityDeadline: Duration = .seconds(10)

    private let client: OpenRouterClient
    private let keyStore: KeyStore
    private let modelProvider: @Sendable () -> String
    /// Model id -> how to send `reasoning` (mandatory-reasoning models reject `enabled: false`).
    private let reasoningProvider: @Sendable (String) -> ReasoningPolicy
    private let session: URLSession
    private let deadline: Duration
    private let tokenCap: Int
    private let prewarmer = Prewarmer()

    /// Output cap of the brief's `max_tokens` rule for dictation.
    static let defaultTokenCap = 2048
    /// Extra tokens for gpt-oss, which cannot fully turn reasoning off and counts it in `max_tokens`.
    static let reasoningAllowance = 512

    init(
        client: OpenRouterClient,
        keyStore: KeyStore,
        modelProvider: @escaping @Sendable () -> String,
        reasoningProvider: @escaping @Sendable (String) -> ReasoningPolicy = { _ in .disabled },
        session: URLSession = HTTP.llmSession,
        deadline: Duration = .seconds(3),
        tokenCap: Int = Enhancer.defaultTokenCap
    ) {
        self.client = client
        self.keyStore = keyStore
        self.modelProvider = modelProvider
        self.reasoningProvider = reasoningProvider
        self.session = session
        self.deadline = deadline
        self.tokenCap = tokenCap
    }

    // MARK: TextEnhancing

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        guard !Self.shouldSkip(raw, kind: job.kind) else { return .skipped(.tooShort) }
        let deadline = job.deadline ?? self.deadline

        // The Keychain read counts against the deadline: an ACL prompt must not hold the widget.
        let clock = ContinuousClock()
        let start = clock.now
        let key: String
        switch await keyStore.load(KeyStore.Account.openRouter, timeout: deadline) {
        case .value(let value?) where !value.isEmpty:
            key = value
        case .value:
            return .skipped(.noKey)
        case .timedOut:
            Log.enhancement.error("AI skipped: Keychain read did not finish within the deadline")
            return .failed(.keychainTimeout, ms: Self.milliseconds(clock.now - start))
        }

        let model = modelProvider()
        let policy = reasoningProvider(model)
        let baseTokens = Self.maxTokens(forUTF8Count: raw.utf8.count, model: model, kind: job.kind, cap: tokenCap)
        let makeRequest: (ReasoningPolicy) -> URLRequest = { policy in
            self.client.chatRequest(
                model: model,
                system: job.systemPrompt,
                transcript: raw,
                maxTokens: Self.tokens(baseTokens, for: policy),
                key: key,
                reasoning: policy
            )
        }
        let signpost = Log.signposter.beginInterval("enhance")
        defer { Log.signposter.endInterval("enhance", signpost) }

        do {
            var (data, http) = try await sendWithRetry(makeRequest(policy), deadline: deadline, start: start, clock: clock)
            // A model missing from the cached list may still require reasoning: OpenRouter then
            // answers 400 about `reasoning`. Retry once with minimal hidden reasoning.
            if policy == .disabled, Self.isReasoningRejection(status: http.statusCode, body: data),
               deadline - (clock.now - start) > Self.retryBudget {
                Log.enhancement.notice("\(model, privacy: .public) requires reasoning, retrying with minimal effort")
                (data, http) = try await sendWithRetry(makeRequest(.minimal(effort: "low")), deadline: deadline, start: start, clock: clock)
            }
            let ms = Self.milliseconds(clock.now - start)
            if OpenRouterClient.mapStatus(http.statusCode) != nil {
                Log.enhancement.error("AI failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failed(.http(status: http.statusCode), ms: ms)
            }
            let (content, finishReason) = try client.parseChat(data)
            let text = Self.stripReasoning(content ?? "")
            if let rejection = Self.rejectionReason(raw: raw, output: text, finishReason: finishReason, kind: job.kind) {
                Log.enhancement.notice("AI output rejected: \(rejection.errorDescription, privacy: .public)")
                return .failed(.rejected(rejection), ms: ms)
            }
            Log.enhancement.info("AI \(job.kind.rawValue, privacy: .public) ok in \(ms) ms with \(model, privacy: .public)")
            return .enhanced(text: text, ms: ms, model: model)
        } catch {
            let ms = Self.milliseconds(clock.now - start)
            let failure = Self.failure(for: error, deadline: deadline)
            Log.enhancement.error("AI failed after \(ms) ms: \(failure.errorDescription ?? "", privacy: .public)")
            return .failed(failure, ms: ms)
        }
    }

    /// Warms DNS + TLS + H2 with the key check; debounced by the `Prewarmer`.
    func prewarm() async {
        guard case .value(let key?) = await keyStore.load(KeyStore.Account.openRouter), !key.isEmpty else { return }
        await prewarmer.fire(client.keyCheckRequest(key: key), using: session)
    }

    // MARK: Settings helpers

    /// One-token chat call; returns the round trip in milliseconds.
    func test(model: String) async -> Result<Int, any Error> {
        guard case .value(let key?) = await keyStore.load(KeyStore.Account.openRouter), !key.isEmpty else {
            return .failure(OpenRouterError.missingKey)
        }
        let policy = reasoningProvider(model)
        let request = client.chatRequest(
            model: model,
            system: "Reply with the word ok.",
            transcript: "ok",
            maxTokens: Self.tokens(1, for: policy),
            key: key,
            reasoning: policy
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, http) = try await send(request, budget: Self.utilityDeadline)
            let ms = Self.milliseconds(clock.now - start)
            if let error = OpenRouterClient.mapStatus(http.statusCode) {
                Log.enhancement.error("Model test failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failure(error)
            }
            _ = try client.parseChat(data)
            return .success(ms)
        } catch {
            return .failure(Self.wrapped(error))
        }
    }

    /// `GET /auth/key` with the candidate key: success means OpenRouter accepted it.
    func verifyKey(_ key: String) async -> Result<Void, any Error> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(OpenRouterError.missingKey) }
        do {
            let (data, http) = try await send(client.keyCheckRequest(key: trimmed), budget: Self.utilityDeadline)
            if let error = OpenRouterClient.mapStatus(http.statusCode) {
                Log.enhancement.error("Key check failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failure(error)
            }
            return .success(())
        } catch {
            return .failure(Self.wrapped(error))
        }
    }

    // MARK: Rules (pure, unit-tested)

    /// `est = max(16, utf8Count / 3)`; cleanup `min(cap, est * 2 + 64)` (brief 5.3), rewrite
    /// `min(max(4096, cap), est * 3 + 256)` (a translation or an e-mail may grow); gpt-oss `+ 512`.
    nonisolated static func maxTokens(
        forUTF8Count count: Int,
        model: String,
        kind: AIModeKind = .cleanup,
        cap: Int = defaultTokenCap
    ) -> Int {
        let estimate = max(16, count / 3)
        let base: Int
        switch kind {
        case .cleanup:
            base = min(cap, estimate * 2 + 64)
        case .rewrite:
            base = min(max(rewriteTokenCap, cap), estimate * 3 + 256)
        }
        return isReasoningModel(model) ? base + reasoningAllowance : base
    }

    /// Output cap of a rewrite mode on the dictation path.
    static let rewriteTokenCap = 4096

    /// Cleanup skips 3 words or fewer (latency, and a short phrase gains nothing); a rewrite
    /// runs on any non-empty text (translating "dzień dobry" is still useful).
    nonisolated static func shouldSkip(_ raw: String, kind: AIModeKind) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        switch kind {
        case .cleanup: return WordCounter.count(raw) < minimumWords
        case .rewrite: return false
        }
    }

    /// Models whose reasoning tokens count toward `max_tokens` even with reasoning disabled.
    nonisolated static func isReasoningModel(_ model: String) -> Bool {
        model.lowercased().contains("gpt-oss")
    }

    /// Removes `<think>`, `<thinking>` and `<reasoning>` blocks (case-insensitive, across lines;
    /// an unclosed block swallows the rest) and trims whitespace.
    nonisolated static func stripReasoning(_ text: String) -> String {
        var output = text
        for pattern in Self.reasoningPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanity guard (gotcha 68): nil when the output is acceptable. Every kind rejects an empty
    /// or cut-off answer; only cleanup also checks the 0.4...2.5 length ratio (raw > 40 chars),
    /// because a rewrite may legitimately shrink (checklist) or grow (e-mail).
    nonisolated static func rejectionReason(
        raw: String,
        output: String,
        finishReason: String?,
        kind: AIModeKind = .cleanup
    ) -> EnhancementRejection? {
        if output.isEmpty {
            return .empty
        }
        if finishReason == "length" {
            return .truncated
        }
        if kind == .cleanup, raw.count > 40 {
            let ratio = Double(output.count) / Double(raw.count)
            if ratio < 0.4 { return .tooShort }
            if ratio > 2.5 { return .tooLong }
        }
        return nil
    }

    /// Maps a thrown transport or parse error to the failure kept in the outcome.
    nonisolated static func failure(for error: any Error, deadline: Duration) -> EnhancementFailure {
        switch error {
        case EnhancerError.deadline:
            return .deadline(seconds: seconds(deadline))
        case let error as OpenRouterError:
            if let status = error.status { return .http(status: status) }
            if case .network(let detail) = error { return .network(detail) }
            return .invalidResponse
        case let error as URLError:
            return .network(error.localizedDescription)
        default:
            return .network((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static let reasoningPatterns = [
        #"<think>.*?(</think>|\z)"#,
        #"<thinking>.*?(</thinking>|\z)"#,
        #"<reasoning>.*?(</reasoning>|\z)"#,
    ]

    // MARK: Transport

    /// One attempt, plus one immediate retry on connection-lost / TLS failure when > 0.8 s remains.
    private func sendWithRetry(
        _ request: URLRequest,
        deadline: Duration,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> (Data, HTTPURLResponse) {
        let budget = deadline - (clock.now - start)
        guard budget > .zero else { throw EnhancerError.deadline }
        do {
            return try await send(request, budget: budget)
        } catch let error as URLError where Self.isRetryable(error) {
            let remaining = deadline - (clock.now - start)
            guard remaining > Self.retryBudget else { throw error }
            Log.enhancement.notice("Retrying cleanup after \(error.code.rawValue) with \(Self.milliseconds(remaining)) ms left")
            return try await send(request, budget: remaining)
        }
    }

    /// Races the request against `Task.sleep` (gotcha 65): the request task is cancelled on timeout.
    private func send(_ request: URLRequest, budget: Duration) async throws -> (Data, HTTPURLResponse) {
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(for: budget)
                throw EnhancerError.deadline
            }
            defer { group.cancelAll() }
            guard let (data, response) = try await group.next() else {
                throw EnhancerError.deadline
            }
            guard let http = response as? HTTPURLResponse else {
                throw OpenRouterError.decoding
            }
            return (data, http)
        }
    }

    /// Extra room for hidden reasoning tokens, which count against `max_tokens`.
    static let mandatoryReasoningAllowance = 1024

    nonisolated static func tokens(_ base: Int, for policy: ReasoningPolicy) -> Int {
        switch policy {
        case .disabled: return base
        case .minimal: return base + mandatoryReasoningAllowance
        }
    }

    /// 400 whose error message is about the `reasoning` parameter.
    nonisolated static func isReasoningRejection(status: Int, body: Data) -> Bool {
        guard status == 400 else { return false }
        return String(decoding: body, as: UTF8.self).localizedCaseInsensitiveContains("reasoning")
    }

    private nonisolated static func isRetryable(_ error: URLError) -> Bool {
        error.code == .networkConnectionLost || error.code == .secureConnectionFailed
    }

    private nonisolated static func wrapped(_ error: any Error) -> any Error {
        if error is OpenRouterError || error is EnhancerError { return error }
        return OpenRouterError.network(error.localizedDescription)
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

enum EnhancerError: LocalizedError, Sendable, Equatable {
    case deadline

    var errorDescription: String? {
        switch self {
        case .deadline:
            return String(localized: "Model nie odpowiedział na czas.")
        }
    }
}
