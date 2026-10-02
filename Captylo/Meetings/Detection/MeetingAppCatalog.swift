import Foundation

/// Call apps and browsers by the bundle ID of the process that holds the mic.
///
/// Electron apps (Slack, Discord, Teams) and browsers take the mic from a helper process
/// (`com.tinyspeck.slackmacgap.helper`, `com.google.Chrome.helper`, Safari's
/// `com.apple.WebKit.GPU`), so an entry matches its prefix at a dot boundary, ignoring case
/// (Arc's helpers are lower case). Names are product names and never translated.
enum MeetingAppCatalog {
    private struct Entry {
        /// Bundle IDs of the app itself (lower case); a quit of one of these means the app is gone.
        let mainIDs: [String]
        /// `mainIDs` plus the prefixes of helper processes with a bundle ID of their own.
        let prefixes: [String]
        let app: MeetingApp
        /// Browsers: the app whose window titles tell a call from any other mic use.
        let windowOwner: String?

        init(_ name: String, _ mainIDs: [String], helpers: [String] = [], browser windowOwner: String? = nil) {
            self.mainIDs = mainIDs.map { $0.lowercased() }
            prefixes = self.mainIDs + helpers.map { $0.lowercased() }
            app = MeetingApp(name: name, isBrowser: windowOwner != nil)
            self.windowOwner = windowOwner
        }
    }

    private static let entries: [Entry] = [
        Entry("Zoom", ["us.zoom.xos"]),
        Entry("Teams", ["com.microsoft.teams2", "com.microsoft.teams"]),
        Entry("Slack", ["com.tinyspeck.slackmacgap"]),
        Entry("FaceTime", ["com.apple.FaceTime"]),
        Entry("Webex", ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]),
        Entry("Discord", ["com.hnc.Discord"]),
        Entry("Around", ["co.teamport.around"]),
        Entry("Tuple", ["app.tuple.app"]),
        Entry("Chrome", ["com.google.Chrome"], browser: "com.google.Chrome"),
        Entry("Safari", ["com.apple.Safari"], helpers: ["com.apple.WebKit"], browser: "com.apple.Safari"),
        Entry("Arc", ["company.thebrowser.Browser"], browser: "company.thebrowser.Browser"),
        Entry("Edge", ["com.microsoft.edgemac"], browser: "com.microsoft.edgemac"),
        Entry("Brave", ["com.brave.Browser"], browser: "com.brave.Browser"),
        Entry("Firefox", ["org.mozilla.firefox"], browser: "org.mozilla.firefox"),
    ]

    /// Words in a browser window title that mean a call: Google Meet, Teams and Zoom on the
    /// web, Whereby, Jitsi Meet.
    static let callTitleWords = ["Meet", "Teams", "Zoom", "Whereby", "Jitsi"]

    static func app(forBundleID id: String) -> MeetingApp? {
        entry(forBundleID: id)?.app
    }

    /// True for the bundle ID of a call app or browser itself, never for one of its helpers
    /// (`com.google.Chrome.helper.renderer` quits with every closed tab, Teams and WebKit
    /// helpers come and go during a call).
    static func isMainApp(bundleID id: String) -> Bool {
        let id = id.lowercased()
        return entries.contains { $0.mainIDs.contains(id) }
    }

    /// Bundle ID of the browser whose windows to read for a process of it (Safari for the
    /// WebKit helpers); nil for call apps.
    static func windowOwner(forBundleID id: String) -> String? {
        entry(forBundleID: id)?.windowOwner
    }

    static func isCallTitle(_ title: String) -> Bool {
        callTitleWords.contains { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func entry(forBundleID id: String) -> Entry? {
        let id = id.lowercased()
        guard !id.isEmpty else { return nil }
        return entries.first { entry in
            entry.prefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
        }
    }
}
