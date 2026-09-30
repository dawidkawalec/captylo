import FluidAudio

/// Silero v6 through FluidAudio (streaming state machine with hysteresis, ~1200x real time).
/// Holds no stream state itself, so one loaded detector can serve both tracks.
final class FluidSpeechDetector: SpeechDetecting {
    /// FluidAudio's defaults, except speech ends after 0.6 s of silence (0.75 s by default):
    /// meeting turns come faster and a shorter pause gives the final text sooner.
    static let segmentation = VadSegmentationConfig(minSilenceDuration: 0.6)

    private let manager: VadManager

    private init(manager: VadManager) {
        self.manager = manager
    }

    /// Loads the Silero model; FluidAudio downloads it (about 1 MB) on first use.
    static func load() async throws -> FluidSpeechDetector {
        FluidSpeechDetector(manager: try await VadManager(config: .default))
    }

    func initialState() async -> VadStreamState {
        await manager.makeStreamState()
    }

    func process(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        try await manager.processStreamingChunk(chunk, state: state, config: Self.segmentation)
    }
}
