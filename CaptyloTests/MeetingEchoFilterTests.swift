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

    /// Words of `text` one every 0.4 s from `start` (what a pass stores, in meeting time).
    private func timed(_ track: MeetingTrack, _ start: Double, _ text: String) -> MeetingSegmentRecord {
        let parts = text.split(separator: " ").map(String.init)
        let words = parts.enumerated().map { index, word in
            MeetingWord(text: word, start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.3)
        }
        var record = seg(track, start, start + Double(parts.count) * 0.4, text)
        record.words = words
        return record
    }

    /// The owner's meeting: "Ja" said his sentence and the mic then caught hers from the speakers.
    @Test func echoRunIsCutFromAMixedMicSegment() {
        let them = timed(.them, 14, "Tylko musiałaby pani podesłać jakieś swoje zdjęcia.")
        let me = timed(.me, 10, "Robiliśmy już parę rzeczy takich, one fajnie wyglądały, więc możemy pójść. Tylko musiałaby pani podesłać jakieś swoje zdjęcia.")
        let changed = EchoFilter.mark([them, me])
        #expect(changed.count == 1)
        #expect(changed.first?.isEcho == false)
        #expect(changed.first?.text == "Robiliśmy już parę rzeczy takich, one fajnie wyglądały, więc możemy pójść.")
        #expect(changed.first?.words.count == 11)
    }

    @Test func shortRepeatOfTheOtherSideStays() {
        let them = timed(.them, 10, "Coś niebieskiego, ale przytłumiony, przygaszony.")
        let me = timed(.me, 11, "No właśnie przytłumiony, przygaszony, taki morski kolor.")
        #expect(EchoFilter.mark([them, me]).isEmpty)
    }

    @Test func sameRunFarApartInTimeStays() {
        let them = timed(.them, 100, "Tylko musiałaby pani podesłać jakieś swoje zdjęcia.")
        let me = timed(.me, 10, "Dobra. Tylko musiałaby pani podesłać jakieś swoje zdjęcia, prawda?")
        #expect(EchoFilter.mark([them, me]).isEmpty)
    }

    @Test func segmentsWithoutWordTimesAreOnlyFlagged() {
        let them = seg(.them, 14, 18, "Tylko musiałaby pani podesłać jakieś swoje zdjęcia.")
        let me = seg(.me, 10, 18, "Robiliśmy już parę rzeczy takich, one fajnie wyglądały. Tylko musiałaby pani podesłać jakieś swoje zdjęcia.")
        #expect(EchoFilter.mark([them, me]).isEmpty)
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
