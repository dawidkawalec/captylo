import Foundation
import Testing
@testable import Captylo

struct TranscriptionRouterTests {
    private static let loud: [Float] = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    private static let silent: [Float] = [Float](repeating: 0.0005, count: 16_000)

    private func cloud(key: String?, status: Int = 200, body: String = #"{"text":"z chmury"}"#) -> ElevenLabsSTT {
        if let key {
            TranscriptionStubURLProtocol.register(key: key, TranscriptionStubURLProtocol.json(status, body))
        }
        return ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            credentialProvider: { TranscriptionFixtures.ownKey(key) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )
    }

    /// The Pro relay answering with `status` and `body` for a fresh session token.
    private func relay(status: Int, body: String) -> ElevenLabsSTT {
        let token = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: token, TranscriptionStubURLProtocol.json(status, body))
        return ElevenLabsSTT(
            session: TranscriptionStubURLProtocol.makeSession(),
            credentialProvider: { TranscriptionFixtures.relay(token) },
            retrySession: { TranscriptionStubURLProtocol.makeSession() }
        )
    }

    @Test func proRelaySuccessIsTheCloudModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(local: local, localInstalled: { true }, elevenLabs: relay(status: 200, body: #"{"text":"z Pro"}"#))
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud, duration: 3)

        let result = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])

        #expect(result.text == "z Pro")
        #expect(result.modelName == "scribe_v2")
        #expect(!result.usedFallback)
        #expect(result.fallbackError == nil)
        #expect(local.transcribeCalls == 0)
    }

    @Test func quotaExceededFallsBackToTheLocalEngineAndSaysWhy() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            elevenLabs: relay(status: 402, body: #"{"error":"quota_exceeded","resetsAt":"2026-11-01T00:00:00.000Z"}"#)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
        #expect(result.modelName == "whisper-large-v3-turbo", "the history row keeps the local model name")
        #expect(result.usedFallback)
        #expect(result.fallbackError == .quotaExceeded)
        #expect(result.fallbackNotice == STTError.quotaExceeded.errorDescription)
        #expect(local.transcribeCalls == 1)
    }

    // MARK: The local model is still being prepared (first load, Neural Engine compile)

    @Test func localEngineUsesTheCloudWhileTheModelIsPreparing() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            elevenLabs: relay(status: 200, body: #"{"text":"z Pro"}"#)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud, duration: 3)

        let result = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])

        #expect(result.text == "z Pro")
        #expect(result.modelName == "scribe_v2")
        #expect(result.cloudWhileLocalPrepares)
        #expect(result.fallbackNotice == "Model lokalny jeszcze się przygotowuje, tym razem użyto chmury.")
        #expect(local.transcribeCalls == 0)
    }

    @Test func localEngineWithoutCloudStopsWaitingForAPreparingModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie", delay: .seconds(5))
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            elevenLabs: cloud(key: nil),
            modelWait: .milliseconds(50)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: DictationError.modelPreparing) {
            _ = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])
        }
        #expect(start.duration(to: clock.now) < .seconds(2), "the take must not hang until the model is ready")
    }

    @Test func aModelThatGetsReadyWithinTheWaitStillTranscribes() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie", delay: .milliseconds(20))
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            elevenLabs: cloud(key: nil),
            modelWait: .seconds(5)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
        #expect(!result.cloudWhileLocalPrepares)
        #expect(result.fallbackNotice == nil)
    }

    @Test func cloudFailureDoesNotHangOnAPreparingModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie", delay: .seconds(5))
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            elevenLabs: relay(status: 500, body: #"{"error":"upstream"}"#),
            modelWait: .milliseconds(50)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: DictationError.modelPreparing) {
            _ = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])
        }
    }

    @Test func modelPreparingSaysWhatToDo() {
        #expect(DictationError.modelPreparing.errorDescription == "Model lokalny jeszcze się przygotowuje (jednorazowo, do kilku minut). Spróbuj ponownie za chwilę.")
    }

    @Test func fallbackNoticeSaysWhyTheCloudWasNotUsed() {
        func notice(_ error: STTError?) -> String? {
            TranscriptionResult(text: "x", modelName: "m", ms: 1, usedFallback: error != nil, fallbackError: error).fallbackNotice
        }
        #expect(notice(nil) == nil)
        #expect(notice(.quotaExceeded) == "Limit chmury w tym miesiącu jest wyczerpany. Captylo użyje modelu lokalnego.")
        #expect(notice(.missingKey) == "Chmura nie jest dostępna bez klucza albo Pro, użyto modelu lokalnego.")
        #expect(notice(.timeout) == "Chmura nie odpowiedziała, użyto modelu lokalnego.")
    }

    @Test func localPathUsesTheLocalEngine() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "  lokalnie  ")
        let router = TranscriptionRouter(local: local, localInstalled: { true }, elevenLabs: cloud(key: nil))
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
        #expect(result.modelName == "whisper-large-v3-turbo")
        #expect(result.usedFallback == false)
        #expect(result.ms >= 0)
        #expect(local.transcribeCalls == 1)
    }

    @Test func localPathRequiresTheModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "x")
        let router = TranscriptionRouter(local: local, localInstalled: { false }, elevenLabs: cloud(key: nil))
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: DictationError.modelNotReady) {
            try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])
        }
        #expect(local.transcribeCalls == 0)
    }

    @Test func cloudSuccessSkipsTheLocalEngine() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(local: local, localInstalled: { true }, elevenLabs: cloud(key: TranscriptionFixtures.uniqueKey()))
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud, duration: 3)

        let result = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: ["Captylo"])

        #expect(result.text == "z chmury")
        #expect(result.modelName == "scribe_v2")
        #expect(result.usedFallback == false)
        #expect(local.transcribeCalls == 0)
    }

    @Test func cloudFailureFallsBackToTheLocalEngineWhenInstalled() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            elevenLabs: cloud(key: TranscriptionFixtures.uniqueKey(), status: 500, body: "down")
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
        #expect(result.modelName == "whisper-large-v3-turbo")
        #expect(result.usedFallback == true)
        #expect(local.transcribeCalls == 1)
    }

    @Test func keychainTimeoutFallsBackToTheLocalEngine() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            elevenLabs: ElevenLabsSTT(session: TranscriptionStubURLProtocol.makeSession(), credentialProvider: { .timedOut })
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
        #expect(result.usedFallback == true)
    }

    @Test func cloudFailureWithoutTheModelSurfacesTheSTTError() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { false },
            elevenLabs: cloud(key: TranscriptionFixtures.uniqueKey(), status: 401, body: "{}")
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: DictationError.stt(.unauthorized)) {
            try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])
        }
        #expect(local.transcribeCalls == 0)
    }

    @Test func cancelledCloudTakeDoesNotFallBack() async throws {
        let key = TranscriptionFixtures.uniqueKey()
        TranscriptionStubURLProtocol.register(key: key) { _ in throw URLError(.cancelled) }
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie")
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            elevenLabs: ElevenLabsSTT(
                session: TranscriptionStubURLProtocol.makeSession(),
                credentialProvider: { TranscriptionFixtures.ownKey(key) },
                retrySession: { TranscriptionStubURLProtocol.makeSession() }
            )
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: CancellationError.self) {
            try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])
        }
        #expect(local.transcribeCalls == 0, "a cancelled take must not run the local fallback")
    }

    @Test func missingKeyWithoutTheModelSurfacesMissingKey() async throws {
        let router = TranscriptionRouter(
            local: TranscriptionFakeLocalTranscriber(text: "lokalnie"),
            localInstalled: { false },
            elevenLabs: cloud(key: nil)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: DictationError.stt(.missingKey)) {
            try await router.transcribe(audio, engine: .elevenLabs, language: "pl", vocabulary: [])
        }
    }

    @Test func silenceHallucinationIsDropped() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "Dziękuję za uwagę.")
        let router = TranscriptionRouter(local: local, localInstalled: { true }, elevenLabs: cloud(key: nil))

        let silent = try await router.transcribe(
            try TranscriptionFixtures.capturedAudio(samples: Self.silent), engine: .local, language: "pl", vocabulary: [])
        #expect(silent.text == "")

        let loud = try await router.transcribe(
            try TranscriptionFixtures.capturedAudio(samples: Self.loud), engine: .local, language: "pl", vocabulary: [])
        #expect(loud.text == "Dziękuję za uwagę.")
    }

    @Test func hallucinationFilterIsCaseInsensitiveAndKeepsRealText() {
        #expect(TranscriptionRouter.filterHallucination("napisy stworzone przez społeczność amara.org", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Subtitles by the Amara.org community", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("  Idę do sklepu.  ", samples: Self.silent) == "Idę do sklepu.")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję za uwagę", samples: Self.loud) == "Dziękuję za uwagę")
        // Whisper's short silence lines go only when they are the whole text of a silent take.
        #expect(TranscriptionRouter.filterHallucination(" Dziękuję. ", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Thank you.", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję, wyślę jutro.", samples: Self.silent) == "Dziękuję, wyślę jutro.")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję.", samples: Self.loud) == "Dziękuję.")
        #expect(TranscriptionRouter.filterHallucination("", samples: []) == "")
        #expect(TranscriptionRouter.rms(Self.silent) < TranscriptionRouter.silenceRMS)
        #expect(TranscriptionRouter.rms(Self.loud) > TranscriptionRouter.silenceRMS)
    }
}
