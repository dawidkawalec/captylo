import Foundation

/// A kind of meeting and what its AI notes should focus on (added to the base prompt).
struct MeetingTemplate: Sendable, Equatable, Identifiable {
    let id: String
    /// Name shown in the template picker (localized).
    let name: String
    /// Folded title keywords (`MeetingSearch.fold`) that pick this template. Each must start a
    /// word of the title; one ending in a digit ("1:1") must also end one, so "11:15" never matches.
    let keywords: [String]
    /// What to focus on, in Polish (the prompt is Polish whatever the UI language).
    let instructions: String
}
