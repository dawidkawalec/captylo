import Foundation

/// What the live meeting view hears from `MeetingTranscriber` while it records.
enum MeetingLiveUpdate: Sendable, Equatable {
    /// Why speech is not turning into lines right now. The audio still records either way.
    enum Problem: Sendable, Equatable {
        /// The voice detection model did not load (it downloads on the first meeting): nothing
        /// is cut into utterances until a retry loads it.
        case speechDetector
        /// A pass of the speech model failed (the model is missing or broken): that line is lost.
        case speechModel
    }

    /// A finished utterance, already saved.
    case segment(MeetingSegmentRecord)
    /// The utterance still being spoken on a track (the grey "w trakcie" line); "" clears it.
    case partial(MeetingTrack, String)
    /// The transcription problem changed; nil when lines come through again.
    case problem(Problem?)
}
