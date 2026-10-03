import Foundation
import Testing
@testable import Captylo

struct EnhancementEnhancerTests {
    private static let raw = "no więc to jest dłuższy testowy transkrypt który ma zdecydowanie więcej niż trzy słowa"
    private static let systemPrompt = CleanupPrompt.system(template: "", vocabulary: [])

    private func makeEnhancer(
        _ handler: @escaping StubURLProtocol.Handler,
        key: String? = "sk-or-test",
        model: String = "openai/gpt-4.1-mini",
        deadline: Duration = .seconds(3),
        relay: Bool = false
    ) -> (Enhancer, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let client = OpenRouterClient(baseURL: baseURL)
        // The relay route has no model: the server picks it.
        let route = key.map { AIRoute(client: client, key: $0, model: relay ? nil : model) }
        let enhancer = Enhancer(
            client: client,
            route: { _ in .value(route) },
            session: StubURLProtocol.makeSession(),
            deadline: deadline
        )
        return (enhancer, baseURL)
    }

    private static func json(of request: URLRequest) -> [String: Any] {
        AccountFixtures.body(of: request)
    }

    // MARK: The Pro relay

    @Test func relayRouteSendsThePlaceholderModelAndTheSessionAndReportsTheServedModel() async throws {
        let cleaned = "Więc to jest dłuższy testowy transkrypt, który ma zdecydowanie więcej niż trzy słowa."
        let (enhancer, baseURL) = makeEnhancer({ request in
            let body = Self.json(of: request)
            #expect(request.url?.path().hasSuffix("/chat/completions") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
            #expect(body["model"] as? String == Enhancer.relayModelPlaceholder)
            #expect((body["reasoning"] as? [String: Any])?["enabled"] as? Bool == false)
            return .json(Fixtures.chat(content: "\"\(cleaned)\"", finish: "stop"))
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }

        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .enhanced(let text, _, let model) = outcome else {
            Issue.record("Expected .enhanced, got \(outcome)")
            return
        }
        #expect(text == cleaned)
        // The model the relay used, from the answer.
        #expect(model == "openai/gpt-4.1-mini")
        #expect(Enhancer.relayModelPlaceholder == "captylo-pro")
    }

    @Test func relayAnswerWithoutAModelNamesThePlaceholder() async {
        let cleaned = "Więc to jest dłuższy testowy transkrypt, który ma zdecydowanie więcej niż trzy słowa."
        let (enhancer, baseURL) = makeEnhancer({ _ in
            .json(#"{"choices":[{"message":{"content":"\#(cleaned)"},"finish_reason":"stop"}]}"#)
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }
        guard case .enhanced(_, _, let model) = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .enhanced")
            return
        }
        #expect(model == Enhancer.relayModelPlaceholder)
    }

    @Test func relayQuotaFailsWithQuotaExceeded() async {
        let (enhancer, baseURL) = makeEnhancer({ _ in
            .json(#"{"error":"quota_exceeded","resetsAt":"2026-11-01T00:00:00.000Z"}"#, status: 402)
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed(.quotaExceeded, _) = outcome else {
            Issue.record("Expected .failed(.quotaExceeded), got \(outcome)")
            return
        }
        #expect(outcome.text == nil, "the raw text is pasted")
        #expect(outcome.errorMessage == "Limit AI w tym miesiącu jest wyczerpany.")
        #expect(outcome.note == "Limit AI wyczerpany")
    }

    @Test func relayRefusingTheSessionReadsAsNoKey() async {
        let (enhancer, baseURL) = makeEnhancer({ _ in
            .json(#"{"error":"pro_required"}"#, status: 403)
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) == .skipped(.noKey))
    }

    @Test func routeTimeoutIsAKeychainTimeout() async {
        let enhancer = Enhancer(client: OpenRouterClient(), route: { _ in .timedOut }, session: StubURLProtocol.makeSession())
        guard case .failed(.keychainTimeout, _) = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed(.keychainTimeout)")
            return
        }
    }

    @Test func prewarmOnTheRelayHitsItsHealthEndpoint() async throws {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer({ request in
            #expect(request.url?.path().hasSuffix("/health") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            counter.increment()
            return .json(#"{"ok":true}"#)
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }
        await enhancer.prewarm()
        try await waitUntil { counter.value >= 1 }
        #expect(counter.value == 1)
    }

    @Test func modelTestOnTheRelayUsesThePlaceholder() async throws {
        let (enhancer, baseURL) = makeEnhancer({ request in
            #expect(Self.json(of: request)["model"] as? String == Enhancer.relayModelPlaceholder)
            return .json(Fixtures.chat(content: "\"ok\"", finish: "stop"))
        }, key: "session-token", relay: true)
        defer { StubURLProtocol.unregister(baseURL) }
        _ = try await enhancer.test(model: "openai/gpt-4.1-mini").get()
    }

    // MARK: Pure rules

    @Test func maxTokensRule() {
        // est = max(16, bytes / 3); cap = min(2048, est * 2 + 64)
        let model = "openai/gpt-4.1-mini"
        #expect(Enhancer.maxTokens(forUTF8Count: 0, model: model) == 96)
        #expect(Enhancer.maxTokens(forUTF8Count: 30, model: model) == 96)
        #expect(Enhancer.maxTokens(forUTF8Count: 300, model: model) == 264)
        #expect(Enhancer.maxTokens(forUTF8Count: 2900, model: model) == 1996)
        #expect(Enhancer.maxTokens(forUTF8Count: 3000, model: model) == 2048)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: model) == 2048)
    }

    @Test func maxTokensAddsTheGptOssReasoningAllowance() {
        // gpt-oss counts its reasoning in max_tokens: + 512 on top of the capped rule.
        // 60 bytes: est 20, base 104.
        #expect(Enhancer.maxTokens(forUTF8Count: 60, model: "openai/gpt-oss-120b") == 104 + 512)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: "openai/gpt-oss-120b") == 2048 + 512)
        #expect(Enhancer.maxTokens(forUTF8Count: 60, model: "google/gemini-2.5-flash-lite") == 104)
    }

    @Test func maxTokensHonorsALargerFileCap() {
        #expect(Enhancer.maxTokens(forUTF8Count: 9000, model: "openai/gpt-4.1-mini", cap: 8192) == 6064)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: "openai/gpt-4.1-mini", cap: 8192) == 8192)
    }

    @Test func fileLLMSessionOutlastsTheFileDeadline() {
        let configuration = HTTP.fileLLMSession.configuration
        #expect(configuration.timeoutIntervalForRequest > 15)
        #expect(configuration.timeoutIntervalForResource > 15)
    }

    @Test func stripsReasoningBlocks() {
        #expect(Enhancer.stripReasoning("<think>plan\nplan</think>\n\nCzysty tekst.") == "Czysty tekst.")
        #expect(Enhancer.stripReasoning("<THINKING>x</THINKING> Tekst <Reasoning>y\nz</Reasoning>") == "Tekst")
        #expect(Enhancer.stripReasoning("  Bez bloków.  ") == "Bez bloków.")
        // An unclosed block swallows the rest, so a leaked chain of thought never gets pasted.
        #expect(Enhancer.stripReasoning("Wynik. <think>nigdy nie zamknięte") == "Wynik.")
        #expect(Enhancer.stripReasoning("<think>a</think><think>b</think>") == "")
    }

    @Test func sanityGuardCases() {
        let long = String(repeating: "słowo ", count: 20)
        #expect(Enhancer.rejectionReason(raw: long, output: "", finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "length") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: "Tak.", finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long + long + long, finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "stop") == nil)
        #expect(Enhancer.rejectionReason(raw: long, output: String(long.prefix(60)), finishReason: nil) == nil)
        // Short transcripts (<= 40 chars) skip the length ratio check.
        #expect(Enhancer.rejectionReason(raw: "krótki tekst do sprawdzenia", output: "Ok", finishReason: "stop") == nil)
    }

    // MARK: enhance

    @Test func skipsShortTranscriptsWithoutNetwork() async {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer { _ in
            counter.increment()
            return .json(Fixtures.chat(content: "\"x\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance("tylko trzy słowa", systemPrompt: Self.systemPrompt) == .skipped(.tooShort))
        #expect(await enhancer.enhance("", systemPrompt: Self.systemPrompt) == .skipped(.tooShort))
        // A rewrite mode still skips empty text.
        #expect(await enhancer.enhance("  ", job: EnhancementJob(systemPrompt: "p", kind: .rewrite)) == .skipped(.tooShort))
        #expect(counter.value == 0)
    }

    @Test func skipsWithoutKey() async {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer({ _ in
            counter.increment()
            return .json(Fixtures.chat(content: "\"x\"", finish: "stop"))
        }, key: nil)
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) == .skipped(.noKey))
        #expect(counter.value == 0)
    }

    @Test func returnsEnhancedTextWithModelAndTiming() async throws {
        let cleaned = "Więc to jest dłuższy testowy transkrypt, który ma zdecydowanie więcej niż trzy słowa."
        let (enhancer, baseURL) = makeEnhancer({ request in
            #expect(request.url?.path().hasSuffix("/chat/completions") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
            return .json(Fixtures.chat(content: "\"<think>hm</think>\\n\(cleaned)\"", finish: "stop"))
        }, model: "google/gemini-2.5-flash-lite")
        defer { StubURLProtocol.unregister(baseURL) }

        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .enhanced(let text, let ms, let model) = outcome else {
            Issue.record("Expected .enhanced, got \(outcome)")
            return
        }
        #expect(text == cleaned)
        #expect(model == "google/gemini-2.5-flash-lite")
        #expect(ms >= 0 && ms < 3000)
        #expect(outcome.text == cleaned)
    }

    @Test func failsOnTruncatedOrEmptyOutput() async {
        let (truncated, url1) = makeEnhancer { _ in .json(Fixtures.chat(content: "\"\(Self.raw)\"", finish: "length")) }
        defer { StubURLProtocol.unregister(url1) }
        guard case .failed = await truncated.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed on finish_reason length")
            return
        }

        let (empty, url2) = makeEnhancer { _ in .json(Fixtures.chat(content: "null", finish: "stop")) }
        defer { StubURLProtocol.unregister(url2) }
        guard case .failed = await empty.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed on null content")
            return
        }
    }

    @Test func failsOnHTTPErrorsWithPolishReason() async {
        let (enhancer, baseURL) = makeEnhancer { _ in .json(#"{"error":{"message":"bad key","code":401}}"#, status: 401) }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed(let failure, _) = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
        #expect(failure == .http(status: 401))
        #expect(failure.errorDescription == OpenRouterError.unauthorized.errorDescription)
        #expect(outcome.note == String(localized: "Błąd AI \(String(401))"))
    }

    @Test func deadlineYieldsFailedWithinBudget() async {
        let (enhancer, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: "\"late\"", finish: "stop"), delay: .seconds(5))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        let elapsed = clock.now - start

        guard case .failed(let failure, let ms) = outcome else {
            Issue.record("Expected .failed on deadline, got \(outcome)")
            return
        }
        #expect(failure == .deadline(seconds: 3))
        #expect(failure.errorDescription == EnhancerError.deadline.errorDescription)
        #expect(elapsed >= .seconds(2.9), "finished too early: \(elapsed)")
        #expect(elapsed < .seconds(3.3), "deadline overshoot: \(elapsed)")
        #expect(ms >= 2900 && ms < 3300)
    }

    @Test func retriesOnceOnConnectionLost() async {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer { _ in
            counter.increment()
            if counter.value == 1 {
                return .failure(.networkConnectionLost)
            }
            return .json(Fixtures.chat(content: "\"\(Self.raw)\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        #expect(outcome.text == Self.raw)
        #expect(counter.value == 2)
    }

    @Test func doesNotRetryOtherNetworkErrors() async {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer { _ in
            counter.increment()
            return .failure(.notConnectedToInternet)
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
        #expect(counter.value == 1)
    }

    @Test func doesNotRetryWhenBudgetIsTooSmall() async {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer({ _ in
            counter.increment()
            return .failure(.networkConnectionLost)
        }, deadline: .milliseconds(500))
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
        #expect(counter.value == 1)
    }

    // MARK: test / verifyKey / prewarm

    @Test func testSendsOneTokenCallAndReportsMilliseconds() async throws {
        let (enhancer, baseURL) = makeEnhancer { request in
            #expect(request.url?.path().hasSuffix("/chat/completions") == true)
            return .json(Fixtures.chat(content: "\"ok\"", finish: "length"), delay: .milliseconds(50))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let ms = try await enhancer.test(model: "openai/gpt-4.1-mini").get()
        #expect(ms >= 40 && ms < 5000)
    }

    @Test func testReportsMissingKeyAndBadKey() async {
        let (noKey, url1) = makeEnhancer({ _ in .json("{}") }, key: nil)
        defer { StubURLProtocol.unregister(url1) }
        if case .success = await noKey.test(model: "x") {
            Issue.record("Expected failure without a key")
        }

        let (badKey, url2) = makeEnhancer { _ in .json(#"{"error":{"message":"no","code":401}}"#, status: 401) }
        defer { StubURLProtocol.unregister(url2) }
        guard case .failure(let error) = await badKey.test(model: "x") else {
            Issue.record("Expected failure on 401")
            return
        }
        #expect(error as? OpenRouterError == .unauthorized)
    }

    @Test func verifyKeyUsesTheAuthEndpoint() async {
        let (enhancer, baseURL) = makeEnhancer { request in
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer good"
            #expect(request.url?.path().hasSuffix("/auth/key") == true)
            return authorized ? .json(#"{"data":{"label":"ok"}}"#) : .json(#"{"error":{"code":401}}"#, status: 401)
        }
        defer { StubURLProtocol.unregister(baseURL) }

        if case .failure(let error) = await enhancer.verifyKey("good") {
            Issue.record("Expected success, got \(error)")
        }
        guard case .failure(let error) = await enhancer.verifyKey("bad") else {
            Issue.record("Expected failure for the bad key")
            return
        }
        #expect(error as? OpenRouterError == .unauthorized)
        guard case .failure(let missing) = await enhancer.verifyKey("  ") else {
            Issue.record("Expected failure for a blank key")
            return
        }
        #expect(missing as? OpenRouterError == .missingKey)
    }

    @Test func prewarmHitsTheKeyEndpointOnceAndSkipsWithoutKey() async throws {
        let counter = Counter()
        let (enhancer, baseURL) = makeEnhancer { request in
            #expect(request.url?.path().hasSuffix("/auth/key") == true)
            counter.increment()
            return .json("{}")
        }
        defer { StubURLProtocol.unregister(baseURL) }
        await enhancer.prewarm()
        await enhancer.prewarm()
        try await waitUntil { counter.value >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.value == 1)

        let noKeyCounter = Counter()
        let (noKey, url2) = makeEnhancer({ _ in
            noKeyCounter.increment()
            return .json("{}")
        }, key: nil)
        defer { StubURLProtocol.unregister(url2) }
        await noKey.prewarm()
        try await Task.sleep(for: .milliseconds(100))
        #expect(noKeyCounter.value == 0)
    }
}
