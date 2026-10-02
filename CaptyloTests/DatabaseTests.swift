import Foundation
import Testing
@testable import Captylo

@MainActor
struct DatabaseThreadingTests {
    @Test func builtAndCalledFromTheMainActorItStillRunsOffTheMainThread() async throws {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        #expect(await database.isExecutingOnMainThread() == false)

        let record = DictationRecord(text: "raz dwa", status: .completed, audioDuration: 1, wordCount: 2)
        try await database.save(record)
        #expect(await database.record(id: record.id)?.text == "raz dwa")
        #expect(await database.isExecutingOnMainThread() == false)
    }
}

struct DatabaseTests {
    private static func makeDatabase() throws -> Database {
        Database(modelContainer: try Store.makeInMemoryContainer())
    }

    private static func record(
        words: Int = 3,
        duration: Double = 6,
        status: DictationStatus = .completed,
        createdAt: Date = Date(),
        text: String = "raz dwa trzy",
        audio: Bool = true
    ) -> DictationRecord {
        let id = UUID()
        return DictationRecord(
            id: id,
            createdAt: createdAt,
            text: text,
            status: status,
            audioDuration: duration,
            audioFileName: audio ? "\(id.uuidString).wav" : nil,
            modelName: "parakeet-tdt-0.6b-v3",
            transcriptionMs: 120,
            wordCount: words
        )
    }

    // MARK: Save and read

    @Test func historyPageIsNewestFirstFilteredAndSeesUpdates() async throws {
        let db = try Self.makeDatabase()
        let older = Self.record(createdAt: Date(timeIntervalSince1970: 100), text: "stary wpis")
        let newer = Self.record(createdAt: Date(timeIntervalSince1970: 200), text: "nowy wpis o kotach")
        try await db.save(older)
        try await db.save(newer)

        #expect(try await db.history(query: "", limit: 50).map(\.id) == [newer.id, older.id])
        #expect(try await db.history(query: "KOTACH", limit: 50).map(\.id) == [newer.id])

        var changed = older
        changed.text = "poprawiony tekst"
        try await db.update(changed)
        #expect(try await db.history(query: "", limit: 50).last?.text == "poprawiony tekst")
    }

    @Test func saveStoresRowAndStat() async throws {
        let db = try Self.makeDatabase()
        let record = Self.record(words: 5, duration: 10)
        try await db.save(record)

        #expect(await db.count() == 1)
        #expect(await db.record(id: record.id) == record)
        #expect(await db.lastCompletedText() == "raz dwa trzy")

        let snapshot = try await db.dashboard(days: 7)
        #expect(snapshot.sessions == 1)
        #expect(snapshot.words == 5)
        #expect(snapshot.audioSeconds == 10)
        #expect(snapshot.wpm == 30)
    }

    @Test func failedRowsGetNoStat() async throws {
        let db = try Self.makeDatabase()
        try await db.save(Self.record(status: .failed, text: ""))
        try await db.save(Self.record(words: 2, text: "dwa słowa"))

        #expect(await db.count() == 2)
        let snapshot = try await db.dashboard(days: 7)
        #expect(snapshot.sessions == 1)
        #expect(snapshot.words == 2)
        #expect(await db.lastCompletedText() == "dwa słowa")
    }

    @Test func lastCompletedTextPrefersEnhancedAndNewest() async throws {
        let db = try Self.makeDatabase()
        var older = Self.record(createdAt: Date(timeIntervalSinceNow: -100), text: "stary")
        older.enhancedText = "stary, poprawiony"
        try await db.save(older)
        var newer = Self.record(createdAt: Date(), text: "nowy")
        newer.enhancedText = "nowy, poprawiony"
        try await db.save(newer)
        try await db.save(Self.record(status: .failed, createdAt: Date(timeIntervalSinceNow: 10), text: ""))

        #expect(await db.lastCompletedText() == "nowy, poprawiony")
        #expect(await db.record(id: UUID()) == nil)
        #expect(await db.lastCompletedText() == "nowy, poprawiony", "unchanged by the failed row")
    }

    // MARK: Update

    @Test func updateOverwritesSameRowWithoutDuplicatingStat() async throws {
        let db = try Self.makeDatabase()
        let original = Self.record(words: 3)
        try await db.save(original)

        var changed = original
        changed.text = "cztery słowa tu są"
        changed.wordCount = 4
        changed.modelName = "scribe_v2"
        changed.transcriptionMs = 900
        try await db.update(changed)

        #expect(await db.count() == 1)
        #expect(await db.record(id: original.id) == changed)
        let snapshot = try await db.dashboard(days: 7)
        #expect(snapshot.sessions == 1, "stat is append-only, no second row for the same id")
        #expect(snapshot.words == 3, "the original stat keeps its numbers")
    }

    @Test func updateAddsStatWhenFailedRowBecomesCompleted() async throws {
        let db = try Self.makeDatabase()
        let failed = Self.record(words: 0, status: .failed, text: "")
        try await db.save(failed)
        #expect(try await db.dashboard(days: 7).sessions == 0)

        var fixed = failed
        fixed.status = .completed
        fixed.text = "teraz działa"
        fixed.wordCount = 2
        try await db.update(fixed)
        try await db.update(fixed)

        let snapshot = try await db.dashboard(days: 7)
        #expect(snapshot.sessions == 1)
        #expect(snapshot.words == 2)
    }

    @Test func upsertInsertsThenReplacesTheSameRow() async throws {
        let db = try Self.makeDatabase()
        let failed = Self.record(words: 0, status: .failed, text: "")
        try await db.upsert(failed)
        #expect(await db.count() == 1)

        var fixed = failed
        fixed.status = .completed
        fixed.text = "drugie podejście"
        fixed.wordCount = 2
        try await db.upsert(fixed)

        #expect(await db.count() == 1, "a retry never adds a second row")
        #expect(await db.record(id: failed.id) == fixed)
        #expect(try await db.dashboard(days: 7).sessions == 1)
    }

    @Test func updateOfMissingRowThrows() async throws {
        let db = try Self.makeDatabase()
        await #expect(throws: DatabaseError.self) {
            try await db.update(Self.record())
        }
    }

    // MARK: Delete

    @Test func deleteReturnsAudioNamesAndKeepsDashboardTotals() async throws {
        let db = try Self.makeDatabase()
        let a = Self.record(words: 10, duration: 30)
        let b = Self.record(words: 20, duration: 30, audio: false)
        let c = Self.record(words: 30, duration: 30)
        for record in [a, b, c] { try await db.save(record) }
        let before = try await db.dashboard(days: 7)

        let names = try await db.delete(ids: [a.id, b.id])
        #expect(names == [a.audioFileName!])
        #expect(await db.count() == 1)
        #expect(await db.record(id: a.id) == nil)
        #expect(await db.record(id: c.id) == c)

        let after = try await db.dashboard(days: 7)
        #expect(after == before)
        #expect(after.sessions == 3)
        #expect(after.words == 60)
        #expect(try await db.delete(ids: []).isEmpty)
    }

    // MARK: Dashboard buckets

    @Test func dashboardBucketsUseTheGivenCalendar() async throws {
        let db = try Self.makeDatabase()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        try await db.save(Self.record(words: 7, duration: 60, createdAt: now))
        try await db.save(Self.record(words: 8, duration: 120, createdAt: yesterday))
        try await db.save(Self.record(words: 9, duration: 60, createdAt: calendar.date(byAdding: .day, value: -40, to: now)!))

        let snapshot = try await db.dashboard(days: 7, now: now, calendar: calendar)
        #expect(snapshot.sessions == 3)
        #expect(snapshot.words == 24)
        #expect(snapshot.days.count == 7)
        #expect(snapshot.days[6].words == 7)
        #expect(snapshot.days[5].words == 8)
        #expect(snapshot.days[5].minutes == 2)
        #expect(snapshot.days[0...4].allSatisfy { $0.sessions == 0 })
    }

    // MARK: Audio retention

    @Test func clearAudioForgetsOldFilesOnly() async throws {
        let db = try Self.makeDatabase()
        let old = Self.record(createdAt: Date(timeIntervalSinceNow: -10 * 86_400))
        let fresh = Self.record(createdAt: Date())
        let oldWithoutAudio = Self.record(createdAt: Date(timeIntervalSinceNow: -20 * 86_400), audio: false)
        for record in [old, fresh, oldWithoutAudio] { try await db.save(record) }

        let names = try await db.clearAudio(olderThan: Date(timeIntervalSinceNow: -7 * 86_400))
        #expect(names == [old.audioFileName!])
        #expect(await db.record(id: old.id)?.audioFileName == nil)
        #expect(await db.record(id: old.id)?.text == old.text)
        #expect(await db.record(id: fresh.id)?.audioFileName == fresh.audioFileName)
        #expect(try await db.dashboard(days: 7).sessions == 3)
        #expect(try await db.clearAudio(olderThan: Date(timeIntervalSinceNow: -7 * 86_400)).isEmpty)
    }

    @MainActor
    @Test func retentionDeletesOldRecordingsAndKeepsText() async throws {
        let db = try Self.makeDatabase()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloRetention-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let old = Self.record(createdAt: now.addingTimeInterval(-10 * 86_400))
        let fresh = Self.record(createdAt: now)
        for record in [old, fresh] {
            try await db.save(record)
            try Data([0, 1, 2]).write(to: directory.appending(path: record.audioFileName!))
        }
        let orphan = directory.appending(path: "orphan.wav")
        try Data([0]).write(to: orphan)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: orphan.path)
        let keep = directory.appending(path: "notes.txt")
        try Data([0]).write(to: keep)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: keep.path)

        await Retention.run(days: 0, database: db, now: now, recordings: directory)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: old.audioFileName!).path))

        await Retention.run(days: 7, database: db, now: now, recordings: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: old.audioFileName!).path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: fresh.audioFileName!).path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(await db.record(id: old.id)?.audioFileName == nil)
        #expect(await db.record(id: old.id)?.text == old.text)
        #expect(await db.record(id: fresh.id)?.audioFileName == fresh.audioFileName)
        #expect(try await db.dashboard(days: 7).sessions == 2)
    }

    @MainActor
    @Test func orphanSweepDeletesOnlyOldUnreferencedRecordings() async throws {
        let db = try Self.makeDatabase()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloOrphans-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let kept = Self.record(createdAt: old)
        try await db.save(kept)
        let referenced = directory.appending(path: kept.audioFileName!)
        let orphan = directory.appending(path: "\(UUID().uuidString).wav")
        let freshOrphan = directory.appending(path: "\(UUID().uuidString).wav")
        let other = directory.appending(path: "notes.txt")
        for url in [referenced, orphan, freshOrphan, other] {
            try Data([0]).write(to: url)
        }
        for url in [referenced, orphan, other] {
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: url.path)
        }

        let removed = await Retention.sweepOrphans(database: db, now: now, recordings: directory)

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(FileManager.default.fileExists(atPath: freshOrphan.path), "a take still in flight has no row yet")
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: CSV

    @Test func csvEscaping() {
        #expect(CSV.escape("plain") == "plain")
        #expect(CSV.escape("a,b") == "\"a,b\"")
        #expect(CSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSV.escape("line\nbreak") == "\"line\nbreak\"")
        #expect(CSV.escape("carriage\rreturn") == "\"carriage\rreturn\"")
        #expect(CSV.escape("crlf\r\nhere") == "\"crlf\r\nhere\"")
        #expect(CSV.escape("") == "")
        #expect(CSV.line(["a", "b,c", ""]) == "a,\"b,c\",")
    }

    @Test func csvLabelsTheCloudModelWithoutTheVendor() {
        var record = Self.record(text: "z chmury")
        record.modelName = STTEngine.elevenLabs.modelName
        #expect(CSV.fields(for: record)[5] == STTEngine.elevenLabs.displayName)
        record.modelName = STTEngine.local.modelName
        #expect(CSV.fields(for: record)[5] == "whisper-large-v3-turbo")
    }

    @Test func csvDocumentFromDatabase() async throws {
        let db = try Self.makeDatabase()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        var first = Self.record(duration: 2.5, createdAt: createdAt, text: "Cześć, świecie")
        first.enhancedText = "Cześć \"świecie\"!"
        let second = Self.record(duration: 1, createdAt: createdAt.addingTimeInterval(60), text: "drugi\nwiersz")
        let ignored = Self.record(createdAt: createdAt.addingTimeInterval(120), text: "nie eksportuj")
        for record in [first, second, ignored] { try await db.save(record) }

        let csv = try await db.csv(ids: [first.id, second.id])
        #expect(csv.hasPrefix(CSV.bom))
        let expected = CSV.bom
            + "id,createdAt,duration,text,enhancedText,model,status\n"
            + "\(second.id.uuidString),2027-01-15T08:01:00Z,1.0,\"drugi\nwiersz\",,parakeet-tdt-0.6b-v3,completed\n"
            + "\(first.id.uuidString),2027-01-15T08:00:00Z,2.5,\"Cześć, świecie\",\"Cześć \"\"świecie\"\"!\",parakeet-tdt-0.6b-v3,completed\n"
        #expect(csv == expected)
        #expect(!csv.contains("nie eksportuj"))
        #expect(try await db.csv(ids: []) == CSV.bom + "id,createdAt,duration,text,enhancedText,model,status\n")
    }

    // MARK: Store

    @Test func storeOpensAtCustomURLAndFallsBackInMemory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let opened = Store.makeContainer(url: directory.appending(path: "nested/Captylo.store"))
        #expect(opened.isFallback == false)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "nested/Captylo.store").path))

        // A directory where the store file should be cannot be opened as SQLite.
        let blocked = directory.appending(path: "blocked.store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let fallback = Store.makeContainer(url: blocked)
        #expect(fallback.isFallback == true)
    }
}
