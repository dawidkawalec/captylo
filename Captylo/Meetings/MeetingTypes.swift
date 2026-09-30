import Foundation

// The small value types of one concept, "meeting vocabulary", shared by the whole module.

/// The two recorded tracks of a meeting: the user's mic and everything the Mac plays.
enum MeetingTrack: String, Codable, Sendable, CaseIterable {
    case me
    case them

    /// File name inside `AppPaths.meetingFolder(_:)`.
    var fileName: String { self == .me ? "me.caf" : "them.caf" }

    var defaultLabel: String {
        switch self {
        case .me: return String(localized: "Ja")
        case .them: return String(localized: "Rozmówcy")
        }
    }
}

enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case completed
    case interrupted
    case failed
}

/// One word with times relative to the meeting start (seconds).
struct MeetingWord: Codable, Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// A line of the user's own notes and the meeting time it was written at.
struct MeetingNoteLine: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var at: Double
}

/// "Zachowuj nagrania spotkań".
enum MeetingAudioRetention: String, CaseIterable, Sendable {
    case none
    case days7
    case days30
    case forever

    /// Days to keep audio; 0 deletes it once the meeting is processed, nil keeps it forever.
    var days: Int? {
        switch self {
        case .none: return 0
        case .days7: return 7
        case .days30: return 30
        case .forever: return nil
        }
    }

    var title: String {
        switch self {
        case .none: return String(localized: "Nie zachowuj")
        case .days7: return String(localized: "7 dni")
        case .days30: return String(localized: "30 dni")
        case .forever: return String(localized: "Zawsze")
        }
    }
}
