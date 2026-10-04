import Foundation
import SwiftData

// MARK: - Store

/// Opens the single SwiftData store (gotcha 80): parent directory first, `cloudKitDatabase: .none`,
/// in-memory fallback when the file cannot be opened. The caller shows the alert when `isFallback`.
enum Store {
    static let configurationName = "Captylo"

    static var schema: Schema { Schema([Dictation.self, UsageStat.self, Meeting.self, MeetingSegment.self]) }

    static func makeContainer(url: URL = AppPaths.store) -> (container: ModelContainer, isFallback: Bool) {
        do {
            try AppPaths.ensureDirectories()
            let container = try openContainer(at: url)
            Log.data.info("Store opened at \(url.path(percentEncoded: false), privacy: .public)")
            return (container, false)
        } catch {
            Log.data.error("Store open failed, using in-memory fallback: \(error.localizedDescription, privacy: .public)")
            do {
                return (try makeInMemoryContainer(), true)
            } catch {
                // An in-memory container only fails when the schema itself is broken: a programming error.
                fatalError("In-memory SwiftData container failed: \(error)")
            }
        }
    }

    /// Opens (and, for an older schema, lightweight-migrates) the on-disk store at `url`.
    /// Schema changes must stay additive with defaults (gotcha 80): SwiftData then migrates
    /// the store in place without a `VersionedSchema`.
    static func openContainer(at url: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Opens the on-disk store at `url` read-only: the MCP server (`MeetingLibraryReader`), a
    /// second process next to a running Captylo. Never creates the file or its folder, never
    /// saves, never migrates: a store of another schema version fails to open instead.
    static func openReadOnlyContainer(at url: URL) throws -> ModelContainer {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            url: url,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Fresh in-memory container (fallback and tests).
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

// MARK: - Errors

enum DatabaseError: LocalizedError, Sendable, Equatable {
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "Nie znaleziono wpisu w historii.")
        }
    }
}

// MARK: - Database

/// Every read and write on the store. Models never leave the actor: callers get `DictationRecord`,
/// `DashboardSnapshot` or plain values (gotcha 10).
///
/// A `ModelActor` written out instead of `@ModelActor`: the macro installs SwiftData's default
/// executor, which runs jobs on the caller's thread (main, for most callers here). This one runs
/// on `DatabaseExecutor`'s own queue.
actor Database: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    /// The meeting search index, told about every saved change to searchable meeting text
    /// (`Database+Meetings`); nil where nothing searches (most tests).
    nonisolated let searchIndex: (any MeetingIndexing)?

    init(modelContainer: ModelContainer, searchIndex: (any MeetingIndexing)? = nil) {
        self.modelContainer = modelContainer
        self.searchIndex = searchIndex
        modelExecutor = DatabaseExecutor(modelContext: ModelContext(modelContainer))
    }

    /// True when the actor's work runs on the main thread (regression check for the executor).
    func isExecutingOnMainThread() -> Bool {
        Thread.isMainThread
    }

    // MARK: Writes

    /// Inserts the `Dictation` and, for a completed one, its `UsageStat` in the same save (gotcha 82).
    func save(_ record: DictationRecord) throws {
        modelContext.insert(Dictation(record))
        if record.status == .completed {
            modelContext.insert(UsageStat(record))
        }
        try modelContext.save()
    }

    /// Retranscribe path (gotcha 85): overwrites the same row and adds a `UsageStat` only when the
    /// row is completed and no stat exists for that id yet.
    func update(_ record: DictationRecord) throws {
        guard let row = try fetchDictation(id: record.id) else {
            throw DatabaseError.notFound(record.id)
        }
        row.apply(record)
        if record.status == .completed, try usageStatCount(for: record.id) == 0 {
            modelContext.insert(UsageStat(record))
        }
        try modelContext.save()
    }

    /// "Przetwórz przez AI": overwrites only the AI fields of the row (`enhancedText`,
    /// `enhancementMode`, `enhancementModel`, `enhancementMs`, `enhancementNote`). The text, the
    /// word count and the `UsageStat` table stay as they are.
    func updateEnhancement(_ record: DictationRecord) throws {
        guard let row = try fetchDictation(id: record.id) else {
            throw DatabaseError.notFound(record.id)
        }
        row.applyEnhancement(of: record)
        try modelContext.save()
    }

    /// `update` when a row with this id exists, otherwise `save` (file queue retries reuse the id).
    func upsert(_ record: DictationRecord) throws {
        if try fetchDictation(id: record.id) != nil {
            try update(record)
        } else {
            try save(record)
        }
    }

    /// Removes the rows and returns their audio file names for the caller to delete. `UsageStat` stays.
    func delete(ids: [UUID]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let rows = try fetchDictations(ids: ids)
        let fileNames = rows.compactMap(\.audioFileName)
        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
        return fileNames
    }

    /// Audio retention: forgets the audio of rows older than `cutoff` and returns the file names.
    /// Text and `UsageStat` are untouched.
    func clearAudio(olderThan cutoff: Date) throws -> [String] {
        let descriptor = FetchDescriptor<Dictation>(
            predicate: #Predicate { $0.createdAt < cutoff && $0.audioFileName != nil }
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return [] }
        let fileNames = rows.compactMap(\.audioFileName)
        for row in rows {
            row.audioFileName = nil
        }
        try modelContext.save()
        return fileNames
    }

    // MARK: Reads

    /// Every audio file name a row still points at (the orphan sweep keeps exactly these).
    func referencedAudioFileNames() throws -> Set<String> {
        let descriptor = FetchDescriptor<Dictation>(predicate: #Predicate { $0.audioFileName != nil })
        return Set(try modelContext.fetch(descriptor).compactMap(\.audioFileName))
    }

    func record(id: UUID) -> DictationRecord? {
        (try? fetchDictation(id: id))?.record
    }

    /// Delivered text of the newest completed dictation (menu bar "Kopiuj ostatni tekst").
    func lastCompletedText() -> String? {
        let completed = DictationStatus.completed.rawValue
        var descriptor = FetchDescriptor<Dictation>(
            predicate: #Predicate { $0.status == completed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.finalText
    }

    /// One page of the history list (`HistorySearch.descriptor`) as value records. Read here, in
    /// the context that wrote the rows, so a save, retranscribe or delete is always visible.
    func history(query: String, limit: Int) throws -> [DictationRecord] {
        try modelContext.fetch(HistorySearch.descriptor(query: query, limit: limit)).map(\.record)
    }

    func count() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<Dictation>())) ?? 0
    }

    /// Totals over every `UsageStat` plus the day buckets of the last `days` days.
    func dashboard(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> DashboardSnapshot {
        let stats = try modelContext.fetch(FetchDescriptor<UsageStat>())
        let samples = stats.map {
            UsageSample(createdAt: $0.createdAt, wordCount: $0.wordCount, audioDuration: $0.audioDuration)
        }
        return Stats.snapshot(samples: samples, days: days, now: now, calendar: calendar)
    }

    /// CSV document for the given rows, newest first.
    func csv(ids: [UUID]) throws -> String {
        let rows = try fetchDictations(ids: ids)
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        return CSV.document(rows.map(\.record))
    }

    // MARK: Helpers

    private func fetchDictation(id: UUID) throws -> Dictation? {
        var descriptor = FetchDescriptor<Dictation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchDictations(ids: [UUID]) throws -> [Dictation] {
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Dictation>(predicate: #Predicate { ids.contains($0.id) })
        return try modelContext.fetch(descriptor)
    }

    private func usageStatCount(for id: UUID) throws -> Int {
        let descriptor = FetchDescriptor<UsageStat>(predicate: #Predicate { $0.dictationID == id })
        return try modelContext.fetchCount(descriptor)
    }
}
