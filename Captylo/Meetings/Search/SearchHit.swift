import Foundation

/// One match of the meeting search index: where it is, never the text (the snippet comes from the store).
struct SearchHit: Sendable, Equatable {
    enum Kind: String, Sendable {
        case title
        case notes
        case segment
    }

    var meetingID: UUID
    /// The matching segment; nil for a title or notes hit.
    var segmentID: UUID?
    var kind: Kind
    /// Seconds from the meeting start (segments), 0 otherwise.
    var start: Double
    /// The segment's track; nil for a title or notes hit.
    var track: MeetingTrack?
    /// bm25 weighted by kind (title and notes count more): lower is better.
    var rank: Double
}
