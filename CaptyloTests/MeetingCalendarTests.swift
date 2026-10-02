import EventKit
import Foundation
import Testing
@testable import Captylo

@MainActor
struct MeetingCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, startsIn minutes: Double, lasts length: Double = 30, allDay: Bool = false) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(
            id: id, title: "Wydarzenie \(id)", start: start, end: start.addingTimeInterval(length * 60),
            isAllDay: allDay, calendarTitle: "Praca", participants: ["Anna"], callApp: nil
        )
    }

    private func makeCalendar(source: FakeCalendarSource, isOn: Bool = true) -> (MeetingCalendar, Switch) {
        let toggle = Switch(isOn: isOn)
        let calendar = MeetingCalendar(source: source, isOn: { toggle.isOn }, now: { now })
        return (calendar, toggle)
    }

    @MainActor
    final class Switch {
        var isOn: Bool
        init(isOn: Bool) { self.isOn = isOn }
    }

    @Test func requestAccessPromptsOnceWhenNotDeterminedAndLoadsTheEvents() async {
        let source = FakeCalendarSource(access: .notDetermined, grants: .fullAccess, events: [event("a", startsIn: 10)])
        let (calendar, _) = makeCalendar(source: source)
        #expect(calendar.access == .notDetermined)
        #expect(!calendar.isEnabled)

        await calendar.requestAccess()
        #expect(calendar.access == .fullAccess)
        #expect(calendar.isEnabled)
        #expect(source.requestCount == 1)
        #expect(calendar.upcoming.map(\.id) == ["a"])

        // Already decided: no second prompt, the state is re-read.
        await calendar.requestAccess()
        #expect(source.requestCount == 1)
        #expect(calendar.access == .fullAccess)
    }

    @Test func aDeniedCalendarIsNeverRead() async {
        let source = FakeCalendarSource(access: .denied, grants: .denied, events: [event("a", startsIn: 1)])
        let (calendar, _) = makeCalendar(source: source)
        await calendar.requestAccess()
        await calendar.refresh()
        #expect(calendar.access == .denied)
        #expect(!calendar.isEnabled)
        #expect(source.readCount == 0)
        #expect(calendar.upcoming.isEmpty)
        #expect(calendar.currentEvent(at: now) == nil)
    }

    @Test func writeOnlyAccessCountsAsNotGranted() async {
        let source = FakeCalendarSource(access: .writeOnly, grants: .writeOnly, events: [event("a", startsIn: 1)])
        let (calendar, _) = makeCalendar(source: source)
        await calendar.refresh()
        #expect(!calendar.isEnabled)
        #expect(source.readCount == 0)
        #expect(calendar.upcoming.isEmpty)
    }

    @Test func theSettingOffHidesEventsEvenWithAccess() async {
        let source = FakeCalendarSource(access: .fullAccess, grants: .fullAccess, events: [event("a", startsIn: 1)])
        let (calendar, toggle) = makeCalendar(source: source, isOn: false)
        await calendar.refresh()
        #expect(calendar.access == .fullAccess)
        #expect(!calendar.isEnabled)
        #expect(source.readCount == 0)
        #expect(calendar.upcoming.isEmpty)
        #expect(calendar.currentEvent(at: now) == nil)

        toggle.isOn = true
        await calendar.refresh()
        #expect(calendar.isEnabled)
        #expect(calendar.currentEvent(at: now)?.id == "a")

        // Switched off again: the cached events are not used, even before the next refresh.
        toggle.isOn = false
        #expect(calendar.currentEvent(at: now) == nil)
    }

    @Test func refreshReadsFifteenMinutesBackToTwelveHoursAheadSortedWithoutAllDayEvents() async {
        let source = FakeCalendarSource(access: .fullAccess, grants: .fullAccess, events: [
            event("later", startsIn: 120),
            event("day", startsIn: -60, lasts: 24 * 60, allDay: true),
            event("soon", startsIn: 5),
        ])
        let (calendar, _) = makeCalendar(source: source)
        await calendar.refresh()
        #expect(source.readCount == 1)
        #expect(source.lastWindow?.from == now.addingTimeInterval(-15 * 60))
        #expect(source.lastWindow?.to == now.addingTimeInterval(12 * 60 * 60))
        #expect(calendar.upcoming.map(\.id) == ["soon", "later"])
        #expect(calendar.refreshedAt == now)
    }

    @Test func calendarChangesRefreshTheEventsWhileStarted() async throws {
        let source = FakeCalendarSource(access: .fullAccess, grants: .fullAccess, events: [event("a", startsIn: 5)])
        let (calendar, _) = makeCalendar(source: source)
        calendar.start()
        defer { calendar.stop() }
        try await waitUntil { calendar.upcoming.map(\.id) == ["a"] }
        #expect(source.readCount == 1)

        source.events = [event("a", startsIn: 5), event("b", startsIn: 30)]
        source.signalChange()
        try await waitUntil { calendar.upcoming.map(\.id) == ["a", "b"] }
        #expect(source.readCount == 2)

        // Starting twice does not add a second loop.
        calendar.start()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.readCount == 2)
    }

    @Test func stopEndsTheRefreshLoop() async throws {
        let source = FakeCalendarSource(access: .fullAccess, grants: .fullAccess, events: [])
        let (calendar, _) = makeCalendar(source: source)
        calendar.start()
        try await waitUntil { source.readCount == 1 }
        calendar.stop()
        source.signalChange()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.readCount == 1)
    }

    @Test func currentEventMatchesLikeTheMatcher() async {
        let source = FakeCalendarSource(access: .fullAccess, grants: .fullAccess, events: [
            event("running", startsIn: -10),
            event("later", startsIn: 60),
        ])
        let (calendar, _) = makeCalendar(source: source)
        await calendar.refresh()
        #expect(calendar.currentEvent(at: now)?.id == "running")
        #expect(calendar.currentEvent(at: now.addingTimeInterval(55 * 60))?.id == "later")
        #expect(calendar.currentEvent(at: now.addingTimeInterval(30 * 60)) == nil)
    }

    @Test func accessMapsEveryEventKitStatus() {
        #expect(CalendarAccess(status: .notDetermined) == .notDetermined)
        #expect(CalendarAccess(status: .fullAccess) == .fullAccess)
        #expect(CalendarAccess(status: .writeOnly) == .writeOnly)
        #expect(CalendarAccess(status: .denied) == .denied)
        #expect(CalendarAccess(status: .restricted) == .restricted)
        #expect(CalendarAccess.fullAccess.isGranted)
        for access in [CalendarAccess.notDetermined, .writeOnly, .denied, .restricted] {
            #expect(!access.isGranted)
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
