import AppKit
import AVFoundation

/// Microphone permission checks (gotcha 32): checked before every start, never cached.
enum MicrophonePermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isAuthorized: Bool { status == .authorized }

    /// Shows the system prompt when undecided. Returns true only when access is granted.
    /// `.denied` and `.restricted` never prompt again: open the settings pane instead.
    static func request() async -> Bool {
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.audio.info("Microphone permission prompt answered: \(granted)")
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Opens Privacy & Security > Microphone in System Settings.
    @MainActor
    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
