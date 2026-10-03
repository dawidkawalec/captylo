import Foundation
import os
import Testing
@testable import Captylo

/// Per-kind rules of `Enhancer` (guard, token cap, skip, deadline) and the history notes.
struct EnhancementModeRulesTests {
    private static let raw = "no więc to jest dłuższy testowy transkrypt który ma zdecydowanie więcej niż trzy słowa"

    private func makeEnhancer(
        _ handler: @escaping StubURLProtocol.Handler,
        key: String? = "sk-or-test",
        model: String = "openai/gpt-4.1-mini"
    ) -> (Enhancer, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let client = OpenRouterClient(baseURL: baseURL)
        let route = key.map { AIRoute(client: client, key: $0, model: model) }
        let enhancer = Enhancer(
            client: client,
            route: { _ in .value(route) },
            session: StubURLProtocol.makeSession()
        )
        return (enhancer, baseURL)
    }

    private static func body(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return data
    }

    // MARK: Sanity guard

    @Test func cleanupGuardChecksTheLengthRatio() {
        let long = String(repeating: "słowo ", count: 20)
        #expect(Enhancer.rejectionReason(raw: long, output: "Tak.", finishReason: "stop", kind: .cleanup) == .tooShort)
        #expect(Enhancer.rejectionReason(raw: long, output: long + long + long, finishReason: "stop", kind: .cleanup) == .tooLong)
        #expect(Enhancer.rejectionReason(raw: long, output: "", finishReason: "stop", kind: .cleanup) == .empty)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "length", kind: .cleanup) == .truncated)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "stop", kind: .cleanup) == nil)
    }

    @Test func rewriteGuardOnlyRejectsEmptyOrCutOffAnswers() {
        let long = String(repeating: "słowo ", count: 20)
        #expect(Enhancer.rejectionReason(raw: long, output: "- [ ] Zadzwoń", finishReason: "stop", kind: .rewrite) == nil)
        #expect(Enhancer.rejectionReason(raw: long, output: String(repeating: long, count: 5), finishReason: "stop", kind: .rewrite) == nil)
        #expect(Enhancer.rejectionReason(raw: long, output: "", finishReason: "stop", kind: .rewrite) == .empty)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "length", kind: .rewrite) == .truncated)
    }

    // MARK: Token caps

    @Test func rewriteTokenCap() {
        let model = "openai/gpt-4.1-mini"
        // est = max(16, bytes / 3); rewrite = min(4096, est * 3 + 256)
        #expect(Enhancer.maxTokens(forUTF8Count: 0, model: model, kind: .rewrite) == 16 * 3 + 256)
        #expect(Enhancer.maxTokens(forUTF8Count: 3000, model: model, kind: .rewrite) == 1000 * 3 + 256)
        #expect(Enhancer.maxTokens(forUTF8Count: 3900, model: model, kind: .rewrite) == 4096)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: model, kind: .rewrite) == 4096)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: "openai/gpt-oss-120b", kind: .rewrite) == 4096 + 512)
        // The file cap (8192) lifts the rewrite ceiling too.
        #expect(Enhancer.maxTokens(forUTF8Count: 6000, model: model, kind: .rewrite, cap: 8192) == 2000 * 3 + 256)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, model: model, kind: .rewrite, cap: 8192) == 8192)
        // Cleanup keeps the old rule.
        #expect(Enhancer.maxTokens(forUTF8Count: 3000, model: model, kind: .cleanup) == 2048)
        #expect(Enhancer.maxTokens(forUTF8Count: 300, model: model, kind: .cleanup) == 264)
    }

    // MARK: Skip rule

    @Test func skipRuleAppliesToCleanupOnly() {
        #expect(Enhancer.shouldSkip("raz dwa trzy", kind: .cleanup))
        #expect(!Enhancer.shouldSkip("raz dwa trzy cztery", kind: .cleanup))
        #expect(!Enhancer.shouldSkip("dzień dobry", kind: .rewrite))
        #expect(!Enhancer.shouldSkip("tak", kind: .rewrite))
        #expect(Enhancer.shouldSkip(" \n ", kind: .rewrite))
        #expect(Enhancer.shouldSkip("", kind: .cleanup))
    }

    // MARK: Notes

    @Test func everyOutcomeMapsToAPolishNote() {
        #expect(EnhancementOutcome.enhanced(text: "A", ms: 1, model: "m").note == nil)
        #expect(EnhancementOutcome.enhanced(text: "A", ms: 1, model: "m").errorMessage == nil)
        #expect(EnhancementOutcome.skipped(.noKey).note == String(localized: "Brak klucza AI"))
        #expect(EnhancementOutcome.skipped(.tooShort).note == String(localized: "Za krótkie (3 słowa lub mniej)"))
        #expect(EnhancementOutcome.failed(.deadline(seconds: 3), ms: 3000).note == String(localized: "Przekroczono limit \("3") s"))
        #expect(EnhancementOutcome.failed(.http(status: 401), ms: 1).note == String(localized: "Błąd AI \("401")"))
        #expect(EnhancementOutcome.failed(.http(status: 503), ms: 1).note == String(localized: "Błąd AI \("503")"))
        #expect(EnhancementOutcome.failed(.rejected(.tooShort), ms: 1).note == String(localized: "Odrzucono: wynik podejrzanie krótki"))
        #expect(EnhancementOutcome.failed(.rejected(.tooLong), ms: 1).note == String(localized: "Odrzucono: wynik podejrzanie długi"))
        #expect(EnhancementOutcome.failed(.rejected(.empty), ms: 1).note == String(localized: "Odrzucono: pusta odpowiedź"))
        #expect(EnhancementOutcome.failed(.rejected(.truncated), ms: 1).note == String(localized: "Odrzucono: odpowiedź ucięta"))
        #expect(EnhancementOutcome.failed(.network("offline"), ms: 1).note == String(localized: "Błąd sieci"))
        #expect(EnhancementOutcome.failed(.invalidResponse, ms: 1).note == String(localized: "Nieoczekiwana odpowiedź AI"))
        #expect(EnhancementOutcome.failed(.keychainTimeout, ms: 1).note == String(localized: "Pęk kluczy nie odpowiedział na czas"))

        // Fractional limits keep one decimal in the UI locale ("2,5" in Polish, "2.5" in English).
        let note = EnhancementFailure.deadline(seconds: 2.5).note
        #expect(note.contains("2,5") || note.contains("2.5"))

        // Full messages for toasts and the reprocess banner.
        #expect(EnhancementOutcome.skipped(.noKey).errorMessage == OpenRouterError.missingKey.errorDescription)
        #expect(EnhancementFailure.http(status: 429).errorDescription == OpenRouterError.rateLimited.errorDescription)
        #expect(EnhancementFailure.http(status: 403).errorDescription == OpenRouterError.unauthorized.errorDescription)
    }

    @Test func applyEnhancementFillsModeAndNote() {
        var record = DictationRecord(text: "raz dwa trzy cztery", wordCount: 4)
        record.applyEnhancement(.failed(.http(status: 401), ms: 120), mode: "E-mail")
        #expect(record.enhancementMode == "E-mail")
        #expect(record.enhancementNote == EnhancementFailure.http(status: 401).note)
        #expect(record.enhancementMs == 120)
        #expect(record.enhancedText == nil)
        #expect(record.enhancementModel == nil)

        record.applyEnhancement(.enhanced(text: "Raz, dwa.", ms: 640, model: "openai/gpt-4.1-mini"), mode: "Czyszczenie")
        #expect(record.enhancedText == "Raz, dwa.")
        #expect(record.enhancementMode == "Czyszczenie")
        #expect(record.enhancementModel == "openai/gpt-4.1-mini")
        #expect(record.enhancementMs == 640)
        #expect(record.enhancementNote == nil)
        #expect(record.text == "raz dwa trzy cztery")
        #expect(record.wordCount == 4)

        record.applyEnhancement(.skipped(.noKey), mode: "Czyszczenie")
        #expect(record.enhancedText == nil)
        #expect(record.enhancementMs == nil)
        #expect(record.enhancementNote == EnhancementSkip.noKey.note)
    }

    @Test func thrownErrorsMapToFailures() {
        #expect(Enhancer.failure(for: EnhancerError.deadline, deadline: .seconds(6)) == .deadline(seconds: 6))
        #expect(Enhancer.failure(for: OpenRouterError.unauthorized, deadline: .seconds(3)) == .http(status: 401))
        #expect(Enhancer.failure(for: OpenRouterError.rateLimited, deadline: .seconds(3)) == .http(status: 429))
        #expect(Enhancer.failure(for: OpenRouterError.server(502), deadline: .seconds(3)) == .http(status: 502))
        #expect(Enhancer.failure(for: OpenRouterError.decoding, deadline: .seconds(3)) == .invalidResponse)
        if case .network = Enhancer.failure(for: URLError(.notConnectedToInternet), deadline: .seconds(3)) {} else {
            Issue.record("URLError should map to .network")
        }
    }

    // MARK: Enhancer with a mode

    @Test func rewriteModeSendsItsPromptAndCapAndKeepsALongAnswer() async throws {
        let email = "Dzień dobry,\n\n" + String(repeating: "uprzejmie przypominam o jutrzejszym spotkaniu w sprawie oferty. ", count: 6) + "\n\nPozdrawiam"
        let seen = OSAllocatedUnfairLock<Data>(initialState: Data())
        let (enhancer, baseURL) = makeEnhancer { request in
            let body = Self.body(of: request)
            seen.withLock { $0 = body }
            let escaped = email.replacingOccurrences(of: "\n", with: "\\n")
            return .json(Fixtures.chat(content: "\"\(escaped)\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let raw = "przypomnij marcie o jutrzejszym spotkaniu w sprawie oferty"
        let outcome = await enhancer.enhance(raw, mode: BuiltInAIModes.email, vocabulary: ["Marta"])
        #expect(outcome.text == email, "a rewrite may be far longer than the dictation")

        let data = seen.withLock { $0 }
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] as? Int == Enhancer.maxTokens(forUTF8Count: raw.utf8.count, model: "openai/gpt-4.1-mini", kind: .rewrite))
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.first?["content"] as? String == BuiltInAIModes.email.systemPrompt(vocabulary: ["Marta"]))
        #expect(messages.last?["content"] as? String == raw)

        // The same answer is rejected in the strict cleanup mode.
        let cleanup = await enhancer.enhance(raw + " i jeszcze trochę słów", mode: BuiltInAIModes.cleanup, vocabulary: [])
        #expect(cleanup == .failed(.rejected(.tooLong), ms: cleanup.ms ?? 0))
    }

    @Test func rewriteModeTranslatesEvenAShortPhrase() async {
        let (enhancer, baseURL) = makeEnhancer { _ in .json(Fixtures.chat(content: "\"Good morning\"", finish: "stop")) }
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance("dzień dobry", mode: BuiltInAIModes.english, vocabulary: []).text == "Good morning")
        #expect(await enhancer.enhance("dzień dobry", mode: BuiltInAIModes.cleanup, vocabulary: []) == .skipped(.tooShort))
    }

    @Test func modeDeadlineIsHonored() async {
        let (enhancer, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: "\"late\"", finish: "stop"), delay: .seconds(3))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        var mode = BuiltInAIModes.english
        mode.deadlineSeconds = 1
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await enhancer.enhance(Self.raw, mode: mode, vocabulary: [])
        let elapsed = clock.now - start
        guard case .failed(let failure, _) = outcome else {
            Issue.record("Expected the 1 s mode deadline to win, got \(outcome)")
            return
        }
        #expect(failure == .deadline(seconds: 1))
        #expect(elapsed < .seconds(1.5), "deadline overshoot: \(elapsed)")
        #expect(outcome.note == String(localized: "Przekroczono limit \("1") s"))
    }

    // MARK: ModeTester

    @MainActor
    @Test func modeTesterReturnsTextOrAPolishError() async throws {
        let slow = ModeTesterFakeEnhancer(outcome: .enhanced(text: "- [ ] Zadzwoń do księgowej", ms: 4200, model: "m"))
        let tester = ModeTester(enhancer: slow, vocabulary: { ["PRD"] })
        let text = try await tester.run(BuiltInAIModes.tasks, sample: ModeTester.defaultSample).get()
        #expect(text == "- [ ] Zadzwoń do księgowej")
        let detailed = try await tester.runDetailed(BuiltInAIModes.cleanup, sample: "a b c d e").get()
        #expect(detailed.exceedsModeDeadline, "4.2 s is above the 3 s cleanup limit")
        #expect(try await tester.runDetailed(BuiltInAIModes.organize, sample: "x").get().exceedsModeDeadline == false)
        // The test runs with the enhancer's own (long) deadline and the mode's prompt and kind.
        let job = try #require(slow.lastJob)
        #expect(job.deadline == nil)
        #expect(job.kind == .rewrite)
        #expect(job.systemPrompt.contains("PRD"))

        let noKey = ModeTester(enhancer: ModeTesterFakeEnhancer(outcome: .skipped(.noKey)), vocabulary: { [] })
        guard case .failure(let error) = await noKey.run(BuiltInAIModes.english, sample: "cześć") else {
            Issue.record("Expected a failure without a key")
            return
        }
        #expect((error as? LocalizedError)?.errorDescription == OpenRouterError.missingKey.errorDescription)

        let failing = ModeTester(enhancer: ModeTesterFakeEnhancer(outcome: .failed(.http(status: 401), ms: 90)), vocabulary: { [] })
        guard case .failure(let failure) = await failing.run(BuiltInAIModes.english, sample: "cześć") else {
            Issue.record("Expected a failure on 401")
            return
        }
        #expect(failure as? EnhancementFailure == .http(status: 401))
    }
}

/// Fixed outcome, remembers the last job.
final class ModeTesterFakeEnhancer: TextEnhancing, Sendable {
    private let outcome: EnhancementOutcome
    private let jobs = OSAllocatedUnfairLock<[EnhancementJob]>(initialState: [])

    init(outcome: EnhancementOutcome) {
        self.outcome = outcome
    }

    var lastJob: EnhancementJob? { jobs.withLock { $0.last } }
    var calls: Int { jobs.withLock { $0.count } }

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        jobs.withLock { $0.append(job) }
        return outcome
    }

    func prewarm() async {}
}
