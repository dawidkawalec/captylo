import Foundation
import Testing
@testable import Captylo

/// Notes in the FTS5 index next to meetings (kinds `noteTitle` / `noteBody`).
struct NotesSearchIndexTests {
    private static func fixture() throws -> (index: MeetingSearchIndex, db: Database) {
        let index = MeetingSearchIndex(url: nil)
        return (index, Database(modelContainer: try Store.makeInMemoryContainer(), searchIndex: index))
    }

    @Test func notesAreFoundByTitleAndBodyWithPolishForms() async throws {
        let (index, db) = try Self.fixture()
        let offer = NoteRecord(title: "Oferta dla klienta", body: "")
        let board = NoteRecord(title: "", body: "Zarząd przyjmie ofertę w piątek")
        try await db.createNote(offer)
        try await db.createNote(board)
        let hits = try #require(await index.noteHits(terms: ["ofert"], all: true, limit: 10))
        #expect(Set(hits.map(\.noteID)) == [offer.id, board.id])
        // The title weighs more than the body.
        #expect(hits.first?.noteID == offer.id)
    }

    @Test func meetingQueriesNeverReturnNoteRows() async throws {
        let (index, db) = try Self.fixture()
        try await db.createNote(NoteRecord(title: "Budżet", body: "budżet budżet"))
        #expect(try #require(await index.search("budżet", limit: 10)).isEmpty)
        let meetings = try #require(await index.meetingHits(terms: ["budzet"], all: true, meetings: 5, segmentsPerMeeting: 3))
        #expect(meetings.isEmpty)
    }

    @Test func meetingHitsStillCountWithManyMatchingNotes() async throws {
        let (index, db) = try Self.fixture()
        for number in 0..<6 {
            try await db.createNote(NoteRecord(title: "Kawa \(number)", body: "kawa"))
        }
        let meeting = MeetingRecord(title: "Kawa z zespołem")
        try await db.createMeeting(meeting)
        // A flat limit of 3 would be eaten by the note rows if they were not filtered out.
        let hits = try #require(await index.search("kawa", limit: 3))
        #expect(hits.map(\.meetingID) == [meeting.id])
    }

    @Test func editsAndDeletesKeepTheIndexInStep() async throws {
        let (index, db) = try Self.fixture()
        let note = NoteRecord(title: "", body: "stara treść")
        try await db.createNote(note)
        try await db.modifyNote(id: note.id) { $0.body = "nowy wpis o kawie" }
        #expect(try #require(await index.noteHits(terms: ["stara"], all: true, limit: 5)).isEmpty)
        #expect(try #require(await index.noteHits(terms: ["kawie"], all: true, limit: 5)).map(\.noteID) == [note.id])
        var renamed = try #require(try await db.note(id: note.id))
        renamed.title = "Zakupy"
        try await db.updateNote(renamed)
        #expect(try #require(await index.noteHits(terms: ["zakupy"], all: true, limit: 5)).map(\.noteID) == [note.id])
        _ = try await db.deleteNote(id: note.id)
        #expect(try #require(await index.noteHits(terms: ["kawie"], all: true, limit: 5)).isEmpty)
    }

    @Test func rebuildIncludesNotesAndCountsMatchTheStore() async throws {
        let (index, db) = try Self.fixture()
        try await db.createNote(NoteRecord(title: "Pierwsza", body: "a"))
        try await db.createMeeting(MeetingRecord(title: "Spotkanie"))
        let rebuilt = try await index.rebuild(from: db)
        #expect(rebuilt.meetings == 1)
        let stored = try await db.searchIndexCounts()
        #expect(stored.notes == 1)
        #expect(try #require(await index.noteHits(terms: ["pierwsza"], all: true, limit: 5)).count == 1)
    }

    /// A file of the old version is dropped and rebuilt with the notes (launch after the update).
    @Test func anOldIndexFileIsRebuiltWithNotes() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "captylo-notes-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: MeetingSearchIndex.fileName)
        do {
            let old = try SQLiteConnection(path: url.path(percentEncoded: false))
            try old.execute("PRAGMA user_version = 1;")
        }
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        try await db.createNote(NoteRecord(title: "Notatka z wczoraj", body: ""))
        let index = MeetingSearchIndex(url: url)
        guard case .rebuilt = await index.prepare(database: db) else {
            Issue.record("Expected a rebuild of the version 1 file")
            return
        }
        #expect(try #require(await index.noteHits(terms: ["wczoraj"], all: true, limit: 5)).count == 1)
    }
}
