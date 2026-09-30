import Foundation

/// Work that runs after a meeting stops (speaker labels, AI notes, audio retention), in order.
/// The recorder sets the meeting to "processing" before the first one and "completed" after the
/// last, so a processor re-reads the record, changes only its own fields and saves.
protocol MeetingPostProcessing: Sendable {
    func process(meetingID: UUID) async
}
