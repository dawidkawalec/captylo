import Foundation

/// The data of the AI notes (`CaptyloAITask.Kind.meetingNotes`): the relay holds the
/// instructions; the answer is Markdown with the sections `MeetingNotesDocument` reads.
/// Speaker labels come from `MeetingRecord.promptLabel(for:)`.
enum MeetingNotesPrompt {
    /// Title, the participants from the calendar when there are any (so the names are spelled
    /// right), the user's note lines with their times, then every non-echo segment in time order.
    static func user(meeting: MeetingRecord, segments: [MeetingSegmentRecord]) -> String {
        var header = "Tytuł: \(meeting.title)"
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            header += "\nUczestnicy: " + participants.joined(separator: ", ")
        }
        let notes = meeting.noteLines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\(MeetingTime.stamp($0.at)) \($0.text)" }
            .joined(separator: "\n")
        let transcript = segments
            .filter { !$0.isEcho }
            .sorted { $0.start < $1.start }
            .map { "\(MeetingTime.stamp($0.start)) \(meeting.promptLabel(for: $0)): \($0.text)" }
            .joined(separator: "\n")
        return """
        \(header)
        <user_notes>
        \(notes)
        </user_notes>
        <transcript>
        \(transcript)
        </transcript>
        """
    }
}
