import Foundation

/// A search hit line was clicked: the details open "Transkrypt" of `meetingID`, scroll to the
/// line that holds `segmentID` and light it up for a moment. A new value per click, so the same
/// hit clicked again jumps again.
struct MeetingTranscriptJump: Equatable, Sendable {
    let id = UUID()
    let meetingID: UUID
    let segmentID: UUID
}
