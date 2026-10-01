import Foundation

/// An app that can hold a call, as `MeetingDetector` names it in its prompts ("Wygląda na
/// spotkanie w Zoom"). Browsers only count when a window title names a call service.
struct MeetingApp: Sendable, Equatable {
    let name: String
    let isBrowser: Bool
}
