import Foundation
import Testing
@testable import Captylo

struct AccountUsageFormatTests {
    private let pl = Locale(identifier: "pl_PL")
    private let en = Locale(identifier: "en_US")

    @Test func durationsInMinutesThenHours() {
        #expect(AccountUsageFormat.duration(0, locale: pl) == "0 min")
        #expect(AccountUsageFormat.duration(59, locale: pl) == "0 min")
        #expect(AccountUsageFormat.duration(45 * 60, locale: pl) == "45 min")
        #expect(AccountUsageFormat.duration(3600, locale: pl) == "1 h")
        #expect(AccountUsageFormat.duration(10_800, locale: pl) == "3 h")
        #expect(AccountUsageFormat.duration(12_600, locale: pl) == "3,5 h")
        #expect(AccountUsageFormat.duration(12_600, locale: en) == "3.5 h")
        // Rounded down to a tenth, so the bar never claims more than was used.
        #expect(AccountUsageFormat.duration(3600 + 359, locale: pl) == "1 h")
        #expect(AccountUsageFormat.duration(72_000, locale: pl) == "20 h")
    }

    @Test func fractionsAreClamped() {
        #expect(AccountUsageFormat.fraction(0, limit: 100) == 0)
        #expect(AccountUsageFormat.fraction(25, limit: 100) == 0.25)
        #expect(AccountUsageFormat.fraction(250, limit: 100) == 1)
        #expect(AccountUsageFormat.fraction(5, limit: 0) == 0)
        #expect(AccountUsageFormat.fraction(-5, limit: 100) == 0)
    }

    @Test func percentRoundsDown() {
        #expect(AccountUsageFormat.percent(360_000, limit: 3_000_000) == 12)
        #expect(AccountUsageFormat.percent(1, limit: 3_000_000) == 0)
        #expect(AccountUsageFormat.percent(3_000_000, limit: 3_000_000) == 100)
        #expect(AccountUsageFormat.percent(9_000_000, limit: 3_000_000) == 100)
        #expect(AccountUsageFormat.percent(10, limit: 0) == 0)
    }

    @Test func linesCarryTheNumbers() {
        let audio = AccountUsageFormat.audio(10_800, limit: 72_000, locale: pl)
        #expect(audio.contains("3 h"))
        #expect(audio.contains("20 h"))
        #expect(audio == String(localized: "Chmura: \("3 h") z \("20 h") w tym miesiącu"))
        let tokens = AccountUsageFormat.tokens(360_000, limit: 3_000_000)
        #expect(tokens.contains("12"))
        #expect(tokens == String(localized: "AI: \(12)% limitu"))
    }
}
