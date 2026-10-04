import Foundation
import Testing
@testable import Captylo

struct MeetingCalendarMatcherTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(
        _ id: String,
        startsIn minutes: Double,
        lasts length: Double = 30,
        callApp: String? = nil,
        allDay: Bool = false
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(
            id: id,
            title: "Wydarzenie \(id)",
            start: start,
            end: start.addingTimeInterval(length * 60),
            isAllDay: allDay,
            calendarTitle: "Praca",
            participants: [],
            callApp: callApp
        )
    }

    @Test func anEventInProgressWinsOverAnUpcomingOne() {
        let running = event("running", startsIn: -20)
        let soon = event("soon", startsIn: 5)
        #expect(CalendarEventMatcher.match([soon, running], at: now)?.id == "running")
        #expect(CalendarEventMatcher.match([soon], at: now)?.id == "soon")
    }

    @Test func aCallLinkWinsOverTiming() {
        let running = event("running", startsIn: -20)
        let soonWithLink = event("soon", startsIn: 5, callApp: "Meet")
        #expect(CalendarEventMatcher.match([running, soonWithLink], at: now)?.id == "soon")
        let runningWithLink = event("running-link", startsIn: -25, callApp: "Zoom")
        #expect(CalendarEventMatcher.match([running, soonWithLink, runningWithLink], at: now)?.id == "running-link")
    }

    @Test func nothingBeyondTenMinutesAheadOrFiveMinutesAfterTheEnd() {
        #expect(CalendarEventMatcher.match([event("later", startsIn: 11)], at: now) == nil)
        #expect(CalendarEventMatcher.match([event("edge", startsIn: 10)], at: now)?.id == "edge")
        // Ended 6 min ago: over. Ended 4 min ago: still counts (the call ran over).
        #expect(CalendarEventMatcher.match([event("over", startsIn: -36, lasts: 30)], at: now) == nil)
        #expect(CalendarEventMatcher.match([event("overrun", startsIn: -34, lasts: 30)], at: now)?.id == "overrun")
        #expect(CalendarEventMatcher.match([], at: now) == nil)
    }

    @Test func allDayEventsNeverMatch() {
        let allDay = event("day", startsIn: -120, lasts: 24 * 60, allDay: true)
        #expect(CalendarEventMatcher.match([allDay], at: now) == nil)
        let allDayWithLink = event("day-link", startsIn: -120, lasts: 24 * 60, callApp: "Zoom", allDay: true)
        let plain = event("plain", startsIn: 3)
        #expect(CalendarEventMatcher.match([allDayWithLink, plain], at: now)?.id == "plain")
    }

    @Test func tieBreaksAreDeterministic() {
        // Two events in progress: the one that started most recently.
        let early = event("early", startsIn: -40, lasts: 60)
        let late = event("late", startsIn: -10, lasts: 60)
        #expect(CalendarEventMatcher.match([early, late], at: now)?.id == "late")
        #expect(CalendarEventMatcher.match([late, early], at: now)?.id == "late")
        // Same start: the shorter one.
        let long = event("long", startsIn: -10, lasts: 120)
        let short = event("short", startsIn: -10, lasts: 30)
        #expect(CalendarEventMatcher.match([long, short], at: now)?.id == "short")
        #expect(CalendarEventMatcher.match([short, long], at: now)?.id == "short")
        // Two upcoming events: the one that starts first.
        let inTwo = event("two", startsIn: 2)
        let inEight = event("eight", startsIn: 8)
        #expect(CalendarEventMatcher.match([inEight, inTwo], at: now)?.id == "two")
        // Identical timing: the id decides, whatever the order.
        let a = event("a", startsIn: -5)
        let b = event("b", startsIn: -5)
        #expect(CalendarEventMatcher.match([b, a], at: now)?.id == "a")
        #expect(CalendarEventMatcher.match([a, b], at: now)?.id == "a")
    }

    @Test func hasCallLinkFollowsTheApp() {
        #expect(event("x", startsIn: 0, callApp: "Zoom").hasCallLink)
        #expect(!event("y", startsIn: 0).hasCallLink)
    }
}
