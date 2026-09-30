import Foundation
import os

/// After a meeting (Pro): AI notes from the template picked by the title, stored on the meeting
/// row. Runs after `SpeakerLabelProcessor`, so the transcript already carries "Mówca N".
struct MeetingNotesProcessor: MeetingPostProcessing {
    let database: Database
    let summarizer: MeetingSummarizer
    let isAllowed: @Sendable () async -> Bool

    func process(meetingID: UUID) async {
        guard await isAllowed() else { return }
        await regenerate(meetingID: meetingID, templateID: nil)
    }

    /// Also for "Wygeneruj ponownie" with a template the user picked (nil = pick from the title).
    /// On success stores the notes, template and model and clears the error; on failure stores
    /// the Polish error and keeps earlier notes.
    func regenerate(meetingID: UUID, templateID: String?) async {
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting notes could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return
        }
        let template = templateID.map(BuiltInMeetingTemplates.template(id:)) ?? BuiltInMeetingTemplates.pick(forTitle: meeting.title)

        let outcome: Result<(markdown: String, model: String), any Error>
        do {
            outcome = .success(try await summarizer.summarize(meeting: meeting, segments: segments, template: template))
        } catch {
            Log.enhancement.error("Meeting notes failed: \(error.localizedDescription, privacy: .public)")
            outcome = .failure(error)
        }

        // The call can take minutes: re-read, so a title, notes or names edited meanwhile survive.
        do {
            guard var latest = try await database.meeting(id: meetingID) else { return }
            switch outcome {
            case .success(let result):
                latest.summary = result.markdown
                latest.summaryModel = result.model
                latest.summaryTemplateID = template.id
                latest.summaryError = nil
            case .failure(let error):
                latest.summaryError = error.localizedDescription
            }
            try await database.updateMeeting(latest)
        } catch {
            Log.data.error("Meeting notes could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
