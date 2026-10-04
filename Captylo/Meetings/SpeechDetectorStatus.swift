import Foundation
import Observation
import os

/// Whether the meeting voice detector is on this Mac, for the line under the model status in
/// Modele and onboarding. `prewarm()` loads it through `SpeechDetectorCache` (the first load
/// downloads it, about 1 MB): after the speech model download and at launch once the model is
/// installed. Failures are shown here and logged, never surfaced as an alert; a meeting started
/// meanwhile loads the detector itself.
@MainActor
@Observable
final class SpeechDetectorStatus {
    enum State: Equatable, Sendable {
        /// No load attempted yet (or the speech model is not installed).
        case missing
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private let load: @Sendable () async throws -> Void
    /// Design preview: the state stays as pinned and nothing is loaded.
    @ObservationIgnored private let isPinned: Bool

    init(load: @escaping @Sendable () async throws -> Void, pinned: State? = nil) {
        self.load = load
        isPinned = pinned != nil
        state = pinned ?? .missing
    }

    /// Loads once; a call while it loads or after it is ready does nothing, a call after a
    /// failure tries again. The load itself runs on the cache actor, not the main actor.
    func prewarm() async {
        if isPinned { return }
        switch state {
        case .loading, .ready:
            return
        case .missing, .failed:
            break
        }
        state = .loading
        do {
            try await load()
            state = .ready
            Log.transcription.info("Meeting voice detector ready")
        } catch {
            Log.transcription.error("Meeting voice detector could not load: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }
}
