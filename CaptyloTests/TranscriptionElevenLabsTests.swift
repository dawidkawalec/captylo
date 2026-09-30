import Foundation
import Testing
import os
@testable import Captylo

struct TranscriptionElevenLabsTests {
    private func request(
        language: String? = "pl",
        vocabulary: [String] = [],
        audioSeconds: Double = 12
    ) -> STTRequest {
        STTRequest(
            wav: Data([1, 2, 3, 4]),
            fileName: "abc.wav",
            model: "scribe_v2",
            language: language,
            vocabulary: vocabulary,
            audioSeconds: audioSeconds
        )
    }

    private func field(_ name: String, _ value: String) -> String {
        "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    // MARK: - Request building

    @Test func makeRequestSetsMethodHeadersAndTimeout() {
        let urlRequest = ElevenLabsSTT.makeRequest(request(), key: "secret")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.url == URL(string: "https://api.elevenlabs.io/v1/speech-to-text"))
        #expect(urlRequest.value(forHTTPHeaderField: "xi-api-key") == "secret")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Boundary-") == true)
        #expect(urlRequest.timeoutInterval == 20)
        #expect(ElevenLabsSTT.timeout(forAudioSeconds: 60) == 40)
    }

    @Test func multipartContainsEveryField() throws {
        let urlRequest = ElevenLabsSTT.makeRequest(request(vocabulary: ["Captylo", "Kawalec"]), key: "k")
        let contentType = try #require(urlRequest.value(forHTTPHeaderField: "Content-Type"))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: try #require(urlRequest.httpBody), as: UTF8.self)

        #expect(body.contains(field("model_id", "scribe_v2")))
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"abc.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(body.contains(field("language_code", "pl")))
        #expect(body.contains(field("tag_audio_events", "false")))
        #expect(body.contains(field("temperature", "0.0")))
        #expect(body.contains(field("no_verbatim", "true")))
        #expect(body.contains(field("timestamps_granularity", "none")))
        #expect(body.contains(field("keyterms", "Captylo")))
        #expect(body.contains(field("keyterms", "Kawalec")))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
        #expect(body.components(separatedBy: "--\(boundary)--").count == 2)
        // CRLF everywhere: no bare LF.
        #expect(body.components(separatedBy: "\n").count == body.components(separatedBy: "\r\n").count)
    }

    @Test func languageCodeIsOmittedForAutoAndNil() throws {
        for language in [nil, "auto"] {
            let urlRequest = ElevenLabsSTT.makeRequest(request(language: language), key: "k")
            let body = String(decoding: try #require(urlRequest.httpBody), as: UTF8.self)
            #expect(!body.contains("language_code"))
        }
    }

    @Test func keytermsAreFilteredDedupedAndCapped() {
        let noisy = [
            " Captylo ", "captylo", "a<b", "x{y}", "[z]", "back\\slash",
            String(repeating: "x", count: 51), String(repeating: "y", count: 50),
            "one two three four five", "one two three four five six", "",
        ]
        #expect(ElevenLabsSTT.keyterms(from: noisy) == ["Captylo", String(repeating: "y", count: 50), "one two three four five"])

        let many = (0..<1200).map { "term\($0)" }
        #expect(ElevenLabsSTT.keyterms(from: many).count == 1000)
    }

    // MARK: - Parsing and status mapping

    @Test func parsesTextAndRejectsEmpty() throws {
        #expect(try ElevenLabsSTT.parseText(Data(#"{"text":"  Cześć świecie \n","language_code":"pl"}"#.utf8)) == "Cześć świecie")
        #expect(throws: STTError.empty) { try ElevenLabsSTT.parseText(Data(#"{"text":"   "}"#.utf8)) }
        #expect(throws: STTError.empty) { try ElevenLabsSTT.parseText(Data(#"{}"#.utf8)) }
    }

    @Test func mapsStatusCodes() {
        #expect(ElevenLabsSTT.mapStatus(200, body: Data()) == nil)
        #expect(ElevenLabsSTT.mapStatus(401, body: Data()) == .unauthorized)
        #expect(ElevenLabsSTT.mapStatus(403, body: Data()) == .unauthorized)
        #expect(ElevenLabsSTT.mapStatus(413, body: Data()) == .tooLarge)
        #expect(ElevenLabsSTT.mapStatus(429, body: Data()) == .rateLimited)
        #expect(ElevenLabsSTT.mapStatus(503, body: Data("upstream down".utf8)) == .server(503, "upstream down"))
        #expect(ElevenLabsSTT.mapTransportError(URLError(.timedOut)) == .timeout)
        if case .network = ElevenLabsSTT.mapTransportError(URLError(.notConnectedToInternet)) {} else {
            Issue.record("expected network")
        }
    }

    @Test func transcribesThroughTheStub() async throws {
        let key = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: key, TranscriptionStubURLProtocol.json(200, #"{"text":"Dzień dobry"}"#))
        let client = ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), keyProvider: { .value(key) })

        #expect(try await client.transcribe(request()) == "Dzień dobry")
    }

    @Test func mapsHTTPFailuresThroughTheStub() async throws {
        let cases: [(Int, String, STTError)] = [
            (401, "{}", .unauthorized),
            (413, "{}", .tooLarge),
            (429, "{}", .rateLimited),
            (500, "boom", .server(500, "boom")),
            (200, #"{"text":""}"#, .empty),
        ]
        for (status, body, expected) in cases {
            let key = TranscriptionFixtures.uniqueKey()
            TranscriptionStubURLProtocol.register(key: key, TranscriptionStubURLProtocol.json(status, body))
            let client = ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), keyProvider: { .value(key) })
            await #expect(throws: expected) { try await client.transcribe(request()) }
        }
    }

    @Test func missingKeyFailsBeforeTheNetwork() async {
        let client = ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), keyProvider: { .value("  ") })
        await #expect(throws: STTError.missingKey) { try await client.transcribe(request()) }
    }

    @Test func keychainTimeoutFailsBeforeTheNetwork() async {
        let client = ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), keyProvider: { .timedOut })
        await #expect(throws: STTError.keychainTimeout) { try await client.transcribe(request()) }
    }

    @Test func totalDeadlineCutsASlowUpload() async {
        let key = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: key) { _ in
            Thread.sleep(forTimeInterval: 0.6)
            return (200, Data(#"{"text":"za późno"}"#.utf8))
        }
        let client = ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            keyProvider: { .value(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() },
            deadline: { _ in 0.1 }
        )
        let clock = ContinuousClock()
        let start = clock.now
        // Both attempts (first and the retry) lose the race long before the stub answers.
        await #expect(throws: STTError.timeout) { try await client.transcribe(request()) }
        #expect(clock.now - start < .seconds(1))
    }

    @Test func retriesOnceOnTimeoutWithAFreshSession() async throws {
        let key = TranscriptionFixtures.uniqueKey()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        TranscriptionStubURLProtocol.register(key: key) { _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw URLError(.timedOut) }
            return (200, Data(#"{"text":"drugi raz"}"#.utf8))
        }
        let client = ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            keyProvider: { .value(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )

        #expect(try await client.transcribe(request()) == "drugi raz")
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func timeoutTwiceSurfacesAsTimeout() async {
        let key = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: key) { _ in throw URLError(.timedOut) }
        let client = ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            keyProvider: { .value(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )
        await #expect(throws: STTError.timeout) { try await client.transcribe(request()) }
    }

    @Test func cancelledUploadIsACancellationAndIsNotRetried() async {
        let key = TranscriptionFixtures.uniqueKey()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        TranscriptionStubURLProtocol.register(key: key) { _ in
            attempts.withLock { $0 += 1 }
            throw URLError(.cancelled)
        }
        let client = ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            keyProvider: { .value(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )
        await #expect(throws: CancellationError.self) { try await client.transcribe(request()) }
        #expect(attempts.withLock { $0 } == 1)
        #expect(ElevenLabsSTT.isCancellation(URLError(.cancelled)))
        #expect(!ElevenLabsSTT.isCancellation(URLError(.timedOut)))
    }

    @Test func httpFailuresAreNotRetried() async {
        let key = TranscriptionFixtures.uniqueKey()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        TranscriptionStubURLProtocol.register(key: key) { _ in
            attempts.withLock { $0 += 1 }
            return (500, Data())
        }
        let client = ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            keyProvider: { .value(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )
        await #expect(throws: STTError.server(500, "")) { try await client.transcribe(request()) }
        #expect(attempts.withLock { $0 } == 1)
    }

    // MARK: - Verify

    @Test func verifyBuildsAGetOnUser() {
        let urlRequest = ElevenLabsSTT.makeVerifyRequest(key: "k")
        #expect(urlRequest.httpMethod == "GET")
        #expect(urlRequest.url == URL(string: "https://api.elevenlabs.io/v1/user"))
        #expect(urlRequest.value(forHTTPHeaderField: "xi-api-key") == "k")
        #expect(urlRequest.timeoutInterval == 10)
    }

    @Test func verifyMapsUnauthorized() async throws {
        let good = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: good, TranscriptionStubURLProtocol.json(200, #"{"subscription":{}}"#))
        let bad = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: bad, TranscriptionStubURLProtocol.json(401, #"{"detail":"invalid"}"#))
        let client = ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), keyProvider: { .value(nil) })

        try await client.verify(key: good)
        await #expect(throws: STTError.unauthorized) { try await client.verify(key: bad) }
        await #expect(throws: STTError.missingKey) { try await client.verify(key: "") }
    }
}
