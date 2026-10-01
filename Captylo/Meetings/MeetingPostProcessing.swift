import Foundation

/// Work that runs after a meeting stops (speaker labels, AI notes, audio retention), in order.
/// The recorder sets the meeting to "processing" and is idle again before the first one runs;
/// they run in the background, one meeting at a time, and the recorder sets "completed" after
/// the last. A processor re-reads the record (the user may rename the meeting or type notes
/// meanwhile), changes only its own fields and saves.
protocol MeetingPostProcessing: Sendable {
    func process(meetingID: UUID) async
}
