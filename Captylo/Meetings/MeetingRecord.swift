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

    /// Display label for a segment: user name, "Mówca N", or the track default.
    func label(for segment: MeetingSegmentRecord) -> String {
        if let speaker = segment.speaker {
            if let name = speakerNames[speaker], !name.isEmpty { return name }
            return String(localized: "Mówca \(speaker)")
        }
        return segment.track.defaultLabel
    }
}
