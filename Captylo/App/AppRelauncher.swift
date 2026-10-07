import AppKit

/// Starts a new copy of the app from its bundle, then quits this one: an Accessibility grant
/// (gotcha 54) and a new "Język aplikacji" apply only to a new process.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
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
