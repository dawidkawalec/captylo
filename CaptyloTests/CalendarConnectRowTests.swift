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
        // The system prompt is still to come: nothing to explain yet.
        #expect(CalendarConnectRow.kind(isOn: true, dismissed: false, access: .notDetermined) == nil)
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
