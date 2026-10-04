import Foundation

/// A transcriber that also returns word times (meetings need them for citations and playback).
/// Word times are relative to the start of `samples`; the caller adds the slice offset.
protocol MeetingSpeechTranscribing: Sendable {
    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript
    /// Text for the grey "w trakcie" line. May return "" when the engine is busy with finals.
    func previewText(_ samples: [Float], language: String?) async throws -> String
}

extension MeetingSpeechTranscribing {
    func previewText(_ samples: [Float], language: String?) async throws -> String {
        try await transcribeTimed(samples, language: language).text
    }
}
