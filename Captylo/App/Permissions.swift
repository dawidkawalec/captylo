import AppKit
import AVFoundation
import Observation

/// Microphone and Accessibility state for onboarding, settings and the main-window banner.
/// Accessibility polling lives in `AccessibilityWatcher` (gotcha 38); this type adds the
/// microphone side, the deep links and the relaunch helper (gotcha 54).
@MainActor
@Observable
final class Permissions {
    /// Offer "Uruchom ponownie" when Accessibility is still untrusted this long after the toggle.
    static let relaunchHintDelay: Duration = .seconds(5)

    private(set) var microphone: AVAuthorizationStatus
    let accessibility: AccessibilityWatcher

    /// True after an Accessibility request stayed untrusted for `relaunchHintDelay` (gotcha 54).
    private(set) var suggestsRelaunch = false

    @ObservationIgnored private var relaunchHintTask: Task<Void, Never>?

    init(accessibility: AccessibilityWatcher) {
        self.accessibility = accessibility
        microphone = MicrophonePermission.status
    }

    var isMicrophoneAuthorized: Bool { microphone == .authorized }
    var isMicrophoneDenied: Bool { microphone == .denied || microphone == .restricted }
    var isAccessibilityTrusted: Bool { accessibility.isTrusted }
    var allGranted: Bool { isMicrophoneAuthorized && isAccessibilityTrusted }

    /// Re-reads both states (call on app activation and when a view appears).
    func refresh() {
        microphone = MicrophonePermission.status
        accessibility.refresh()
        if accessibility.isTrusted {
            suggestsRelaunch = false
            relaunchHintTask?.cancel()
        }
    }

    // MARK: Microphone

    /// Prompts when undecided; `.denied` / `.restricted` never prompt again (gotcha 32).
    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await MicrophonePermission.request()
        microphone = MicrophonePermission.status
        return granted
    }

    func openMicrophoneSettings() {
        MicrophonePermission.openSystemSettings()
    }

    // MARK: Accessibility

    /// Shows the system prompt (once per code identity) and opens the pane directly, then waits
    /// `relaunchHintDelay` before suggesting a relaunch (gotcha 54).
    func requestAccessibility() {
        let trusted = accessibility.requestPrompt()
        guard !trusted else { return }
        accessibility.openSystemSettings()
        relaunchHintTask?.cancel()
        relaunchHintTask = Task { [weak self] in
            try? await Task.sleep(for: Self.relaunchHintDelay)
            guard !Task.isCancelled, let self else { return }
            self.accessibility.refresh()
            self.suggestsRelaunch = !self.accessibility.isTrusted
        }
    }

    func openAccessibilitySettings() {
        accessibility.openSystemSettings()
    }

    /// Relaunches the app from its bundle: an Accessibility grant often applies only to a new process.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
