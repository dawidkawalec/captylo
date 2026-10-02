import Foundation

/// Re-transcribes the last 15 s of the live buffer every 1.5 s while recording (one Whisper pass
/// takes 0.7-0.9 s, so a faster tick would keep the model busy). Always the local engine; the
/// final text comes from the router's full pass, not from these partials.
struct LivePreview: LivePreviewing {
    static let defaultTick: Duration = .milliseconds(1500)
    /// New samples required since the last pass: 0.5 s at 16 kHz.
    static let minNewSamples = SampleBuffer.sampleRate / 2
    /// Tail handed to the engine: 15 s keeps the decoder short (the engine caps it at one window).
    static let tailSamples = 15 * SampleBuffer.sampleRate

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
