import Security
import Testing
@testable import Captylo

struct CalendarConnectRowTests {
    @Test func offOffersToConnectUntilDismissed() {
        #expect(CalendarConnectRow.kind(isOn: false, dismissed: false, access: .notDetermined) == .connect)
        #expect(CalendarConnectRow.kind(isOn: false, dismissed: false, access: .denied) == .connect)
        #expect(CalendarConnectRow.kind(isOn: false, dismissed: true, access: .notDetermined) == nil)
    }

    @Test func onShowsNothingWhileTheCalendarCanBeRead() {
        #expect(CalendarConnectRow.kind(isOn: true, dismissed: false, access: .fullAccess) == nil)
    }

    /// "Połącz" turned it on but macOS never answered: the offer stays so it can be retried.
    @Test func onWithoutAnAnswerKeepsTheOffer() {
        #expect(CalendarConnectRow.kind(isOn: true, dismissed: false, access: .notDetermined) == .connect)
        #expect(CalendarConnectRow.kind(isOn: true, dismissed: true, access: .notDetermined) == .connect)
    }

    /// Under Hardened Runtime the system prompt only appears with this entitlement; without it
    /// "Połącz" did nothing and the row vanished.
    @Test func appIsSignedToAskForTheCalendar() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.personal-information.calendars" as CFString, nil)
        #expect(value as? Bool == true)
    }

    /// "Nie teraz" only hides the offer; a calendar the user turned on but cannot read is always explained.
    @Test func onWithoutAccessExplainsWhy() {
        for access in [CalendarAccess.denied, .restricted, .writeOnly] {
            guard case .noAccess(let message) = CalendarConnectRow.kind(isOn: true, dismissed: true, access: access) else {
                Issue.record("expected noAccess for \(access)")
                continue
            }
            #expect(!message.isEmpty)
        }
    }
}
