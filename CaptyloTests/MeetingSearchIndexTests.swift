import Foundation
import Testing
@testable import Captylo

/// The FTS5 index in memory (and on temp files for the launch checks), kept in step by `Database`.
struct MeetingSearchIndexTests {
    private static func fixture() throws -> (index: MeetingSearchIndex, db: Database) {
        let index = MeetingSearchIndex(url: nil)
        return (index, Database(modelContainer: try Store.makeInMemoryContainer(), searchIndex: index))
    }

    private static func segment(
        _ meeting: MeetingRecord, _ text: String, start: Double = 0, track: MeetingTrack = .them
    ) -> MeetingSegmentRecord {
        MeetingSegmentRecord(meetingID: meeting.id, track: track, start: start, end: start + 2, text: text)
    }

    private static func segmentIDs(_ index: MeetingSearchIndex, _ query: String) async throws -> Set<UUID> {
        Set(try #require(await index.search(query, limit: 100)).compactMap(\.segmentID))
    }

    /// Everything a search returns except the rank, for comparing two builds.
    private static func keys(_ index: MeetingSearchIndex, _ query: String) async throws -> Set<String> {
        Set(try #require(await index.search(query, limit: 500)).map {
            "\($0.meetingID) \($0.segmentID?.uuidString ?? "-") \($0.kind.rawValue) \($0.start) \($0.track?.rawValue ?? "-")"
        })
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "captylo-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Polish

    @Test func polishInflectionAndLettersMatch() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie zespołu")
        try await db.createMeeting(meeting)
        let send = Self.segment(meeting, "Wyślę ofertę jutro", start: 1)
        let none = Self.segment(meeting, "Nie mamy jeszcze ofert", start: 2)
        let agree = Self.segment(meeting, "Zgadzam się z tą ofertą", start: 3)
        let board = Self.segment(meeting, "Zarząd zdecyduje w piątek", start: 4)
        let city = Self.segment(meeting, "Jutro jadę do Łódź Fabryczna", start: 5)
        let other = Self.segment(meeting, "Coś zupełnie innego", start: 6)
        for segment in [send, none, agree, board, city, other] {
            try await db.appendSegment(segment)
        }
        #expect(try await Self.segmentIDs(index, "oferta") == [send.id, none.id, agree.id])
        #expect(try await Self.segmentIDs(index, "zarzad") == [board.id])
        #expect(try await Self.segmentIDs(index, "lodz") == [city.id])
        #expect(try await Self.segmentIDs(index, "ŁÓDŹ") == [city.id])
    }

    @Test func everyWordMustMatchTheSameEntry() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Sprzedaż")
        try await db.createMeeting(meeting)
        let both = Self.segment(meeting, "Wyślę ofertę jutro rano", start: 1)
        let one = Self.segment(meeting, "Oferta jest gotowa", start: 2)
        try await db.appendSegment(both)
        try await db.appendSegment(one)
        #expect(try await Self.segmentIDs(index, "oferta jutro") == [both.id])
        #expect(try await Self.segmentIDs(index, "oferta") == [both.id, one.id])
    }

    @Test func aHitCarriesItsPlaceInTheMeeting() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        let mine = Self.segment(meeting, "Przygotuję harmonogram", start: 754.5, track: .me)
        try await db.appendSegment(mine)
        let hit = try #require(await index.search("harmonogram", limit: 10)?.first)
        #expect(hit.meetingID == meeting.id)
        #expect(hit.segmentID == mine.id)
        #expect(hit.kind == .segment)
        #expect(hit.start == 754.5)
        #expect(hit.track == .me)
    }

    @Test func shortQueriesAreLeftToTheFallback() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "OK")
        try await db.createMeeting(meeting)
        #expect(await index.search("ok", limit: 10) == nil)
        #expect(await index.search("a b", limit: 10) == nil)
        #expect(await index.search("", limit: 10) == nil)
    }

    @Test func quotesAndOperatorsDoNotBreakTheQuery() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        let offer = Self.segment(meeting, "Wyślę ofertę", start: 1)
        try await db.appendSegment(offer)
        #expect(await index.search("\"a\" OR b*", limit: 10) == nil)
        #expect(try await Self.segmentIDs(index, "oferta\" OR \"x") == [offer.id])
        #expect(try await Self.segmentIDs(index, "NEAR(oferta*") == [])
        #expect(try await Self.segmentIDs(index, "oferta) OR (") == [offer.id])
        // A 3-letter operator is just a word: no entry has "and" next to "ofert".
        #expect(try await Self.segmentIDs(index, "oferta AND") == [])
        #expect(try await Self.segmentIDs(index, "-oferta ^") == [offer.id])
    }

    @Test func aTitleHitRanksAboveASegmentHitOfAnotherMeeting() async throws {
        let (index, db) = try Self.fixture()
        let titled = MeetingRecord(title: "Budżet roczny")
        let spoken = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(spoken)
        try await db.createMeeting(titled)
        try await db.appendSegment(Self.segment(spoken, "budżet roczny"))
        let hits = try #require(await index.search("budżet", limit: 10))
        #expect(hits.count == 2)
        #expect(hits.first?.meetingID == titled.id)
        #expect(hits.first?.kind == .title)
        #expect(hits.first?.segmentID == nil)
        #expect(hits.map(\.rank) == hits.map(\.rank).sorted())
    }

    /// Grouped per meeting in SQL: every matching meeting is there however many hits another
    /// one has, each with at most its best segment hits plus its title and notes hits, meetings
    /// in the order of their best hit.
    @Test func meetingHitsKeepEveryMeetingAndCapItsSegments() async throws {
        let (index, db) = try Self.fixture()
        var busy = MeetingRecord(title: "Klient premium")
        busy.notes = "zadzwonić do klienta"
        try await db.createMeeting(busy)
        try await db.replaceSegments(meetingID: busy.id, track: .them, with: (0..<400).map { line in
            Self.segment(busy, "klient klient klient", start: Double(line))
        })
        let quiet = MeetingRecord(title: "Standup")
        try await db.createMeeting(quiet)
        try await db.appendSegment(Self.segment(quiet, "Omawialiśmy plan wdrożenia, testy, terminy i jednego klienta", start: 50))

        // The flat search reads 300 entries: all of the busy meeting.
        let flat = try #require(await index.search("klient", limit: 300))
        #expect(!flat.contains { $0.meetingID == quiet.id })

        let hits = try #require(await index.meetingHits(terms: ["klien"], all: true, meetings: 10, segmentsPerMeeting: 2))
        let meetings = hits.map(\.meetingID).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        #expect(meetings == [busy.id, quiet.id])
        let busyHits = hits.filter { $0.meetingID == busy.id }
        #expect(busyHits.filter { $0.kind == .segment }.count == 2)
        #expect(busyHits.filter { $0.kind == .title }.count == 1)
        #expect(busyHits.filter { $0.kind == .notes }.count == 1)
        #expect(hits.filter { $0.meetingID == quiet.id }.map(\.kind) == [.segment])

        let first = try #require(await index.meetingHits(terms: ["klien"], all: true, meetings: 1, segmentsPerMeeting: 2))
        #expect(Set(first.map(\.meetingID)) == [busy.id])
        #expect(await index.meetingHits(terms: [], all: true, meetings: 10, segmentsPerMeeting: 2) == nil)

        // Limited to some meetings (a period of "Zapytaj wszystkie").
        let within = try #require(await index.meetingHits(terms: ["klien"], all: true, meetings: 1, segmentsPerMeeting: 2, within: [quiet.id]))
        #expect(within.map(\.meetingID) == [quiet.id])
        #expect(await index.meetingHits(terms: ["klien"], all: true, meetings: 10, segmentsPerMeeting: 2, within: []) == [])
        // The unbound filter of a cached statement is NULL again: all meetings.
        let again = try #require(await index.meetingHits(terms: ["klien"], all: true, meetings: 10, segmentsPerMeeting: 2))
        #expect(Set(again.map(\.meetingID)) == [busy.id, quiet.id])
    }

    // MARK: Sync with the store

    @Test func echoIsNeverIndexedAndLeavesWhenMarked() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        var echo = Self.segment(meeting, "oferta z głośnika", start: 1, track: .me)
        echo.isEcho = true
        var live = Self.segment(meeting, "oferta na żywo", start: 2, track: .me)
        try await db.appendSegment(echo)
        try await db.appendSegment(live)
        #expect(try await Self.segmentIDs(index, "oferta") == [live.id])

        live.isEcho = true
        try await db.updateSegments([live])
        #expect(try await Self.segmentIDs(index, "oferta") == [])

        live.isEcho = false
        try await db.updateSegments([live])
        #expect(try await Self.segmentIDs(index, "oferta") == [live.id])
    }

    @Test func aiFixAndRestoreFollowTheText() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        var line = Self.segment(meeting, "kupimy kserokopiarke", start: 1)
        try await db.appendSegment(line)
        line.originalText = line.text
        line.text = "kupimy drukarkę"
        try await db.updateSegments([line])
        #expect(try await Self.segmentIDs(index, "drukarka") == [line.id])
        #expect(try await Self.segmentIDs(index, "kserokopiarka") == [])

        #expect(try await db.restoreOriginalTranscript(meetingID: meeting.id) == 1)
        #expect(try await Self.segmentIDs(index, "kserokopiarka") == [line.id])
        #expect(try await Self.segmentIDs(index, "drukarka") == [])
    }

    @Test func speakerLabelsAloneDoNotTouchTheIndex() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        var line = Self.segment(meeting, "omówimy harmonogram", start: 1)
        try await db.appendSegment(line)
        line.speaker = "2"
        try await db.updateSegments([line])
        #expect(try await Self.segmentIDs(index, "harmonogram") == [line.id])
    }

    @Test func theCloudTranscriptReplacesOneTrack() async throws {
        let (index, db) = try Self.fixture()
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        let mine = Self.segment(meeting, "moja oferta", start: 1, track: .me)
        let theirs = Self.segment(meeting, "stara oferta", start: 2, track: .them)
        try await db.appendSegment(mine)
        try await db.appendSegment(theirs)
        let cloud = Self.segment(meeting, "nowa propozycja cenowa", start: 2, track: .them)
        try await db.replaceSegments(meetingID: meeting.id, track: .them, with: [cloud])
        #expect(try await Self.segmentIDs(index, "oferta") == [mine.id])
        #expect(try await Self.segmentIDs(index, "propozycja") == [cloud.id])
    }

    @Test func deletingAMeetingDropsAllItsRows() async throws {
        let (index, db) = try Self.fixture()
        let gone = MeetingRecord(title: "Oferta dla klienta", notes: "oferta do wysłania")
        let kept = MeetingRecord(title: "Inne")
        try await db.createMeeting(gone)
        try await db.createMeeting(kept)
        try await db.appendSegment(Self.segment(gone, "oferta", start: 1))
        let stays = Self.segment(kept, "też oferta", start: 1)
        try await db.appendSegment(stays)
        try await db.deleteMeeting(id: gone.id)
        let hits = try #require(await index.search("oferta", limit: 10))
        #expect(hits.map(\.meetingID) == [kept.id])
        #expect(hits.map(\.segmentID) == [stays.id])
    }

    @Test func titleAndNotesEditsAreSearchable() async throws {
        let (index, db) = try Self.fixture()
        var meeting = MeetingRecord(title: "Budżet Q4")
        try await db.createMeeting(meeting)
        let title = try #require(await index.search("budżet", limit: 10))
        #expect(title.map(\.kind) == [.title])
        #expect(title.first?.segmentID == nil)

        try await db.modifyMeeting(id: meeting.id) { $0.notes = "Omówić harmonogram wdrożenia" }
        let notes = try #require(await index.search("harmonogram", limit: 10))
        #expect(notes.map(\.kind) == [.notes])

        meeting = try #require(try await db.meeting(id: meeting.id))
        meeting.title = "Plan roczny"
        try await db.updateMeeting(meeting)
        #expect(await index.search("budżet", limit: 10) == [])
        #expect(await index.search("roczny", limit: 10)?.map(\.kind) == [.title])
        #expect(await index.search("harmonogram", limit: 10)?.map(\.kind) == [.notes])
    }

    @Test func launchRecoveryDropsTheEchoItMarks() async throws {
        let (index, db) = try Self.fixture()
        let live = MeetingRecord(title: "bez słuchawek")
        try await db.createMeeting(live)
        let them = MeetingSegmentRecord(meetingID: live.id, track: .them, start: 10, end: 14, text: "wyślę ofertę jutro rano")
        let echo = MeetingSegmentRecord(meetingID: live.id, track: .me, start: 10.4, end: 14.2, text: "wyślę ofertę jutro rano")
        for segment in [them, echo] {
            try await db.appendSegment(segment)
        }
        #expect(try await Self.segmentIDs(index, "oferta") == [them.id, echo.id])
        _ = try await db.markInterruptedMeetings { _ in 0 }
        #expect(try await Self.segmentIDs(index, "oferta") == [them.id])
    }

    // MARK: Rebuild and launch checks

    @Test func aRebuildEqualsTheIncrementalIndex() async throws {
        let (index, db) = try Self.fixture()
        var meetings: [MeetingRecord] = []
        for number in 0..<5 {
            let meeting = MeetingRecord(title: "Spotkanie \(number) budżet", notes: number.isMultiple(of: 2) ? "oferta i harmonogram" : "")
            try await db.createMeeting(meeting)
            meetings.append(meeting)
            for line in 0..<8 {
                var segment = Self.segment(meeting, "linia \(line) ofertę wyślemy, budżet zatwierdzony", start: Double(line * 10),
                                           track: line.isMultiple(of: 2) ? .me : .them)
                segment.isEcho = line == 7
                try await db.appendSegment(segment)
            }
        }
        try await db.deleteMeeting(id: meetings[1].id)
        let queries = ["oferta", "budżet", "harmonogram", "linia", "spotkanie budżet"]
        var incremental: [String: Set<String>] = [:]
        for query in queries {
            incremental[query] = try await Self.keys(index, query)
        }
        let result = try await index.rebuild(from: db)
        #expect(result.meetings == 4)
        #expect(result.rows == 4 * 2 + 4 * 7)
        #expect(index.isReady)
        for query in queries {
            #expect(try await Self.keys(index, query) == incremental[query])
        }
        #expect(try await db.searchIndexCounts() == MeetingSearchIndex.Counts(meetings: 4, segments: 28))
    }

    @Test func aFileIndexIsCheckedAndRebuiltWhenNeeded() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MeetingSearchIndex.fileName)
        // The store is written without an index: only `prepare` brings the file in step.
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let meeting = MeetingRecord(title: "Zarząd")
        try await db.createMeeting(meeting)
        try await db.appendSegment(Self.segment(meeting, "Wyślę ofertę jutro"))

        // Missing file: created and built.
        let fresh = MeetingSearchIndex(url: url)
        #expect(!fresh.isReady)
        #expect(await fresh.search("oferta", limit: 10) == nil)
        guard case .rebuilt(let built) = await fresh.prepare(database: db) else {
            Issue.record("expected a rebuild of a new file")
            return
        }
        #expect(built.meetings == 1)
        #expect(built.rows == 3)
        #expect(fresh.isReady)
        #expect(await fresh.search("oferta", limit: 10)?.count == 1)

        // Same store, same file: ready without a rebuild.
        #expect(await MeetingSearchIndex(url: url).prepare(database: db) == .ready)

        // Another version: rebuilt.
        try SQLiteConnection(path: url.path(percentEncoded: false)).execute("PRAGMA user_version = 0")
        let upgraded = MeetingSearchIndex(url: url)
        guard case .rebuilt = await upgraded.prepare(database: db) else {
            Issue.record("expected a rebuild after a version change")
            return
        }
        #expect(await upgraded.search("zarzad", limit: 10)?.map(\.kind) == [.title])

        // The store moved on without the index (a crash lost writes): rebuilt.
        let later = MeetingRecord(title: "Harmonogram")
        try await db.createMeeting(later)
        let behind = MeetingSearchIndex(url: url)
        guard case .rebuilt(let caughtUp) = await behind.prepare(database: db) else {
            Issue.record("expected a rebuild when the counts differ")
            return
        }
        #expect(caughtUp.meetings == 2)
        #expect(await behind.search("harmonogram", limit: 10)?.map(\.meetingID) == [later.id])
    }

    @Test func aCorruptFileIsRecreated() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: MeetingSearchIndex.fileName)
        try Data(repeating: 0x5A, count: 8_192).write(to: url)
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        try await db.appendSegment(Self.segment(meeting, "Wyślę ofertę jutro"))

        let index = MeetingSearchIndex(url: url)
        guard case .rebuilt = await index.prepare(database: db) else {
            Issue.record("expected a rebuild of a corrupt file")
            return
        }
        #expect(await index.search("oferta", limit: 10)?.count == 1)
    }

    // MARK: Performance

    /// 200 meetings of 2 h (600 segments each): a search answers well under the bound. The
    /// target on an M1 is 100 ms; the bound is generous for a loaded CI machine.
    @Test func searchingALargeLibraryIsFast() async throws {
        let index = MeetingSearchIndex(url: nil)
        let words = [
            "wyślę", "ofertę", "jutro", "rano", "klient", "pytał", "o", "budżet", "na", "przyszły", "kwartał",
            "zespół", "przygotuje", "prezentację", "terminy", "są", "napięte", "ale", "damy", "radę", "spotkanie",
            "w", "piątek", "zarząd", "zatwierdzi", "plan", "sprzedaży", "umowa", "jest", "gotowa", "do", "podpisu",
            "faktura", "przyjdzie", "po", "wdrożeniu", "testy", "trwają", "dwa", "tygodnie", "dobrze", "że",
        ]
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for number in 0..<200 {
            let meeting = MeetingRecord(title: "Spotkanie \(number)")
            var segments: [MeetingSegmentRecord] = []
            segments.reserveCapacity(600)
            for line in 0..<600 {
                var text = (0..<12).map { _ in words[next(words.count)] }.joined(separator: " ")
                if next(50) == 0 { text += " harmonogram" }
                segments.append(Self.segment(meeting, text, start: Double(line * 12), track: line.isMultiple(of: 2) ? .me : .them))
            }
            index.indexMeeting(meeting, segments: segments)
        }
        // Waits for the queued writes (search runs after them on the same queue).
        _ = await index.search("rozgrzewka", limit: 1)

        for query in ["harmonogram", "oferta jutro", "budżet"] {
            let started = ContinuousClock.now
            let hits = try #require(await index.search(query, limit: 300))
            let elapsed = ContinuousClock.now - started
            print("Search index: \"\(query)\" over 120000 rows -> \(hits.count) hits in \(elapsed)")
            #expect(!hits.isEmpty)
            #expect(elapsed < .milliseconds(500))

            // The list asks per meeting: every one of the 200 meetings is ranked.
            let terms = try #require(SearchQuery.terms(query))
            let groupedStart = ContinuousClock.now
            let grouped = try #require(await index.meetingHits(terms: terms, all: true, meetings: 200, segmentsPerMeeting: 2))
            let groupedElapsed = ContinuousClock.now - groupedStart
            print("Search index: \"\(query)\" per meeting -> \(Set(grouped.map(\.meetingID)).count) meetings in \(groupedElapsed)")
            #expect(!grouped.isEmpty)
            #expect(groupedElapsed < .milliseconds(500))
        }
    }
}
