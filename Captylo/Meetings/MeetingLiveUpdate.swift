import Foundation

/// What the live meeting view hears from `MeetingTranscriber` while it records.
enum MeetingLiveUpdate: Sendable, Equatable {
    /// A finished utterance, already saved.
    case segment(MeetingSegmentRecord)
    /// The utterance still being spoken on a track (the grey "w trakcie" line); "" clears it.
    case partial(MeetingTrack, String)
}
