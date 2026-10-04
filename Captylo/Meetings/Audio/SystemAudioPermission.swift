import AppKit

/// "System Audio Recording Only" (Privacy & Security): where the user lets Captylo hear other
/// apps. There is no API for the grant state; a denied tap delivers exact zeros, which
/// `SystemTrackWatch` notices.
enum SystemAudioPermission {
    /// The pane with the "System Audio Recording Only" list. The anchor is in the search terms of
    /// the Privacy & Security settings on macOS 26 (checked); an older system that does not know
    /// it shows Privacy & Security, one click away.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    /// Privacy & Security itself, when the settings app refuses the anchor.
    static let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!

    @MainActor
    static func openSettings() {
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}
