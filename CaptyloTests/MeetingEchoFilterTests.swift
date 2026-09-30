import Foundation
import Testing
@testable import Captylo

struct MeetingEchoFilterTests {
    private let id = UUID()
    private func seg(_ track: MeetingTrack, _ start: Double, _ end: Double, _ text: String) -> MeetingSegmentRecord {
        MeetingSegmentRecord(meetingID: id, track: track, start: start, end: end, text: text)
    }

    @Test func micCopyOfTheSystemTrackIsEcho() {
        let them = seg(.them, 10, 14, "Wdrożenie przesuwamy na piątek, bo testy nie przeszły.")
        let me = seg(.me, 10.3, 14.2, "wdrożenie przesuwamy na piątek bo testy nie")
        #expect(EchoFilter.isEcho(me, against: [them]))
    }

    @Test func differentSentenceAtTheSameTimeIsNotEcho() {
        let them = seg(.them, 10, 14, "Wdrożenie przesuwamy na piątek.")
        let me = seg(.me, 11, 13, "A co z budżetem na reklamy w listopadzie?")
        #expect(!EchoFilter.isEcho(me, against: [them]))
    }

    @Test func shortRealRepliesSurvive() {
        let them = seg(.them, 10, 12, "Tak, dokładnie tak.")
        let me = seg(.me, 11, 11.5, "Tak")
        #expect(!EchoFilter.isEcho(me, against: [them]))
    }

    @Test func repeatedShortReplySurvives() {
        let them = seg(.them, 10, 12, "Tak, dokładnie tak.")
        let me = seg(.me, 11, 12, "Tak, tak, tak.")
        #expect(!EchoFilter.isEcho(me, against: [them]))
    }

    @Test func sameWordsFarApartInTimeAreNotEcho() {
        let them = seg(.them, 100, 104, "Wdrożenie przesuwamy na piątek.")
        let me = seg(.me, 10, 14, "Wdrożenie przesuwamy na piątek.")
        #expect(!EchoFilter.isEcho(me, against: [them]))
    }

    @Test func markReturnsOnlyChangedMicSegments() {
        let them = seg(.them, 10, 14, "Wdrożenie przesuwamy na piątek, bo testy nie przeszły.")
        let echo = seg(.me, 10.2, 14, "wdrożenie przesuwamy na piątek bo testy")
        let real = seg(.me, 20, 22, "Dobra, to ja napiszę do klienta.")
        let changed = EchoFilter.mark([them, echo, real])
        #expect(changed.map(\.id) == [echo.id])
        #expect(changed.first?.isEcho == true)
    }

    @Test func markClearsAnEchoFlagThatNoLongerHolds() {
        let them = seg(.them, 10, 14, "Wdrożenie przesuwamy na piątek.")
        var stale = seg(.me, 20, 22, "Dobra, to ja napiszę do klienta.")
        stale.isEcho = true
        let changed = EchoFilter.mark([them, stale])
        #expect(changed.map(\.id) == [stale.id])
        #expect(changed.first?.isEcho == false)
    }
}
