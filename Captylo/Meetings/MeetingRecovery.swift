import Foundation

/// What the launch recovery found (`Database.markInterruptedMeetings`).
struct MeetingRecovery: Equatable, Sendable {
    /// Left "recording" by a crash or quit: now "interrupted", with the segments they saved.
    var interrupted: [UUID] = []
    /// Left "processing": the stop saved everything, only the post-processors were cut short.
    /// In stop order (the oldest first); the recorder finishes their AI steps.
    var resumed: [UUID] = []
}
