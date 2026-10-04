// `OfflineDiarizerManager` is a non-Sendable class whose async `process` runs off this actor.
// It never leaves the actor and its models are read-only after loading (FluidAudio's own note).
@preconcurrency import FluidAudio
import Foundation

/// pyannote community-1 + VBx through FluidAudio, offline over the "Rozmówcy" track file
/// (memory-mapped, 10-30 s per hour of audio). The models download on first use and stay loaded
/// for later meetings. Crashes on macOS 14 (Apple BNNS bug, FluidAudio #878): callers gate it
/// with `SpeakerLabelProcessor.systemSupportsDiarization`. One call at a time is expected (the
/// recorder runs its post-processing in order and one meeting records at a time).
actor FluidSpeakerDiarizer: SpeakerDiarizing {
    private var manager: OfflineDiarizerManager?

    func diarize(url: URL) async throws -> [SpeakerTurn] {
        let manager = try await prepared()
        let result = try await manager.process(url)
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// A failed load is not kept, so the next meeting tries again.
    private func prepared() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        self.manager = manager
        return manager
    }
}
