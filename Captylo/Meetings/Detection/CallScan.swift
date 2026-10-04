import Foundation

/// One poll of the apps holding the mic, as `MeetingDetector.appsInCalls(keeping:)` reads it.
struct CallScan: Sendable, Equatable {
    /// Known call apps holding the mic, and browsers holding it with a call window or already in
    /// a call (`keeping`); one entry per app.
    var apps: [MeetingApp]
    /// Browsers among `apps` that count only because they are already in a call: they hold the
    /// mic, but none of their windows or tabs names a call service in this poll
    /// (`BrowserCallWindows.Check.noCall`). `MeetingDetector` drops a browser that stays like
    /// this for `browserIdleAfter`. A browser whose tabs cannot be read is never listed here.
    var browsersWithoutCallWindow: Set<String> = []
}
