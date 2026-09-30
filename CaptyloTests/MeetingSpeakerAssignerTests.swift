import Foundation
import Testing
@testable import Captylo

struct MeetingSpeakerAssignerTests {
    private let id = UUID()
    private func seg(_ start: Double, _ end: Double, track: MeetingTrack = .them) -> MeetingSegmentRecord {
        MeetingSegmentRecord(meetingID: id, track: track, start: start, end: end, text: "x")
    }

    @Test func mostOverlapWinsAndLabelsFollowFirstAppearance() {
        let segments = [seg(0, 4), seg(5, 9), seg(10, 12), seg(1, 2, track: .me)]
        let turns = [SpeakerTurn(speaker: "S7", start: 0, end: 4.5), SpeakerTurn(speaker: "S2", start: 4.5, end: 9.5), SpeakerTurn(speaker: "S7", start: 9.5, end: 13)]
        let labeled = SpeakerAssigner.assign(segments, turns: turns)
        #expect(labeled.map(\.speaker) == ["1", "2", "1"])
        #expect(labeled.allSatisfy { $0.track == .them })
    }

    @Test func segmentInAGapTakesTheNearestTurnWithinASecond() {
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 6, end: 8)]
        let labeled = SpeakerAssigner.assign([seg(0, 1), seg(2.5, 2.9), seg(6, 7)], turns: turns)
        #expect(labeled.map(\.speaker) == ["1", "1", "2"])
    }

    @Test func oneRemoteSpeakerMeansNoLabels() {
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 20)]
        #expect(SpeakerAssigner.assign([seg(0, 4), seg(5, 9)], turns: turns).isEmpty)
    }

    @Test func echoSegmentsAreIgnored() {
        var echo = seg(0, 4)
        echo.isEcho = true
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 4), SpeakerTurn(speaker: "B", start: 5, end: 9)]
        #expect(SpeakerAssigner.assign([echo, seg(5, 9)], turns: turns).map(\.speaker) == ["1"])
    }

    @Test func segmentFarFromEveryTurnKeepsTheTrackLabel() {
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 10, end: 12)]
        let far = seg(5, 6)
        let labeled = SpeakerAssigner.assign([seg(0, 2), far, seg(10, 12)], turns: turns)
        #expect(labeled.map(\.speaker) == ["1", "2"])
        #expect(!labeled.map(\.id).contains(far.id))
    }

    @Test func unsortedSegmentsAreNumberedInTimeOrder() {
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 4), SpeakerTurn(speaker: "B", start: 5, end: 9)]
        let labeled = SpeakerAssigner.assign([seg(5, 9), seg(0, 4)], turns: turns)
        #expect(labeled.map(\.start) == [0, 5])
        #expect(labeled.map(\.speaker) == ["1", "2"])
    }
}
