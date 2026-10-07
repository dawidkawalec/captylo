import Accelerate
import Foundation
import os

/// Routes a finished recording to the local engine or the cloud (own key or the Pro relay, decided
/// by the STT client's credential). A cloud failure, including no route at all and the Pro monthly
/// limit, falls back to the local engine when the model is installed (`usedFallback` with the
/// reason in `fallbackError`), otherwise surfaces as `DictationError.stt`.
struct TranscriptionRouter: TranscriptionRouting {
    /// Below this RMS the recording counts as silence for the hallucination filter (gotcha 87).
    static let silenceRMS: Float = 0.003
    /// Phrases cloud models invent on near-silent Polish audio; matched case-insensitively.
    static let hallucinations: [String] = [
        "Napisy stworzone przez społeczność Amara.org",
        "Dziękuję za uwagę",
        "Dziękuję za oglądanie",
        "Subtitles by",
    ]
    /// Short lines Whisper says on silence; dropped only when they are the whole text.
    static let silenceOnlyLines: Set<String> = [
        "dziękuję", "dziękuję bardzo", "dzięki", "thank you", "thanks for watching",
    ]

    /// How long a take waits for a model that is still being prepared (the first load compiles it
    /// for the Neural Engine, minutes) before it fails with `modelPreparing` instead of hanging.
    static let defaultModelWait: Duration = .seconds(90)

    private let local: any LocalTranscribing
    private let localInstalled: @Sendable () -> Bool
    private let localReady: @Sendable () -> Bool
    private let elevenLabs: ElevenLabsSTT
    private let modelWait: Duration

    /// - Parameters:
    ///   - local: the Whisper engine (or a fake in tests).
    ///   - localInstalled: whether the model files are on disk; gates the local path and the fallback.
    ///   - localReady: whether the model is loaded; while it is not, the local engine tries the
    ///     cloud first and a local pass waits at most `modelWait`.
    ///   - elevenLabs: the cloud client; its key provider decides `missingKey`.
    init(
        local: any LocalTranscribing,
        localInstalled: @escaping @Sendable () -> Bool,
        localReady: @escaping @Sendable () -> Bool = { true },
        elevenLabs: ElevenLabsSTT,
        modelWait: Duration = TranscriptionRouter.defaultModelWait
    ) {
        self.local = local
        self.localInstalled = localInstalled
        self.localReady = localReady
        self.elevenLabs = elevenLabs
        self.modelWait = modelWait
    }

    func transcribe(
        _ audio: CapturedAudio,
        engine: STTEngine,
        language: String?,
        vocabulary: [String]
    ) async throws -> TranscriptionResult {
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Log.signposter.beginInterval("transcribe", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("transcribe", interval) }

        let text: String
        let modelName: String
        var usedFallback = false
        var fallbackError: STTError?
        var cloudWhileLocalPrepares = false
        switch engine {
        case .local where !localReady() && localInstalled():
            // The model is still being prepared: the cloud (own key or Pro) does this take when it
            // can, otherwise the take waits for the model a bounded time.
            do {
                text = try await transcribeInCloud(audio, language: language, vocabulary: vocabulary)
                modelName = STTEngine.elevenLabs.modelName
                cloudWhileLocalPrepares = true
                Log.transcription.notice("Local model still preparing, the cloud did this take")
            } catch is STTError {
                if Task.isCancelled { throw CancellationError() }
                text = try await transcribeLocally(audio, language: language)
                modelName = STTEngine.local.modelName
            }
        case .local:
            text = try await transcribeLocally(audio, language: language)
            modelName = STTEngine.local.modelName
        case .elevenLabs:
            do {
                text = try await transcribeInCloud(audio, language: language, vocabulary: vocabulary)
                modelName = STTEngine.elevenLabs.modelName
            } catch let error as STTError {
                // A cancelled take never falls back: it would only start a local pass nobody waits for.
                if Task.isCancelled { throw CancellationError() }
                guard localInstalled() else { throw DictationError.stt(error) }
                Log.transcription.error("ElevenLabs failed (\(String(describing: error), privacy: .public)), falling back to the local engine")
                text = try await transcribeLocally(audio, language: language)
                modelName = STTEngine.local.modelName
                usedFallback = true
                fallbackError = error
            }
        }

        let ms = Int(start.duration(to: clock.now) / .milliseconds(1))
        let filtered = Self.filterHallucination(text, samples: audio.samples)
        Log.transcription.info("Transcribed \(audio.duration, format: .fixed(precision: 1)) s with \(modelName, privacy: .public) in \(ms) ms, fallback: \(usedFallback)")
        return TranscriptionResult(
            text: filtered,
            modelName: modelName,
            ms: ms,
            usedFallback: usedFallback,
            fallbackError: fallbackError,
            cloudWhileLocalPrepares: cloudWhileLocalPrepares
        )
    }

    // MARK: - Paths

    /// A local pass. With the model ready it runs as long as it needs; with the model still being
    /// prepared it waits at most `modelWait` and then fails with `modelPreparing` (the load itself
    /// keeps running in the engine, so the next take finds the model ready).
    private func transcribeLocally(_ audio: CapturedAudio, language: String?) async throws -> String {
        guard localInstalled() else { throw DictationError.modelNotReady }
        if localReady() {
            return try await local.transcribe(audio.samples, language: language)
        }
        let local = local
        let samples = audio.samples
        let wait = modelWait
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await local.transcribe(samples, language: language) }
            group.addTask {
                try await Task.sleep(for: wait)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let text = first else {
                Log.transcription.error("Local model still preparing after \(String(describing: wait), privacy: .public), the take gives up")
                throw DictationError.modelPreparing
            }
            return text
        }
    }

    /// `@concurrent`: the callers are main-actor code, and reading a long WAV plus building the
    /// multipart body must not stall the main thread (hotkeys, widget, windows).
    @concurrent
    private func transcribeInCloud(_ audio: CapturedAudio, language: String?, vocabulary: [String]) async throws -> String {
        let wav: Data
        do {
            wav = try Data(contentsOf: audio.fileURL)
        } catch {
            throw STTError.network(error.localizedDescription)
        }
        let request = STTRequest(
            wav: wav,
            fileName: "\(audio.id.uuidString).wav",
            model: STTEngine.elevenLabs.modelName,
            language: language,
            vocabulary: vocabulary,
            audioSeconds: audio.duration
        )
        return try await elevenLabs.transcribe(request)
    }

    // MARK: - Hallucination filter (pure)

    /// Returns "" when the audio is near silence and the text matches the blocklist; otherwise the trimmed text.
    static func filterHallucination(_ text: String, samples: [Float]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rms(samples) < silenceRMS else { return trimmed }
        let lowered = trimmed.lowercased()
        let bare = lowered.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let matches = hallucinations.contains { lowered.contains($0.lowercased()) } || silenceOnlyLines.contains(bare)
        if matches {
            Log.transcription.notice("Dropped a silence hallucination: \(trimmed, privacy: .private)")
        }
        return matches ? "" : trimmed
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
}
