import Foundation
import Testing
@testable import Captylo

struct MeetingDatabaseTests {
    private static func db() throws -> Database {
        Database(modelContainer: try Store.makeInMemoryContainer())
    }

    private static func meeting(title: String = "Spotkanie w Zoom", createdAt: Date = Date()) -> MeetingRecord {
        MeetingRecord(createdAt: createdAt, title: title)
    }

    @Test func createUpdateAndReadBack() async throws {
        let db = try Self.db()
        var m = Self.meeting()
        m.appName = "Zoom"
        m.noteLines = [MeetingNoteLine(text: "budżet", at: 12)]
        m.speakerNames = ["1": "Anna"]
        try await db.createMeeting(m)
        m.status = .completed
        m.duration = 3600
        m.notes = "budżet\nterminy"
        m.summary = "## Podsumowanie"
        m.summaryTemplateID = "general"
        m.summaryModel = "model"
        m.summaryError = nil
        m.interruptions = [61.5, 1200]
        try await db.updateMeeting(m)
        let read = try #require(try await db.meeting(id: m.id))
        #expect(read == m)
    }

    @Test func updatingAMissingMeetingThrowsNotFound() async throws {
        let db = try Self.db()
        let m = Self.meeting()
        await #expect(throws: DatabaseError.notFound(m.id)) {
            try await db.updateMeeting(m)
        }
    }

    @Test func segmentsComeBackInTimeOrder() async throws {
        let db = try Self.db()
        let m = Self.meeting()
        try await db.createMeeting(m)
        let late = MeetingSegmentRecord(meetingID: m.id, track: .them, start: 10, end: 12, text: "później",
                                        words: [MeetingWord(text: "później", start: 10, end: 11)])
        let early = MeetingSegmentRecord(meetingID: m.id, track: .me, start: 1, end: 3, text: "najpierw")
        try await db.appendSegment(late)
        try await db.appendSegment(early)
        let segments = try await db.segments(meetingID: m.id)
        #expect(segments.map(\.text) == ["najpierw", "później"])
        #expect(segments.last?.words == late.words)
        #expect(segments.last == late)
    }

    @Test func segmentsWithTheSameStartPutTheMicFirst() async throws {
        let db = try Self.db()
        let m = Self.meeting()
        try await db.createMeeting(m)
        try await db.appendSegment(MeetingSegmentRecord(meetingID: m.id, track: .them, start: 5, end: 6, text: "oni"))
        try await db.appendSegment(MeetingSegmentRecord(meetingID: m.id, track: .me, start: 5, end: 6, text: "ja"))
        #expect(try await db.segments(meetingID: m.id).map(\.text) == ["ja", "oni"])
    }

    @Test func segmentsOfOtherMeetingsStayApart() async throws {
        let db = try Self.db()
        let a = Self.meeting(title: "A")
        let b = Self.meeting(title: "B")
        try await db.createMeeting(a)
        try await db.createMeeting(b)
        try await db.appendSegment(MeetingSegmentRecord(meetingID: a.id, track: .me, start: 0, end: 1, text: "a"))
        try await db.appendSegment(MeetingSegmentRecord(meetingID: b.id, track: .me, start: 0, end: 1, text: "b"))
        #expect(try await db.segments(meetingID: a.id).map(\.text) == ["a"])
    }

    @Test func searchFindsTitleNotesAndTranscriptWithoutDiacritics() async throws {
        let db = try Self.db()
        let a = Self.meeting(title: "Budżet Q4", createdAt: Date(timeIntervalSince1970: 100))
        var b = Self.meeting(title: "Standup", createdAt: Date(timeIntervalSince1970: 200))
        b.notes = "omówić zarząd"
        let c = Self.meeting(title: "Klient", createdAt: Date(timeIntervalSince1970: 300))
        for m in [a, b, c] { try await db.createMeeting(m) }
        try await db.appendSegment(MeetingSegmentRecord(meetingID: c.id, track: .them, start: 0, end: 1, text: "Wdrożenie w piątek"))
        #expect(try await db.meetings(query: "", limit: 10).map(\.id) == [c.id, b.id, a.id])
        #expect(try await db.meetings(query: "", limit: 2).map(\.id) == [c.id, b.id])
        #expect(try await db.meetings(query: "budzet", limit: 10).map(\.id) == [a.id])
        #expect(try await db.meetings(query: "ZARZAD", limit: 10).map(\.id) == [b.id])
        #expect(try await db.meetings(query: "wdrozenie", limit: 10).map(\.id) == [c.id])
        #expect(try await db.meetings(query: "  w piątek ", limit: 10).map(\.id) == [c.id])
        #expect(try await db.meetings(query: "nic takiego", limit: 10).isEmpty)
    }

    @Test func searchFollowsTitleAndNotesChanges() async throws {
        let db = try Self.db()
        var m = Self.meeting(title: "Standup")
        try await db.createMeeting(m)
        m.title = "Wyjazd do Łodzi"
        m.notes = "Zabrać laptopa"
        try await db.updateMeeting(m)
        #expect(try await db.meetings(query: "lodzi", limit: 10).map(\.id) == [m.id])
        #expect(try await db.meetings(query: "LAPTOP", limit: 10).map(\.id) == [m.id])
        #expect(try await db.meetings(query: "standup", limit: 10).isEmpty)
    }

    @Test func echoSegmentsAreKeptButNotSearchable() async throws {
        let db = try Self.db()
        let m = Self.meeting(title: "Klient")
        try await db.createMeeting(m)
        let echo = MeetingSegmentRecord(meetingID: m.id, track: .me, start: 0, end: 1, text: "cennik premium", isEcho: true)
        try await db.appendSegment(echo)
        #expect(try await db.meetings(query: "cennik", limit: 10).isEmpty)
        #expect(try await db.segments(meetingID: m.id) == [echo])
    }

    @Test func updateSegmentsChangesSpeakerAndEchoAndReindexesSearch() async throws {
        let db = try Self.db()
        let m = Self.meeting(title: "Klient")
        try await db.createMeeting(m)
        var mine = MeetingSegmentRecord(meetingID: m.id, track: .me, start: 0, end: 2, text: "ustalamy harmonogram")
        var theirs = MeetingSegmentRecord(meetingID: m.id, track: .them, start: 3, end: 4, text: "zgoda")
        try await db.appendSegment(mine)
        try await db.appendSegment(theirs)
        #expect(try await db.meetings(query: "harmonogram", limit: 10).map(\.id) == [m.id])

        mine.isEcho = true
        theirs.speaker = "2"
        try await db.updateSegments([mine, theirs])
        #expect(try await db.segments(meetingID: m.id) == [mine, theirs])
        #expect(try await db.meetings(query: "harmonogram", limit: 10).isEmpty)
        #expect(try await db.meetings(query: "zgoda", limit: 10).map(\.id) == [m.id])

        mine.isEcho = false
        try await db.updateSegments([mine])
        #expect(try await db.meetings(query: "harmonogram", limit: 10).map(\.id) == [m.id])
        try await db.updateSegments([])
    }

    @Test func deleteRemovesSegmentsToo() async throws {
        let db = try Self.db()
        let m = Self.meeting()
        let other = Self.meeting(title: "Inne")
        try await db.createMeeting(m)
        try await db.createMeeting(other)
        try await db.appendSegment(MeetingSegmentRecord(meetingID: m.id, track: .me, start: 0, end: 1, text: "x"))
        try await db.appendSegment(MeetingSegmentRecord(meetingID: other.id, track: .me, start: 0, end: 1, text: "y"))
        try await db.deleteMeeting(id: m.id)
        #expect(try await db.meeting(id: m.id) == nil)
        #expect(try await db.segments(meetingID: m.id).isEmpty)
        #expect(try await db.segments(meetingID: other.id).count == 1)
        #expect(try await db.meetings(query: "", limit: 10).map(\.id) == [other.id])
    }

    @Test func interruptedMeetingsAreMarkedOnLaunch() async throws {
        let db = try Self.db()
        var done = Self.meeting(title: "gotowe")
        done.status = .completed
        let live = Self.meeting(title: "w trakcie")
        var processing = Self.meeting(title: "notatki AI")
        processing.status = .processing
        try await db.createMeeting(done)
        try await db.createMeeting(live)
        try await db.createMeeting(processing)
        try await db.appendSegment(MeetingSegmentRecord(meetingID: live.id, track: .me, start: 0, end: 2, text: "zdążyłem"))
        #expect(Set(try await db.markInterruptedMeetings()) == [live.id, processing.id])
        #expect(try await db.meeting(id: live.id)?.status == .interrupted)
        #expect(try await db.meeting(id: processing.id)?.status == .interrupted)
        #expect(try await db.meeting(id: done.id)?.status == .completed)
        #expect(try await db.segments(meetingID: live.id).count == 1)
        #expect(try await db.markInterruptedMeetings().isEmpty)
    }

    @Test func audioRetentionQueries() async throws {
        let db = try Self.db()
        let old = Self.meeting(createdAt: Date(timeIntervalSince1970: 0))
        let fresh = Self.meeting(createdAt: Date())
        try await db.createMeeting(old)
        try await db.createMeeting(fresh)
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        #expect(try await db.meetingsWithAudio(olderThan: cutoff) == [old.id])
        try await db.setMeetingAudioRemoved(ids: [old.id])
        #expect(try await db.meeting(id: old.id)?.hasAudio == false)
        #expect(try await db.meeting(id: fresh.id)?.hasAudio == true)
        #expect(try await db.meetingsWithAudio(olderThan: cutoff).isEmpty)
        try await db.setMeetingAudioRemoved(ids: [])
    }

    @Test func modifyMeetingChangesOnlyWhatTheClosureTouches() async throws {
        let db = try Self.db()
        var m = Self.meeting(title: "Budżet")
        m.summary = "## Podsumowanie"
        m.speakerNames = ["1": "Anna"]
        try await db.createMeeting(m)
        let changed = try await db.modifyMeeting(id: m.id) {
            $0.notes = "budżet reklam"
            $0.noteLines = [MeetingNoteLine(text: "budżet reklam", at: 12)]
        }
        #expect(changed?.notes == "budżet reklam")
        let read = try #require(try await db.meeting(id: m.id))
        #expect(read.notes == "budżet reklam")
        #expect(read.noteLines.map(\.at) == [12])
        #expect(read.summary == "## Podsumowanie")
        #expect(read.speakerNames == ["1": "Anna"])
        #expect(read.createdAt == m.createdAt)
        // The notes are searchable right away, like `updateMeeting`.
        #expect(try await db.meetings(query: "reklam", limit: 10).map(\.id) == [m.id])
    }

    /// Two writers of different fields at the same time (the notes editor and the recorder's
    /// stop) both land: each change is read, applied and saved in one step on the actor.
    @Test func concurrentModificationsOfDifferentFieldsBothLand() async throws {
        let db = try Self.db()
        let m = Self.meeting()
        try await db.createMeeting(m)
        async let notes: MeetingRecord? = db.modifyMeeting(id: m.id) { $0.notes = "notatka" }
        async let status: MeetingRecord? = db.modifyMeeting(id: m.id) {
            $0.status = .completed
            $0.duration = 90
        }
        _ = try await (notes, status)
        let read = try #require(try await db.meeting(id: m.id))
        #expect(read.notes == "notatka")
        #expect(read.status == .completed)
        #expect(read.duration == 90)
    }

    @Test func modifyingAMissingMeetingReturnsNil() async throws {
        let db = try Self.db()
        #expect(try await db.modifyMeeting(id: UUID()) { $0.notes = "x" } == nil)
    }

    @Test func foldIgnoresCaseAndPolishLetters() {
        #expect(MeetingSearch.fold("Łódź") == "lodz")
        #expect(MeetingSearch.fold("ZARZĄD żółć") == "zarzad zolc")
        #expect(MeetingSearch.fold("Wdrożenie w piątek") == "wdrozenie w piatek")
    }
}
