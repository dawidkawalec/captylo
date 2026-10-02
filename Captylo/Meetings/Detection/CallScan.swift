import Foundation

/// One poll of the apps holding the mic, as `MeetingDetector.appsInCalls(keeping:)` reads it.
struct CallScan: Sendable, Equatable {
    /// Known call apps holding the mic, and browsers holding it with a call window or already in
    /// a call (`keeping`); one entry per app.
    var apps: [MeetingApp]
    /// Browsers among `apps` that count only because they are already in a call: they hold the
    /// mic, but none of their windows names a call service in this poll. `MeetingDetector` drops
    /// a browser that stays like this for `browserIdleAfter`. Empty when titles cannot be read.
    var browsersWithoutCallWindow: Set<String> = []
}
