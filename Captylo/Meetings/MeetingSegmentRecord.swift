import Foundation

/// One transcribed utterance of one track. Times are seconds from the meeting start.
/// `isEcho` marks a mic segment that repeats the system track (speakers, no headphones): kept, never shown.
struct MeetingSegmentRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var meetingID: UUID
    var track: MeetingTrack
    var start: Double
    var end: Double
    var text: String
    var words: [MeetingWord] = []
    /// Diarization label ("1", "2"...) for `.them`; nil = the track's default label.
    var speaker: String? = nil
    var isEcho: Bool = false
    /// The text before the AI fixed it ("Poprawiaj transkrypt przez AI"); nil when the AI never
    /// changed this line. "Przywróć transkrypt" puts it back.
    var originalText: String? = nil
}
