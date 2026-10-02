import FluidAudio
import Foundation
import os

/// `--compare-models`: Parakeet v3 against Parakeet Ultra on one audio file, for the owner's
/// Polish accuracy and speed check. Each model gets its own `AsrManager`, loaded one after the
/// other (both at once would need ~1.2 GB) and released before the next one; the app's
/// `ParakeetEngine` is never touched. v3 is read from the app's model directory
/// (`AppPaths.parakeetModelDir`); Ultra (~600 MB) is downloaded into its own FluidAudio cache
/// folder the first time, and only by this tool.
enum ModelComparison {
    /// The versions compared, in run order.
    static let versions: [AsrModelVersion] = [.v3, .ultra]

    struct ModelReport: Sendable {
        /// "parakeet-v3" / "parakeet-ultra".
        let model: String
        let text: String
        /// Model load (download excluded when the files were already on disk).
        let loadMs: Int
        /// Transcription of the whole file.
        let ms: Int
        /// Transcription time over audio duration (0.1 = ten times faster than real time).
        let rtf: Double
        /// Highest process footprint seen while this model loaded and ran, in MB.
        let peakMemoryMB: Int
        /// `peakMemoryMB` minus the footprint before the model loaded.
        let memoryDeltaMB: Int
        /// Against the reference text, when one was given.
        let wer: WordErrorRate?
    }

    struct Report: Sendable {
        let file: URL
        let durationSeconds: Double
        /// Engine language code used for both models (nil = auto).
        let language: String?
        let hasReference: Bool
        let models: [ModelReport]
        /// Process peak after the whole run, in MB.
        let peakMemoryMB: Int
    }

    enum Failure: LocalizedError {
        case unknownLanguage(String)

        var errorDescription: String? {
            switch self {
            case .unknownLanguage(let code):
                return "Unknown language code: \(code)"
            }
        }
    }

    /// `AsrModels.loadLocal` blocks for seconds on the first load of a binary; it runs here,
    /// never on the cooperative pool (same rule as `ParakeetEngine`).
    private static let loadQueue = DispatchQueue(label: "com.captylo.app.compare.load", qos: .userInitiated)

    /// Decodes the file once and runs every version on the same 16 kHz mono samples.
    static func run(file: URL, reference: String?, language: String?) async throws -> Report {
        let hint = try languageHint(language)
        let (samples, duration) = try await AudioDecoder.decode16kMono(file)
        var reports: [ModelReport] = []
        for version in versions {
            reports.append(try await run(version, samples: samples, duration: duration, reference: reference, language: hint))
        }
        return Report(
            file: file,
            durationSeconds: duration,
            language: language,
            hasReference: reference != nil,
            models: reports,
            peakMemoryMB: PeakMemory.peakMB()
        )
    }

    static func name(of version: AsrModelVersion) -> String {
        switch version {
        case .v3: return "parakeet-v3"
        case .ultra: return "parakeet-ultra"
        default: return "parakeet-\(String(describing: version))"
        }
    }

    /// Where a version's files live: the app's directory for v3, FluidAudio's cache for the rest.
    static func directory(for version: AsrModelVersion) -> URL {
        version == .v3 ? AppPaths.parakeetModelDir : AsrModels.defaultCacheDirectory(for: version)
    }

    private static func run(
        _ version: AsrModelVersion,
        samples: [Float],
        duration: Double,
        reference: String?,
        language: Language?
    ) async throws -> ModelReport {
        let name = name(of: version)
        let before = PeakMemory.currentMB()
        let sampler = MemorySampler()
        defer { sampler.stop() }
        let clock = ContinuousClock()

        let loadStart = clock.now
        let modelDirectory = try await AsrModels.download(to: directory(for: version), version: version)
        let models = try await loadModelsOnQueue(from: modelDirectory, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let loadMs = Int(loadStart.duration(to: clock.now) / .milliseconds(1))
        Log.transcription.info("Comparison: \(name, privacy: .public) loaded in \(loadMs) ms")

        // Same padding as the app's passes (1 s of silence improves the final punctuation).
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: ParakeetEngine.paddingSamples))
        let runStart = clock.now
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &decoderState, language: language)
        let ms = Int(runStart.duration(to: clock.now) / .milliseconds(1))
        await manager.cleanup()

        let peak = max(sampler.stop(), PeakMemory.currentMB())
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.transcription.info("Comparison: \(name, privacy: .public) transcribed \(duration, format: .fixed(precision: 1)) s in \(ms) ms, peak \(peak) MB")
        return ModelReport(
            model: name,
            text: text,
            loadMs: loadMs,
            ms: ms,
            rtf: duration > 0 ? (Double(ms) / 1000 / duration * 1000).rounded() / 1000 : 0,
            peakMemoryMB: peak,
            memoryDeltaMB: max(peak - before, 0),
            wer: reference.map { WordErrorRate.compute(reference: $0, hypothesis: text) }
        )
    }

    private static func loadModelsOnQueue(from directory: URL, version: AsrModelVersion) async throws -> AsrModels {
        try await withCheckedThrowingContinuation { continuation in
            loadQueue.async {
                do {
                    continuation.resume(returning: try AsrModels.loadLocal(from: directory, version: version))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// nil (auto) for a missing code; an unknown code fails loudly instead of running as auto.
    private static func languageHint(_ code: String?) throws -> Language? {
        guard let code, code != TranscriptionLanguages.auto else { return nil }
        guard let language = Language(rawValue: code) else { throw Failure.unknownLanguage(code) }
        return language
    }
}

/// Polls the process footprint every 100 ms while a model loads and runs, so a short spike
/// between two reads is not missed. The lifetime peak would hide a smaller second model.
private final class MemorySampler: Sendable {
    private let state: OSAllocatedUnfairLock<(peak: Int, running: Bool)>
    private let task: Task<Void, Never>

    init() {
        let state = OSAllocatedUnfairLock(initialState: (peak: 0, running: true))
        self.state = state
        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let current = PeakMemory.currentMB()
                let running = state.withLock { value in
                    value.peak = max(value.peak, current)
                    return value.running
                }
                if !running { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Stops polling and returns the highest value seen (idempotent).
    @discardableResult
    func stop() -> Int {
        task.cancel()
        return state.withLock { value in
            value.running = false
            return value.peak
        }
    }
}
