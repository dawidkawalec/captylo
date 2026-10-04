import Foundation

/// Meeting clocks: "12:34" under an hour, "1:02:03" from one hour, "[12:34]" for citations.
enum MeetingTime {
    /// Upper bound that keeps `Int(seconds)` safe for absurd inputs (about 11 574 days).
    private static let maxSeconds: Double = 999_999_999

    static func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(max(0, seconds), maxSeconds)) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func stamp(_ seconds: Double) -> String {
        "[\(clock(seconds))]"
    }
}
