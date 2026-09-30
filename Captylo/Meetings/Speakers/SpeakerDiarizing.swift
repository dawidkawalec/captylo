import Foundation

/// Finds who spoke when in one track file. `FluidSpeakerDiarizer` in the app, fakes in tests.
protocol SpeakerDiarizing: Sendable {
    func diarize(url: URL) async throws -> [SpeakerTurn]
}
