import Foundation
import Testing
@testable import Captylo

struct MeetingTranscriptLinesTests {
    private let meetingID = UUID()

    private func segment(_ track: MeetingTrack, _ start: Double, _ end: Double, _ text: String,
                         speaker: String? = nil, echo: Bool = false) -> MeetingSegmentRecord {
        MeetingSegmentRecord(meetingID: meetingID, track: track, start: start, end: end, text: text,
                             speaker: speaker, isEcho: echo)
    }

    private func lines(_ items: [MeetingTranscriptLines.Item]) -> [MeetingTranscriptLines.Line] {
        items.compactMap {
            if case .line(let line) = $0 { return line }
            return nil
        }
    }

    @Test func mergesOneSpeakerWithinTwoSeconds() {
        let first = segment(.me, 0, 3, "Zaczynamy.")
        let second = segment(.me, 4.5, 6, "Najpierw budżet.")
        let third = segment(.me, 8.5, 10, "Potem terminy.")
        let result = lines(MeetingTranscriptLines.items([first, second, third], interruptions: []))
        #expect(result.map(\.text) == ["Zaczynamy. Najpierw budżet.", "Potem terminy."])
        #expect(result[0].id == first.id)
        #expect(result[0].segmentIDs == [first.id, second.id])
        #expect(result[0].start == 0)
        #expect(result[0].end == 6)
    }

    @Test func keepsSpeakersApart() {
        let items = MeetingTranscriptLines.items([
            segment(.them, 0, 2, "Dzień dobry.", speaker: "1"),
            segment(.them, 2.5, 4, "Cześć.", speaker: "2"),
            segment(.me, 4.2, 5, "Witam."),
            segment(.them, 5.5, 7, "Zaczynajmy.", speaker: "1"),
        ], interruptions: [])
        #expect(lines(items).map(\.text) == ["Dzień dobry.", "Cześć.", "Witam.", "Zaczynajmy."])
    }

    @Test func hidesEchoAndMergesAcrossIt() {
        let items = MeetingTranscriptLines.items([
            segment(.them, 0, 2, "Widzicie ekran?"),
            segment(.me, 0.3, 2.1, "Widzicie ekran?", echo: true),
            segment(.them, 3, 4, "Super."),
        ], interruptions: [])
        let result = lines(items)
        #expect(result.count == 1)
        #expect(result.first?.text == "Widzicie ekran? Super.")
        #expect(result.first?.track == .them)
    }

    @Test func placesGapsInTimeAndBreaksTheMerge() {
        let items = MeetingTranscriptLines.items([
            segment(.me, 0, 3, "Przed przerwą."),
            segment(.me, 4, 6, "Po przerwie."),
        ], interruptions: [120, 3.5, 3.5, 0])
        let shape = items.map { item -> String in
            switch item {
            case .line(let line): return line.text
            case .gap(let at): return "gap \(at)"
            }
        }
        #expect(shape == ["gap 0.0", "Przed przerwą.", "gap 3.5", "Po przerwie.", "gap 120.0"])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func sortsLiveSegmentsByTime() {
        let items = MeetingTranscriptLines.items([
            segment(.them, 5, 6, "Druga."),
            segment(.me, 0, 1, "Pierwsza."),
        ], interruptions: [])
        #expect(lines(items).map(\.text) == ["Pierwsza.", "Druga."])
    }

    @Test func speakerTintsAreStablePerLabel() {
        #expect(MeetingTranscriptLines.tintSlot(track: .me, speaker: nil) == nil)
        #expect(MeetingTranscriptLines.tintSlot(track: .them, speaker: nil) == 0)
        #expect(MeetingTranscriptLines.tintSlot(track: .them, speaker: "1") == 0)
        #expect(MeetingTranscriptLines.tintSlot(track: .them, speaker: "2") == 1)
        let count = MeetingTranscriptLines.tintCount
        #expect(MeetingTranscriptLines.tintSlot(track: .them, speaker: "\(count + 1)") == 0)
        #expect(MeetingTranscriptLines.tintSlot(track: .them, speaker: "Anna") != nil)
    }

    /// A search hit jumps to the line that holds its segment, also when it was merged into it.
    @Test func findsTheLineThatHoldsASegment() {
        let first = segment(.me, 0, 3, "Zaczynamy.")
        let merged = segment(.me, 4, 6, "Najpierw budżet.")
        let other = segment(.them, 10, 12, "Dobrze.")
        let echo = segment(.me, 10, 12, "Dobrze.", echo: true)
        let items = MeetingTranscriptLines.items([first, merged, other, echo], interruptions: [8])
        #expect(MeetingTranscriptLines.lineID(containing: merged.id, in: items) == first.id)
        #expect(MeetingTranscriptLines.lineID(containing: first.id, in: items) == first.id)
        #expect(MeetingTranscriptLines.lineID(containing: other.id, in: items) == other.id)
        #expect(MeetingTranscriptLines.lineID(containing: echo.id, in: items) == nil)
        #expect(MeetingTranscriptLines.lineID(containing: UUID(), in: items) == nil)
    }
}
