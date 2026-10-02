import Foundation

/// A meeting as the rest of the app sees it (SwiftData models never leave `Database`).
struct MeetingRecord: Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String
    var status: MeetingStatus = .recording
    var duration: Double = 0
    /// Meeting app the recording was started for ("Zoom"), nil when started by hand.
    var appName: String? = nil
    /// Free text the user typed; `noteLines` keeps each line with its meeting time.
    var notes: String = ""
    var noteLines: [MeetingNoteLine] = []
    /// AI notes (Markdown), Pro.
    var summary: String? = nil
    var summaryTemplateID: String? = nil
    var summaryModel: String? = nil
    /// Why the AI notes failed ("Brak klucza AI"...), nil on success.
    var summaryError: String? = nil
    /// Speaker label -> name the user typed ("1": "Anna").
    var speakerNames: [String: String] = [:]
    /// False once the retention job (or the user) removed the track files.
    var hasAudio: Bool = true
    /// Meeting times where capture had a gap ("przerwa w nagraniu").
    var interruptions: [Double] = []
    /// The cloud model whose transcript replaced the live one ("scribe_v2"); nil = transcribed
    /// on this Mac while recording.
    var transcriptModel: String? = nil
    /// The AI model that last fixed the transcript; nil = not fixed (or restored).
    var transcriptAIModel: String? = nil
    /// Why the last cloud transcript or AI fix failed (Polish); nil when it worked.
    var transcriptError: String? = nil
    /// The calendar event this recording was linked to (`CalendarEvent.id`), nil when none.
    var calendarEventID: String? = nil
    /// Attendee names from the calendar event (the user left out), empty without an event.
    var participants: [String] = []

    /// What the title field in the details saves: `typed` on one line and trimmed, or nil when
    /// that is empty or the title it already has (nothing to save).
    static func editedTitle(_ typed: String, current: String) -> String? {
        let title = typed
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    /// Display label for a segment: user name, "Mówca N", or the track default.
    func label(for segment: MeetingSegmentRecord) -> String {
        label(track: segment.track, speaker: segment.speaker)
    }

    /// Display label for a track and diarization label (a merged transcript line).
    func label(track: MeetingTrack, speaker: String?) -> String {
        if let speaker {
            if let name = speakerNames[speaker], !name.isEmpty { return name }
            return String(localized: "Mówca \(speaker)")
        }
        return track.defaultLabel
    }

    /// Like `label(for:)`, but always Polish ("Ja", "Rozmówcy", "Mówca N"): the AI notes prompt
    /// refers to these words, so they never go through the string catalog.
    func promptLabel(for segment: MeetingSegmentRecord) -> String {
        if let speaker = segment.speaker {
            if let name = speakerNames[speaker], !name.isEmpty { return name }
            return "Mówca " + speaker
        }
        switch segment.track {
        case .me: return "Ja"
        case .them: return "Rozmówcy"
        }
    }
}
