import Foundation
import os

/// One step of the launch resume: runs `processor` for a meeting only when its work is still
/// missing on the row (`isDone` false), so the AI notes written before the quit are kept and
/// the AI fix never runs twice. The processor's own gate (Pro, setting) still applies.
struct MeetingResumeStep: MeetingPostProcessing {
    let database: Database
    let isDone: @Sendable (MeetingRecord) -> Bool
    let processor: any MeetingPostProcessing

    func process(meetingID: UUID) async {
        let meeting: MeetingRecord?
        do {
            meeting = try await database.meeting(id: meetingID)
        } catch {
            Log.data.error("Meeting resume could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let meeting, !isDone(meeting) else { return }
        await processor.process(meetingID: meetingID)
    }
}
