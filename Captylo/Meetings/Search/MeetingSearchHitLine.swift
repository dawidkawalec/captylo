import Foundation

/// One line under a meeting row while searching: where the query matched and the text around it
/// ("[12:34] Anna: ...wyślę ofertę jutro..."). A click opens that place in the details.
struct MeetingSearchHitLine: Sendable, Equatable, Identifiable {
    enum Source: Sendable, Equatable {
        /// A transcript line: the details open "Transkrypt" at this segment.
        case segment(UUID, start: Double)
        /// The user's notes: the details open "Notatki".
        case notes
    }

    var source: Source
    /// The speaker ("Ja", "Anna", "Mówca 2") or "Notatki".
    var label: String
    var snippet: MeetingSearchSnippet

    var id: String {
        switch source {
        case .segment(let id, _): return id.uuidString
        case .notes: return "notes"
        }
    }
}
