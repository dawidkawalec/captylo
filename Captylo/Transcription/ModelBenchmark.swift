import Foundation
import os

/// `--benchmark`: the local Whisper model on one audio file, for the owner's accuracy and speed
/// checks. Uses the app's engine (the same model and settings as a dictation)
/// over the whole file, and reports load and run time, peak memory and, with a reference
/// transcript, the word error rate.
enum ModelBenchmark {
    struct Report: Sendable {
        let file: URL
        let durationSeconds: Double
        /// Engine language code (nil = auto).
        let language: String?
        let model: String
        let text: String
        /// Model load, including the Neural Engine compile on the first load of a model.
        let loadMs: Int
        /// Transcription of the whole file.
        let ms: Int
        /// Transcription time over audio duration (0.1 = ten times faster than real time).
        let rtf: Double
        /// Highest process footprint seen while the model loaded and ran, in MB.
        let peakMemoryMB: Int
        /// `peakMemoryMB` minus the footprint before the model loaded.
        let memoryDeltaMB: Int
        /// Against the reference text, when one was given.
        let wer: WordErrorRate?
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

    static func run(file: URL, reference: String?, language: String?, engine: WhisperEngine) async throws -> Report {
        if let language, !TranscriptionLanguages.codes.contains(language) {
            throw Failure.unknownLanguage(language)
        }
        let (samples, duration) = try await AudioDecoder.decode16kMono(file)
        let before = PeakMemory.currentMB()
        let sampler = MemorySampler()
        defer { sampler.stop() }
        let clock = ContinuousClock()

        let loadStart = clock.now
        try await engine.load()
        let loadMs = Int(loadStart.duration(to: clock.now) / .milliseconds(1))

        let runStart = clock.now
        let text = try await engine.transcribe(samples, language: language)
        let ms = Int(runStart.duration(to: clock.now) / .milliseconds(1))

        let peak = max(sampler.stop(), PeakMemory.currentMB())
        Log.transcription.info("Benchmark: \(duration, format: .fixed(precision: 1)) s in \(ms) ms, peak \(peak) MB")
        return Report(
            file: file,
            durationSeconds: duration,
            language: language,
            model: STTEngine.local.modelName,
            text: text,
            loadMs: loadMs,
            ms: ms,
            rtf: duration > 0 ? (Double(ms) / 1000 / duration * 1000).rounded() / 1000 : 0,
            peakMemoryMB: peak,
            memoryDeltaMB: max(peak - before, 0),
            wer: reference.map { WordErrorRate.compute(reference: $0, hypothesis: text) }
        )
    }
}

/// Polls the process footprint every 100 ms while the model loads and runs, so a short spike
/// between two reads is not missed.
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
