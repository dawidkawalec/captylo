import Foundation
import Testing
@testable import Captylo

struct NotesDatabaseTests {
    private static func db() throws -> Database {
        Database(modelContainer: try Store.makeInMemoryContainer())
    }

    @Test func createUpdateAndReadBack() async throws {
        let db = try Self.db()
        var note = NoteRecord(title: "", body: "Kupić mleko\nZadzwonić do Ani")
        try await db.createNote(note)
        note.title = "Zakupy"
        note.body += "\nOdebrać paczkę"
        try await db.updateNote(note)
        let read = try #require(try await db.note(id: note.id))
        #expect(read.title == "Zakupy")
        #expect(read.body == note.body)
        #expect(read.updatedAt >= note.createdAt)
    }

    @Test func updatingAMissingNoteThrowsNotFound() async throws {
        let db = try Self.db()
        let note = NoteRecord(body: "x")
        await #expect(throws: DatabaseError.notFound(note.id)) {
            try await db.updateNote(note)
        }
    }

    @Test func displayTitleFallsBackToTheFirstLine() {
        #expect(NoteRecord(title: "", body: "\n  Pierwsza linia  \ndruga").displayTitle == "Pierwsza linia")
        #expect(NoteRecord(title: "Tytuł", body: "treść").displayTitle == "Tytuł")
        #expect(NoteRecord(title: "", body: "   ").displayTitle == String(localized: "Notatka bez tytułu"))
    }

    @Test func listIsNewestFirstAndQueryIgnoresCaseAndDiacritics() async throws {
        let db = try Self.db()
        let old = NoteRecord(createdAt: Date(timeIntervalSince1970: 1_000), title: "Łódź", body: "")
        let new = NoteRecord(createdAt: Date(timeIntervalSince1970: 2_000), title: "", body: "Spotkanie z zarządem")
        try await db.createNote(old)
        try await db.createNote(new)
        #expect(try await db.notes(query: "", limit: 10).map(\.id) == [new.id, old.id])
        #expect(try await db.notes(query: "lodz", limit: 10).map(\.id) == [old.id])
        #expect(try await db.notes(query: "ZARZAD", limit: 10).map(\.id) == [new.id])
        #expect(try await db.notes(ids: [old.id, new.id]).map(\.id) == [old.id, new.id])
        #expect(try await db.noteIDs() == [new.id, old.id])
    }

    @Test func modifyChangesOneFieldAndKeepsTheRest() async throws {
        let db = try Self.db()
        let note = NoteRecord(title: "A", body: "treść", audioFileName: "x.wav", audioDuration: 3)
        try await db.createNote(note)
        let saved = try #require(try await db.modifyNote(id: note.id) { $0.body = "nowa treść" })
        #expect(saved.body == "nowa treść")
        #expect(saved.audioFileName == "x.wav")
        #expect(try await db.modifyNote(id: UUID()) { $0.body = "x" } == nil)
    }

    @Test func referencedAudioListsOnlyNotesWithAudio() async throws {
        let db = try Self.db()
        try await db.createNote(NoteRecord(body: "a", audioFileName: "a.wav"))
        try await db.createNote(NoteRecord(body: "b"))
        #expect(try await db.referencedNoteAudioFileNames() == ["a.wav"])
    }

    /// Launch sweep of `Notes/`: a recording no note points at (a failed save, the in-memory
    /// fallback store) goes after 10 minutes; a note's own recording and fresh files stay.
    @MainActor
    @Test func theNotesSweepRemovesOldRecordingsNoNotePointsAt() async throws {
        let db = try Self.db()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloNoteOrphans-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let note = NoteRecord(body: "x", audioFileName: "\(UUID().uuidString).wav")
        try await db.createNote(note)
        let kept = directory.appending(path: note.audioFileName!)
        let orphan = directory.appending(path: "\(UUID().uuidString).wav")
        let fresh = directory.appending(path: "\(UUID().uuidString).wav")
        for url in [kept, orphan, fresh] {
            try Data([0]).write(to: url)
        }
        for url in [kept, orphan] {
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: url.path)
        }
        #expect(await Retention.sweepNoteOrphans(database: db, now: now, notes: directory) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func anUntouchedEmptyNoteIsDiscardedWhenLeft() async throws {
        let db = try Self.db()
        let empty = NoteRecord()
        let titled = NoteRecord(title: "Tytuł")
        let voice = NoteRecord(audioFileName: "v.wav")
        for note in [empty, titled, voice] {
            try await db.createNote(note)
        }
        #expect(try await db.deleteNoteIfEmpty(id: empty.id))
        #expect(try await !db.deleteNoteIfEmpty(id: titled.id))
        #expect(try await !db.deleteNoteIfEmpty(id: voice.id))
        #expect(try await db.note(id: empty.id) == nil)
        #expect(try await db.notes(query: "", limit: 10).count == 2)
        // An empty note leaves no tombstone: it never existed for sync.
        #expect(try await db.tombstones().isEmpty)
    }

    /// The device id of a tombstone is checked in `DataDeviceIdentityTests` (serialized: the id is global).
    @Test func deletesLeaveTombstonesForNotesMeetingsAndDictations() async throws {
        let db = try Self.db()
        let note = NoteRecord(title: "", body: "x", audioFileName: "n.wav")
        try await db.createNote(note)
        let typed = NoteRecord(body: "bez nagrania")
        try await db.createNote(typed)
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        let dictation = DictationRecord(text: "raz", status: .completed, audioDuration: 1, wordCount: 1)
        try await db.save(dictation)

        #expect(try await db.deleteNote(id: note.id) == "n.wav")
        #expect(try await db.deleteNote(id: typed.id) == "")
        try await db.deleteMeeting(id: meeting.id)
        _ = try await db.delete(ids: [dictation.id])

        let stones = try await db.tombstones()
        #expect(Set(stones.map { "\($0.entity.rawValue) \($0.entityID)" }) == [
            "note \(note.id)", "note \(typed.id)", "meeting \(meeting.id)", "dictation \(dictation.id)",
        ])
        #expect(try await db.note(id: note.id) == nil)
        #expect(try await db.deleteNote(id: note.id) == nil)
    }
}
