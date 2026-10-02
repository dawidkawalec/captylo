import Foundation
import Testing
@testable import Captylo

/// The Spotkania list search over the index: which path a query takes, how hits become rows
/// (best rank first, then newest) and the hit lines under each row.
struct MeetingSearchResultsTests {
    private static func hit(
        _ meeting: UUID, _ kind: SearchHit.Kind, rank: Double, segment: UUID? = nil, start: Double = 0
    ) -> SearchHit {
        SearchHit(meetingID: meeting, segmentID: segment, kind: kind, start: start,
                  track: kind == .segment ? .them : nil, rank: rank)
    }

    // MARK: Which path

    @Test func shortQueriesKeepTheOldSearch() {
        #expect(MeetingSearchResults.indexTerms(for: "") == nil)
        #expect(MeetingSearchResults.indexTerms(for: "of") == nil)
        #expect(MeetingSearchResults.indexTerms(for: "  ab  ") == nil)
        #expect(MeetingSearchResults.indexTerms(for: "ab cd") == nil)
        #expect(MeetingSearchResults.indexTerms(for: "oferta") == ["ofert"])
        #expect(MeetingSearchResults.indexTerms(for: "ab oferta") == ["ofert"])
        #expect(MeetingSearchResults.indexTerms(for: "Łódź") == ["lodz"])
    }

    // MARK: Grouping and order

    @Test func hitsGroupPerMeetingBestFirst() {
        let first = UUID()
        let second = UUID()
        let early = UUID()
        let late = UUID()
        let weak = UUID()
        let hits = [
            Self.hit(second, .title, rank: -8),
            Self.hit(first, .segment, rank: -5, segment: late, start: 600),
            Self.hit(first, .segment, rank: -4, segment: early, start: 30),
            Self.hit(first, .segment, rank: -3, segment: weak, start: 10),
            Self.hit(first, .notes, rank: -2),
        ]
        let matches = MeetingSearchResults.group(hits)
        #expect(matches.map(\.meetingID) == [second, first])
        #expect(matches[0].titleMatched && !matches[0].notesMatched)
        #expect(matches[0].segmentHits.isEmpty)
        #expect(matches[0].bestRank == -8)
        #expect(matches[1].bestRank == -5)
        #expect(matches[1].notesMatched && !matches[1].titleMatched)
        // The two best segment hits, shown in time order.
        #expect(matches[1].segmentHits.map(\.segmentID) == [early, late])
    }

    @Test func rowsFollowTheRankThenTheNewest() throws {
        let now = Date()
        let old = MeetingRecord(createdAt: now.addingTimeInterval(-7200), title: "Stare")
        let new = MeetingRecord(createdAt: now, title: "Nowe")
        let best = MeetingRecord(createdAt: now.addingTimeInterval(-86_400), title: "Najlepsze")
        let gone = UUID()
        let matches = MeetingSearchResults.group([
            Self.hit(best.id, .title, rank: -9),
            Self.hit(gone, .title, rank: -7),
            Self.hit(old.id, .segment, rank: -5, segment: UUID()),
            Self.hit(new.id, .segment, rank: -5, segment: UUID()),
        ])
        // The store returns rows in any order; a meeting deleted meanwhile is left out.
        let ordered = MeetingSearchResults.ordered(matches, meetings: [old, new, best], limit: 10)
        #expect(ordered.map(\.id) == [best.id, new.id, old.id])
        #expect(MeetingSearchResults.ordered(matches, meetings: [old, new, best], limit: 2).map(\.id) == [best.id, new.id])
    }

    // MARK: Hit lines

    @Test func hitLinesShowTheSpeakerAndTheSnippet() throws {
        var meeting = MeetingRecord(title: "Budżet")
        meeting.speakerNames = ["1": "Anna"]
        meeting.notes = "wysłać ofertę w piątek"
        let anna = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 754, end: 760,
                                        text: "Wyślę ofertę jutro rano", speaker: "1")
        let mine = MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 30, end: 33,
                                        text: "A co z ofertą?")
        let segments = [anna.id: anna, mine.id: mine]

        let both = MeetingSearchMatch(meetingID: meeting.id, bestRank: -5, segmentHits: [
            Self.hit(meeting.id, .segment, rank: -4, segment: mine.id, start: 30),
            Self.hit(meeting.id, .segment, rank: -5, segment: anna.id, start: 754),
        ], titleMatched: false, notesMatched: true)
        let lines = MeetingSearchResults.lines(for: both, meeting: meeting, segments: segments, terms: ["ofert"])
        #expect(lines.map(\.label) == [MeetingTrack.me.defaultLabel, "Anna"])
        #expect(lines.map(\.source) == [.segment(mine.id, start: 30), .segment(anna.id, start: 754)])
        #expect(lines[1].snippet.text == "Wyślę ofertę jutro rano")
        #expect(!lines[1].snippet.matches.isEmpty)

        // One segment hit leaves room for the notes.
        let one = MeetingSearchMatch(meetingID: meeting.id, bestRank: -5, segmentHits: [
            Self.hit(meeting.id, .segment, rank: -5, segment: anna.id, start: 754),
        ], titleMatched: false, notesMatched: true)
        let withNotes = MeetingSearchResults.lines(for: one, meeting: meeting, segments: segments, terms: ["ofert"])
        #expect(withNotes.map(\.source) == [.segment(anna.id, start: 754), .notes])
        #expect(withNotes[1].snippet.text == "wysłać ofertę w piątek")

        // A segment deleted meanwhile has no line; a title hit adds none.
        let stale = MeetingSearchMatch(meetingID: meeting.id, bestRank: -5, segmentHits: [
            Self.hit(meeting.id, .segment, rank: -5, segment: UUID(), start: 1),
        ], titleMatched: true, notesMatched: false)
        #expect(MeetingSearchResults.lines(for: stale, meeting: meeting, segments: segments, terms: ["ofert"]).isEmpty)
    }

    // MARK: Count

    @Test func theCountFollowsPolishForms() {
        #expect(MeetingSearchResults.countText(1) == "1 spotkanie")
        #expect(MeetingSearchResults.countText(2) == "2 spotkania")
        #expect(MeetingSearchResults.countText(4) == "4 spotkania")
        #expect(MeetingSearchResults.countText(5) == "5 spotkań")
        #expect(MeetingSearchResults.countText(12) == "12 spotkań")
        #expect(MeetingSearchResults.countText(22) == "22 spotkania")
        #expect(MeetingSearchResults.countText(0) == "0 spotkań")
    }

    // MARK: Load

    private static func fixture() throws -> (index: MeetingSearchIndex, db: Database) {
        let index = MeetingSearchIndex(url: nil)
        return (index, Database(modelContainer: try Store.makeInMemoryContainer(), searchIndex: index))
    }

    @Test func loadUsesTheIndexAndBuildsHitLines() async throws {
        let (index, db) = try Self.fixture()
        let now = Date()
        let sales = MeetingRecord(createdAt: now.addingTimeInterval(-3600), title: "Sprzedaż")
        let other = MeetingRecord(createdAt: now, title: "Standup")
        try await db.createMeeting(sales)
        try await db.createMeeting(other)
        let send = MeetingSegmentRecord(meetingID: sales.id, track: .them, start: 754, end: 760, text: "Wyślę ofertę jutro rano")
        try await db.appendSegment(send)
        try await db.appendSegment(MeetingSegmentRecord(meetingID: other.id, track: .me, start: 1, end: 2, text: "Nic ciekawego"))

        let loaded = try #require(try await MeetingSearchResults.load(query: "oferta", index: index, database: db, limit: 200))
        #expect(loaded.meetings.map(\.id) == [sales.id])
        let lines = try #require(loaded.lines[sales.id])
        #expect(lines.map(\.source) == [.segment(send.id, start: 754)])
        #expect(lines.first?.snippet.text == "Wyślę ofertę jutro rano")

        let none = try #require(try await MeetingSearchResults.load(query: "harmonogram", index: index, database: db, limit: 200))
        #expect(none.meetings.isEmpty)
    }

    @Test func loadFallsBackForShortQueriesAndAnIndexNotReady() async throws {
        let (index, db) = try Self.fixture()
        try await db.createMeeting(MeetingRecord(title: "Oferta"))
        #expect(try await MeetingSearchResults.load(query: "of", index: index, database: db, limit: 200) == nil)

        // A file index is not ready until it was checked against the store.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "captylo-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileIndex = MeetingSearchIndex(url: directory.appending(path: MeetingSearchIndex.fileName))
        #expect(try await MeetingSearchResults.load(query: "oferta", index: fileIndex, database: db, limit: 200) == nil)
    }
}
