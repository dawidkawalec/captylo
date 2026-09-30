import FluidAudio
import Foundation
import os

/// The single Parakeet TDT 0.6b v3 engine for the whole app (gotcha 19): exactly one `AsrManager`,
/// loaded once and reused by every live preview pass and every final pass. `unload()` runs only
/// when the user deletes the model; never between dictations (it clears FluidAudio's global cache).
actor ParakeetEngine: LocalTranscribing {
    enum State: Sendable, Equatable {
        case missing
        case loading
        case ready
        case failed(String)
    }

    static let version: AsrModelVersion = .v3
    /// Zeros appended to every pass: 1 s (gotcha 17, also improves final punctuation).
    static let paddingSamples = ASRConstants.sampleRate
    /// Longest preview tail so the padded input still fits one fixed-size encoder pass (gotcha 20).
    static let maxPreviewSamples = ASRConstants.maxModelSamples - paddingSamples
    /// Below this the model throws `invalidAudioData` (0.3 s), so the pass returns "" instead.
    static let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)

    /// True when every v3 int8 file sits in `AppPaths.parakeetModelDir` (the folder without `-coreml`, gotcha 14).
    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AppPaths.parakeetModelDir, version: version)
    }

    /// `AsrModels.loadLocal` blocks for up to ~30 s on the first run of a binary (gotcha 16);
    /// it runs here, never on the cooperative pool (gotcha 15).
    private static let loadQueue = DispatchQueue(label: "com.captylo.app.parakeet.load", qos: .userInitiated)

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .missing)
    private var manager: AsrManager?
    private var loadTask: Task<Void, any Error>?

    init() {}

    /// Readable from any isolation domain without a hop (the model store polls it from the main actor).
    nonisolated var state: State {
        stateLock.withLock { $0 }
    }

    // MARK: - Loading

    /// Loads the model from disk (deduped: concurrent callers await the same task) and warms it up.
    /// Throws `DictationError.modelNotReady` when the files are not on disk; never downloads.
    func load() async throws {
        if manager != nil, state == .ready { return }
        if let loadTask { return try await loadTask.value }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Releases the models. Only for model deletion (gotcha 19).
    func unload() async {
        if let manager {
            await manager.cleanup()
        }
        manager = nil
        setState(.missing)
        Log.transcription.notice("Parakeet engine unloaded")
    }

    private func performLoad() async throws {
        guard Self.isDownloaded else {
            setState(.missing)
            throw DictationError.modelNotReady
        }
        setState(.loading)
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Log.signposter.beginInterval("parakeet.load", id: Log.signposter.makeSignpostID())
        do {
            let models = try await Self.loadModelsOnQueue()
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            try await warmUp(asr)
            manager = asr
            setState(.ready)
            Log.signposter.endInterval("parakeet.load", interval)
            Log.transcription.info("Parakeet ready in \(Self.milliseconds(since: start, clock: clock)) ms")
        } catch {
            manager = nil
            setState(.failed(error.localizedDescription))
            Log.signposter.endInterval("parakeet.load", interval)
            Log.transcription.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func loadModelsOnQueue() async throws -> AsrModels {
        try await withCheckedThrowingContinuation { continuation in
            loadQueue.async {
                do {
                    let models = try AsrModels.loadLocal(from: AppPaths.parakeetModelDir, version: version)
                    continuation.resume(returning: models)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One pass over 1 s of silence so the first dictation does not pay the Core ML warm-up.
    private func warmUp(_ asr: AsrManager) async throws {
        let silence = [Float](repeating: 0, count: Self.paddingSamples)
        var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        _ = try await asr.transcribe(silence, decoderState: &decoderState, language: nil)
    }

    // MARK: - LocalTranscribing

    /// Full pass. Waits for an in-flight load; throws `modelNotReady` when the files are missing.
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        if manager == nil {
            try await load()
        }
        guard let manager else { throw DictationError.modelNotReady }
        return try await run(samples, language: language, on: manager, label: "parakeet.transcribe")
    }

    /// Preview pass over the live tail. Returns "" until the model is ready instead of forcing a load.
    func preview(_ tail: [Float], language: String?) async throws -> String {
        guard let manager, state == .ready else { return "" }
        let capped = Array(tail.suffix(Self.maxPreviewSamples))
        return try await run(capped, language: language, on: manager, label: "parakeet.preview")
    }

    private func run(_ samples: [Float], language: String?, on manager: AsrManager, label: StaticString) async throws -> String {
        try await runResult(samples, language: language, on: manager, label: label)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// One padded pass with a fresh decoder state. `nil` when the slice is too short for the model.
    /// Token times in the result are relative to the start of `samples` (the padding sits at the end).
    private func runResult(_ samples: [Float], language: String?, on manager: AsrManager, label: StaticString) async throws -> ASRResult? {
        guard samples.count >= Self.minimumSamples else { return nil }
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: Self.paddingSamples))

        let clock = ContinuousClock()
        let start = clock.now
        let interval = Log.signposter.beginInterval(label, id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval(label, interval) }

        // Fresh decoder state per pass (gotcha 18); the language hint is the v3 script filter (gotcha 21).
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &decoderState, language: Self.languageHint(language))
        Log.transcription.debug("\(label, privacy: .public): \(samples.count) samples in \(Self.milliseconds(since: start, clock: clock)) ms")
        return result
    }

    // MARK: - Helpers

    private nonisolated func setState(_ newState: State) {
        stateLock.withLock { $0 = newState }
    }

    /// `nil` (auto) lets Cyrillic tokens leak into Polish; the caller defaults to "pl" (gotcha 21).
    private static func languageHint(_ code: String?) -> Language? {
        guard let code, code != TranscriptionLanguages.auto else { return nil }
        return Language(rawValue: code)
    }

    private static func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        Int(start.duration(to: clock.now) / .milliseconds(1))
    }
}

// Lives in this file because it reads the actor's private `manager` and `runResult`.
extension ParakeetEngine: MeetingSpeechTranscribing {
    /// Meeting pass over one utterance (at most 14 s, so with the padding it fits one encoder window: no seams).
    /// Word times are relative to the start of `samples`.
    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript {
        if manager == nil {
            try await load()
        }
        guard let manager else { throw DictationError.modelNotReady }
        guard let result = try await runResult(samples, language: language, on: manager, label: "parakeet.meeting") else {
            return TimedTranscript(text: "", words: [])
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(samples.count) / Double(ASRConstants.sampleRate)
        let words = WordTimings.words(from: result.tokenTimings ?? [], offset: 0)
        return TimedTranscript(text: text, words: WordTimings.clamped(words, toDuration: duration))
    }
}
