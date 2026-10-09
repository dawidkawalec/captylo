import AppKit

/// One Captylo with a UI at a time. macOS keeps a second copy away only when the app is opened
/// through LaunchServices (Finder, Dock, `open`); running the binary directly (a script or an AI
/// agent calling `Captylo --help`) used to start a second full app: two hotkeys, two menu bar
/// items, two call detectors. A plain launch that finds another Captylo with the same bundle id
/// brings that one forward and exits before any state is built. The MCP server (`--mcp`) never
/// checks in with LaunchServices, so it is never seen here and never counts.
enum SingleInstance {
    /// Set by `AppRelauncher` on the new copy: the pid of the copy it replaces, which quits right
    /// after and must not count as "already running".
    static let replacesPIDKey = "CAPTYLO_REPLACES_PID"

    /// The process to hand off to: a running Captylo other than this one and the one being
    /// replaced, nil when this launch should go ahead.
    static func instanceToActivate(currentPID: pid_t, replacedPID: pid_t?, running: [pid_t]) -> pid_t? {
        running.first { $0 != currentPID && $0 != replacedPID }
    }

    /// True when another Captylo already runs: it is activated and this launch should exit.
    @MainActor
    static func handOffIfRunning(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let replaced = environment[replacesPIDKey].flatMap { pid_t($0) }
        guard let pid = instanceToActivate(currentPID: getpid(), replacedPID: replaced, running: apps.map(\.processIdentifier)),
              let other = apps.first(where: { $0.processIdentifier == pid })
        else { return false }
        Log.app.notice("Captylo already runs (pid \(pid, privacy: .public)): activating it, this launch exits")
        other.activate()
        return true
    }
}
