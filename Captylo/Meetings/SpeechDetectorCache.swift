import Foundation

/// Loads the meeting VAD once and hands the same detector to both tracks and to every later
/// meeting (it keeps no stream state, `FluidSpeechDetector`). Callers that arrive while it loads
/// wait for that load. A failed load is not kept, so the transcriber's later retry loads again.
actor SpeechDetectorCache {
    private let load: @Sendable () async throws -> any SpeechDetecting
    private var loaded: (any SpeechDetecting)?
    private var loading: Task<any SpeechDetecting, any Error>?

    init(load: @escaping @Sendable () async throws -> any SpeechDetecting) {
        self.load = load
    }

    /// Loads the detector ahead of the first meeting (with the speech model and at launch),
    /// which downloads it once; the meetings then find it ready.
    func prewarm() async throws {
        _ = try await detector()
    }

    func detector() async throws -> any SpeechDetecting {
        if let loaded { return loaded }
        if let loading { return try await loading.value }
        let task = Task { [load] in try await load() }
        loading = task
        defer { loading = nil }
        let detector = try await task.value
        loaded = detector
        return detector
    }
}
