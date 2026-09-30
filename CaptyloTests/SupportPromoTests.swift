import Foundation
import Testing
@testable import Captylo

struct SupportPromoTests {
    private let sponsor = SponsorAd(
        title: "Sponsor",
        message: "Wiadomość sponsora",
        actionTitle: "Sprawdź",
        url: URL(string: "https://example.com")!
    )

    @Test func proAndCoffeeTakeTurnsWithoutASponsor() {
        #expect(SupportPromo.current(on: 0, sponsor: nil) == .pro)
        #expect(SupportPromo.current(on: 1, sponsor: nil) == .coffee)
        #expect(SupportPromo.current(on: 2, sponsor: nil) == .pro)
        #expect(SupportPromo.current(on: -1, sponsor: nil) == .coffee)
    }

    @Test func aSponsorJoinsTheRotation() {
        let week = (0..<6).map { SupportPromo.current(on: $0, sponsor: sponsor) }
        #expect(week == [.pro, .coffee, .sponsor(sponsor), .pro, .coffee, .sponsor(sponsor)])
        #expect(SupportPromo.sponsor(sponsor).url == sponsor.url)
        #expect(SupportPromo.sponsor(sponsor).title == "Sponsor")
    }

    @Test func noSponsorShipsByDefault() {
        #expect(SponsorAd.current == nil)
    }

    @Test func hiddenUntilADateThenVisibleAgain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SupportPromo.isVisible(hiddenUntil: nil, now: now))
        let hiddenUntil = now.addingTimeInterval(SupportPromo.hideInterval)
        #expect(!SupportPromo.isVisible(hiddenUntil: hiddenUntil, now: now))
        #expect(!SupportPromo.isVisible(hiddenUntil: hiddenUntil, now: now.addingTimeInterval(13 * 86_400)))
        #expect(SupportPromo.isVisible(hiddenUntil: hiddenUntil, now: hiddenUntil))
    }

    @Test func theDayChangesAtMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 8)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 23, minute: 59)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 0, minute: 1)))
        #expect(SupportPromo.dayNumber(morning, calendar: calendar) == SupportPromo.dayNumber(evening, calendar: calendar))
        #expect(SupportPromo.dayNumber(nextDay, calendar: calendar) == SupportPromo.dayNumber(morning, calendar: calendar) + 1)
    }

    @Test func linksPointAtOurSite() {
        #expect(SupportPromo.pro.url.absoluteString == "https://captylo.com/#cennik")
        #expect(SupportPromo.coffee.url.absoluteString == "https://captylo.com/kawa/")
    }
}
