import Observation
import ServiceManagement

/// "Uruchamiaj przy logowaniu" through `SMAppService.mainApp`. The service status is the only
/// source of truth (gotcha 8): nothing is stored in defaults, `.notFound` shows up when the app runs
/// from a build folder, and `register()` may end in `.requiresApproval`.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    /// Set when the last register / unregister call failed.
    private(set) var lastError: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool {
        get { status == .enabled }
        set { setEnabled(newValue) }
    }

    var requiresApproval: Bool { status == .requiresApproval }

    /// The app is not in a location launchd can find (build folders, DerivedData, a translocated
    /// copy straight from the DMG).
    var isUnavailable: Bool { Self.isUnavailable(status: status, bundleURL: Bundle.main.bundleURL) }

    /// `.notFound` alone is not enough: macOS also reports it for a copy in Applications that was
    /// never registered, or whose login item still points at an older copy that is gone. Such a
    /// copy can register, so the switch stays usable there.
    nonisolated static func isUnavailable(
        status: SMAppService.Status,
        bundleURL: URL,
        home: String = NSHomeDirectory()
    ) -> Bool {
        guard status == .notFound else { return false }
        let path = bundleURL.standardizedFileURL.path
        let applicationFolders = ["/Applications/", home + "/Applications/"]
        return !applicationFolders.contains { path.hasPrefix($0) }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        if status == .requiresApproval {
            Log.app.notice("Login item requires approval in System Settings")
        }
    }

    /// System Settings > General > Login Items, for the `.requiresApproval` hint.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
