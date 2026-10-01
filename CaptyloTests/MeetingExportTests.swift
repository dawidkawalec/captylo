import Foundation
import Testing
@testable import Captylo

struct MeetingExportTests {
    private func sample() -> (MeetingRecord, [MeetingSegmentRecord]) {
        let id = UUID()
        var meeting = MeetingRecord(id: id, createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "Budżet Q4", status: .completed, duration: 125)
        meeting.notes = "budżet reklam"
        meeting.noteLines = [MeetingNoteLine(text: "budżet reklam", at: 12)]
        meeting.summary = "## Podsumowanie\n- 20 tys. na reklamy [1:05]"
        meeting.summaryTemplateID = "general"
        meeting.summaryModel = "model-x"
        meeting.speakerNames = ["1": "Anna"]
        meeting.interruptions = [30]
        let segments = [
            MeetingSegmentRecord(meetingID: id, track: .me, start: 61, end: 64, text: "Ile mamy na reklamy?",
                                 words: [MeetingWord(text: "Ile", start: 61, end: 61.4)]),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 65, end: 70, text: "Dwadzieścia tysięcy.", speaker: "1"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 66, end: 69, text: "ukryte echo", isEcho: true),
        ]
        return (meeting, segments)
    }

    @Test func markdownHasNotesAINotesAndTranscriptWithoutEcho() {
        let (meeting, segments) = sample()
        let md = MeetingExport.markdown(meeting, segments: segments)
        #expect(md.hasPrefix("# Budżet Q4"))
        #expect(md.contains("budżet reklam"))
        #expect(md.contains("20 tys. na reklamy"))
        #expect(md.contains("**[1:01] \(MeetingTrack.me.defaultLabel):** Ile mamy na reklamy?"))
        #expect(md.contains("**[1:05] Anna:** Dwadzieścia tysięcy."))
        #expect(!md.contains("ukryte echo"))
    }

    @Test func markdownNestsAIHeadingsAndOrdersTheTranscript() throws {
        let (meeting, segments) = sample()
        let md = MeetingExport.markdown(meeting, segments: segments.reversed())
        // The AI notes sit under their own "##" heading, so theirs move one level down.
        #expect(md.contains("\n### Podsumowanie\n"))
        #expect(!md.contains("\n## Podsumowanie"))
        let mine = try #require(md.range(of: "Ile mamy na reklamy?"))
        let theirs = try #require(md.range(of: "Dwadzieścia tysięcy."))
        #expect(mine.lowerBound < theirs.lowerBound)
    }

    @Test func markdownSkipsEmptySections() {
        let meeting = MeetingRecord(title: "Pusta rozmowa", status: .completed, duration: 3)
        let echoOnly = [MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 1, text: "echo", isEcho: true)]
        let md = MeetingExport.markdown(meeting, segments: echoOnly)
        #expect(md.hasPrefix("# Pusta rozmowa\n\n"))
        #expect(!md.contains("## "))
        #expect(md.hasSuffix("\n"))
    }

    @Test func demotedLeavesCodeBlocksAndPlainTextAlone() {
        let source = "# Tytuł\n## Sekcja\ntekst #nie\n```\n# komentarz\n```\n###### Najniżej"
        let expected = "## Tytuł\n### Sekcja\ntekst #nie\n```\n# komentarz\n```\n###### Najniżej"
        #expect(MeetingExport.demoted(source) == expected)
    }

    @Test func jsonIsVersionedAndRoundTripsSegments() throws {
        let (meeting, segments) = sample()
        let data = try MeetingExport.json(meeting, segments: segments)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "captylo.meeting.v1")
        #expect((object["segments"] as? [[String: Any]])?.count == 3)
        #expect(object["id"] as? String == meeting.id.uuidString)
        #expect(object["status"] as? String == "completed")
        let ai = try #require(object["ai"] as? [String: Any])
        #expect(ai["templateID"] as? String == "general")
        #expect(ai["model"] as? String == "model-x")
        let tracks = try #require(object["tracks"] as? [[String: Any]])
        #expect(tracks.compactMap { $0["file"] as? String } == ["me.caf", "them.caf"])

        struct Readback: Decodable {
            let segments: [MeetingSegmentRecord]
            let noteLines: [MeetingNoteLine]
            let createdAt: Date
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let readback = try decoder.decode(Readback.self, from: data)
        #expect(readback.segments == segments.sorted { $0.start < $1.start })
        #expect(readback.noteLines == meeting.noteLines)
        #expect(readback.createdAt == meeting.createdAt)
    }

    @Test func jsonLeavesOutAIWhenThereAreNoNotes() throws {
        var meeting = MeetingRecord(title: "Bez AI", status: .completed)
        meeting.hasAudio = false
        let data = try MeetingExport.json(meeting, segments: [])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ai"] == nil)
        #expect(object["hasAudio"] as? Bool == false)
        #expect((object["segments"] as? [Any])?.isEmpty == true)
    }

    @Test func noteLinesKeepTimesOfUnchangedLines() {
        let first = NoteLines.update([], text: "budżet\n", now: 10)
        #expect(first.map(\.text) == ["budżet"])
        #expect(first.map(\.at) == [10])
        let second = NoteLines.update(first, text: "budżet\nterminy\n\n", now: 42)
        #expect(second.map(\.text) == ["budżet", "terminy"])
        #expect(second.map(\.at) == [10, 42])
        #expect(second.first?.id == first.first?.id)
        let edited = NoteLines.update(second, text: "budżet Q4\nterminy", now: 50)
        #expect(edited.map(\.at) == [50, 42])
    }

    @Test func noteLinesSplitWindowsLineEndingsAndMatchRepeatsOnce() {
        let first = NoteLines.update([], text: "  tak \r\ntak\r\n", now: 5)
        #expect(first.map(\.text) == ["tak", "tak"])
        #expect(Set(first.map(\.id)).count == 2)
        let second = NoteLines.update(first, text: "tak\ntak\ntak", now: 9)
        #expect(second.map(\.at) == [5, 5, 9])
        #expect(second.prefix(2).map(\.id) == first.map(\.id))
    }

    @Test func fileNamesAreSafeForTheSavePanel() {
        #expect(MeetingExport.fileName(title: "Spotkanie w Zoom, 30 września 14:00", fileExtension: "md")
            == "Spotkanie w Zoom, 30 września 14-00.md")
        #expect(MeetingExport.fileName(title: "Plan/budżet\nQ4", fileExtension: "json") == "Plan-budżet-Q4.json")
        #expect(MeetingExport.fileName(title: "..ukryty ", fileExtension: "md") == "ukryty.md")
        #expect(MeetingExport.fileName(title: "  ", fileExtension: "md") == "\(String(localized: "Spotkanie")).md")
        let long = MeetingExport.fileName(title: String(repeating: "a", count: 200), fileExtension: "md")
        #expect(long == String(repeating: "a", count: MeetingExport.maxNameLength) + ".md")
    }

    /// "Skopiuj informację" on the consent card: one Polish and one English sentence, whatever
    /// the UI language, so it works in any call.
    @Test func consentDisclosureNamesCaptyloInPolishAndEnglish() {
        let text = MeetingConsent.disclosure
        #expect(text.contains("Captylo"))
        #expect(text.contains("nagranie zostaje na moim komputerze"))
        #expect(text.contains("the recording stays on my computer"))
        #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
    }
}
