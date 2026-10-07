import Foundation
import SwiftData

/// Note reads and writes. Like meetings: models never leave the actor (callers get `NoteRecord`).
extension Database {
    // MARK: Note writes

    func createNote(_ record: NoteRecord) throws {
        modelContext.insert(Note(record))
        try modelContext.save()
    }

    /// Overwrites every field of the row.
    func updateNote(_ record: NoteRecord) throws {
        guard let row = try fetchNote(id: record.id) else {
            throw DatabaseError.notFound(record.id)
        }
        row.apply(record)
        try modelContext.save()
    }

    /// Reads, changes and saves one note in a single step on the actor, so the editor's autosave
    /// and an AI pass or an append never undo each other. Nil when the note is gone.
    @discardableResult
    func modifyNote(id: UUID, _ change: @Sendable (inout NoteRecord) -> Void) throws -> NoteRecord? {
        guard let row = try fetchNote(id: id) else { return nil }
        var record = row.record
        change(&record)
        row.apply(record)
        try modelContext.save()
        return row.record
    }

    /// Removes the note and writes its tombstone in the same save. Returns the audio file name for
    /// the caller to delete: "" for a note without audio, nil when there was no such note.
    func deleteNote(id: UUID) throws -> String? {
        guard let row = try fetchNote(id: id) else { return nil }
        let fileName = row.audioFileName ?? ""
        modelContext.delete(row)
        modelContext.insert(Tombstone(.note, id: id))
        try modelContext.save()
        return fileName
    }

    // MARK: Note reads

    func note(id: UUID) throws -> NoteRecord? {
        try fetchNote(id: id)?.record
    }

    /// Newest first. A non-empty query matches the title or the body, ignoring case and Polish
    /// diacritics (`MeetingSearch.fold`), inside SQLite.
    func notes(query: String, limit: Int) throws -> [NoteRecord] {
        guard limit > 0 else { return [] }
        let folded = MeetingSearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
        if !folded.isEmpty {
            descriptor.predicate = #Predicate<Note> { $0.searchText.contains(folded) }
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.record)
    }

    /// The notes with these ids, in the order of `ids` (search hits keep their rank).
    func notes(ids: [UUID]) throws -> [NoteRecord] {
        guard !ids.isEmpty else { return [] }
        let rows = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.record) })
        return ids.compactMap { byID[$0] }
    }

    /// Every note id, newest first (the search index rebuild).
    func noteIDs() throws -> [UUID] {
        var descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
        descriptor.propertiesToFetch = [\.id, \.createdAt]
        return try modelContext.fetch(descriptor).map(\.id)
    }

    /// Every audio file name a note points at (a sweep of `AppPaths.notes` keeps exactly these).
    func referencedNoteAudioFileNames() throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.audioFileName != nil }))
        return Set(rows.compactMap(\.audioFileName))
    }

    /// Every deletion kept for sync, oldest first.
    func tombstones() throws -> [TombstoneRecord] {
        try modelContext.fetch(FetchDescriptor<Tombstone>(sortBy: [SortDescriptor(\.deletedAt)])).compactMap(\.record)
    }

    // MARK: Note helpers

    private func fetchNote(id: UUID) throws -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
