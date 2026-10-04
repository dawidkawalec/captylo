import Foundation

/// A "Captylo AI" job on the Pro relay: the app sends only the data as the user message and
/// names the job here (`captylo_task` in the chat body); the relay puts its own instructions
/// first and picks the model. The meeting AI runs only this way, so its instructions never ship
/// in the app.
struct CaptyloAITask: Sendable, Equatable, Encodable {
    enum Kind: String, Sendable, Encodable {
        case meetingNotes = "meeting_notes"
        case meetingAsk = "meeting_ask"
        case libraryAsk = "library_ask"
        case transcriptCorrection = "transcript_correction"
    }

    let kind: Kind
    /// The meeting template id (`MeetingTemplate.id`) for the notes; the relay falls back to `general`.
    var template: String? = nil
}
