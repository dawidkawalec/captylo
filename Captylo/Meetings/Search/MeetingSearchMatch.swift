import Foundation

/// The index hits of one meeting for the Spotkania list (`MeetingSearchResults.group`).
struct MeetingSearchMatch: Sendable, Equatable {
    var meetingID: UUID
    /// The best (lowest) rank of any of its hits: the row's place in the results.
    var bestRank: Double
    /// Its best segment hits, at most `MeetingSearchResults.segmentHitsPerMeeting`, in time order.
    var segmentHits: [SearchHit]
    var titleMatched: Bool
    var notesMatched: Bool
}
