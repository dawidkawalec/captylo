import Foundation

/// A kind of meeting for the AI notes. The app knows its id, name and title keywords; what the
/// notes focus on for each id lives on the relay (`CaptyloAITask.template`).
struct MeetingTemplate: Sendable, Equatable, Identifiable {
    let id: String
    /// Name shown in the template picker (localized).
    let name: String
    /// Folded title keywords (`MeetingSearch.fold`) that pick this template. Each must start a
    /// word of the title; one ending in a digit ("1:1") must also end one, so "11:15" never matches.
    let keywords: [String]
}
