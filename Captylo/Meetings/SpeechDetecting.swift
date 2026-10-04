import FluidAudio

/// Streaming voice activity detection over 16 kHz chunks of `VadManager.chunkSize` samples.
/// The caller keeps the stream state (one per track) and passes it back with every chunk.
protocol SpeechDetecting: Sendable {
    func initialState() async -> VadStreamState
    func process(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult
}
