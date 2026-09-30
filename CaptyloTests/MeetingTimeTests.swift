import Testing
@testable import Captylo

struct MeetingTimeTests {
    @Test func clockUsesHoursOnlyWhenNeeded() {
        #expect(MeetingTime.clock(0) == "0:00")
        #expect(MeetingTime.clock(59.9) == "0:59")
        #expect(MeetingTime.clock(754) == "12:34")
        #expect(MeetingTime.clock(3723) == "1:02:03")
        #expect(MeetingTime.clock(7200) == "2:00:00")
    }

    @Test func stampIsTheBracketedClock() {
        #expect(MeetingTime.stamp(754) == "[12:34]")
        #expect(MeetingTime.stamp(3723) == "[1:02:03]")
    }

    @Test func negativeAndNonFiniteValuesClampToZero() {
        #expect(MeetingTime.clock(-3) == "0:00")
        #expect(MeetingTime.clock(.nan) == "0:00")
        #expect(MeetingTime.clock(.infinity) == "0:00")
    }
}
