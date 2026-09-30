import FluidAudio
import Foundation

/// Re-transcribes the last 15 s of the live buffer once per second while recording (gotcha 20).
/// Always Parakeet; the final text comes from the router's full pass, not from these partials.
struct LivePreview: LivePreviewing {
    static let defaultTick: Duration = .seconds(1)
    /// New samples required since the last pass: 0.5 s at 16 kHz.
    static let minNewSamples = ASRConstants.sampleRate / 2
    /// Tail handed to the engine (the engine caps it further so the padded input fits one pass).
    static let tailSamples = ASRConstants.maxModelSamples

    private let engine: any LocalTranscribing
    private let tick: Duration

    /// - Parameter tick: interval between passes; tests shorten it.
    init(engine: any LocalTranscribing, tick: Duration = LivePreview.defaultTick) {
        self.engine = engine
        self.tick = tick
    }

    func updates(buffer: SampleBuffer, language: String?) -> AsyncStream<String> {
        let engine = engine
        let tick = tick
        return AsyncStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                var nextTick = clock.now + tick
                var lastCount = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(until: nextTick, clock: clock)
                    } catch {
                        break
                    }
                    let count = buffer.count
                    if count - lastCount >= Self.minNewSamples {
                        lastCount = count
                        do {
                            let text = try await engine.preview(buffer.tail(Self.tailSamples), language: language)
                            if Task.isCancelled { break }
                            if !text.isEmpty {
                                continuation.yield(text)
                            }
                        } catch {
                            Log.transcription.error("Live preview pass failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    // A pass longer than one tick skips the missed ticks instead of queueing them.
                    nextTick = max(nextTick + tick, clock.now)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
