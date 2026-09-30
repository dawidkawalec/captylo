/// The local engine seam consumed by `LivePreview` and `TranscriptionRouter`.
/// `ParakeetEngine` is the production implementation; tests inject a fake.
protocol LocalTranscribing: Sendable {
    /// Full pass over a complete recording. Returns "" for audio shorter than 0.3 s.
    func transcribe(_ samples: [Float], language: String?) async throws -> String
    /// Cheap pass over the live tail (capped to one encoder window). Returns "" until the model is ready.
    func preview(_ tail: [Float], language: String?) async throws -> String
}
