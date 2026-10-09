import AppKit

/// Starts a new copy of the app from its bundle, then quits this one: an Accessibility grant
/// (gotcha 54) and a new "Język aplikacji" apply only to a new process.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // The new copy starts while this one still runs: tell it which copy it replaces, or it
        // would hand off to this one and exit (SingleInstance).
        configuration.environment = [SingleInstance.replacesPIDKey: String(getpid())]
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
