import Accelerate
import Foundation
import os

/// Routes a finished recording to the local engine or ElevenLabs. A cloud failure falls back to the local engine
/// when the model is installed (`usedFallback`), otherwise surfaces as `DictationError.stt`.
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

    private let local: any LocalTranscribing
    private let localInstalled: @Sendable () -> Bool
    private let elevenLabs: ElevenLabsSTT

    /// - Parameters:
    ///   - local: the Whisper engine (or a fake in tests).
    ///   - localInstalled: whether the model files are on disk; gates the local path and the fallback.
    ///   - elevenLabs: the cloud client; its key provider decides `missingKey`.
    init(local: any LocalTranscribing, localInstalled: @escaping @Sendable () -> Bool, elevenLabs: ElevenLabsSTT) {
        self.local = local
        self.localInstalled = localInstalled
        self.elevenLabs = elevenLabs
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
        switch engine {
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
            }
        }

        let ms = Int(start.duration(to: clock.now) / .milliseconds(1))
        let filtered = Self.filterHallucination(text, samples: audio.samples)
        Log.transcription.info("Transcribed \(audio.duration, format: .fixed(precision: 1)) s with \(modelName, privacy: .public) in \(ms) ms, fallback: \(usedFallback)")
        return TranscriptionResult(text: filtered, modelName: modelName, ms: ms, usedFallback: usedFallback)
    }

    // MARK: - Paths

    private func transcribeLocally(_ audio: CapturedAudio, language: String?) async throws -> String {
        guard localInstalled() else { throw DictationError.modelNotReady }
        return try await local.transcribe(audio.samples, language: language)
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
