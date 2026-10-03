import Foundation

/// The usage lines of the Pro plan card: "Chmura: 3 h z 20 h w tym miesiącu", "AI: 12% limitu".
/// Pure, so the numbers are tested without a view.
enum AccountUsageFormat {
    /// Minutes below an hour, then hours with at most one decimal, rounded down ("3,5 h").
    static func duration(_ seconds: Int, locale: Locale = AppLocale.current) -> String {
        let seconds = max(seconds, 0)
        if seconds < 3600 {
            return "\(seconds / 60) min"
        }
        let tenths = Double(seconds / 360) / 10
        let number = tenths.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return "\(number) h"
    }

    /// Used share of the limit, 0...1 (0 when there is no limit).
    static func fraction(_ used: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    /// Used share in whole percent, rounded down, at most 100.
    static func percent(_ used: Int, limit: Int) -> Int {
        Int((fraction(used, limit: limit) * 100).rounded(.down))
    }

    static func audio(_ seconds: Int, limit: Int, locale: Locale = AppLocale.current) -> String {
        let used = duration(seconds, locale: locale)
        let cap = duration(limit, locale: locale)
        return String(localized: "Chmura: \(used) z \(cap) w tym miesiącu")
    }

    static func tokens(_ used: Int, limit: Int) -> String {
        String(localized: "AI: \(percent(used, limit: limit))% limitu")
    }
}
