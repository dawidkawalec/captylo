import Foundation

/// Per-delivery options built from `AppSettings` (`AppSettings.outputSettings`).
struct OutputSettings: Sendable, Equatable {
    /// Restore the previous clipboard when `changeCount` is unchanged after `restoreDelay`.
    var restoreClipboard: Bool
    /// Fixed 2 s in the UI; never below 0.25 s (gotcha 52).
    var restoreDelay: Duration
    var trailingSpace: Bool

    init(restoreClipboard: Bool = true, restoreDelay: Duration = .seconds(2), trailingSpace: Bool = true) {
        self.restoreClipboard = restoreClipboard
        self.restoreDelay = restoreDelay
        self.trailingSpace = trailingSpace
    }
}

enum OutputResult: Sendable, Equatable {
    case pasted
    /// Cmd+V could not be posted (no Accessibility, event creation failed); the text stays on the clipboard.
    case copiedOnly(reason: String)
}
