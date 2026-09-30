import Darwin
import Foundation
import SwiftData
import Testing
@testable import Captylo

/// End to end on fake old stores in a temp folder: two sources, fake recordings, an in-memory
/// Captylo store and a temp dictionary.
@MainActor
struct LegacyImporterTests {
    // Fixed ids of the fake rows.
    static let completedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let failedID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let pendingID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let emptyID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let enhancedID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static let enhancementFailedID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    static let missingAudioID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    static let duplicateID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    static let oldRuleID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    static let secondSourceID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!

    /// Temp world of one test: two old installations and the Captylo side.
    struct World {
        let root: URL
        let sources: [LegacySource]
        let recordings: URL
        let database: Database
        let container: ModelContainer
        let dictionary: DictionaryStore
        let noIDPK: Int64 = 8

        var mainRecordings: URL { sources[0].recordingsURL }
        var secondRecordings: URL { sources[1].recordingsURL }

        func importer() -> LegacyImporter {
            let dictionary = self.dictionary
            return LegacyImporter(
                sources: sources,
                database: database,
                recordingsDirectory: recordings,
                tempRoot: root.appending(path: "tmp", directoryHint: .isDirectory),
                mergeDictionary: { words, rules in
                    await MainActor.run { dictionary.mergeImported(vocabulary: words, rules: rules) }
                }
            )
        }

        func usageStats() throws -> [UsageStat] {
            try ModelContext(container).fetch(FetchDescriptor<UsageStat>())
        }

        func dictations() throws -> [Dictation] {
            try ModelContext(container).fetch(FetchDescriptor<Dictation>())
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func fileURL(_ folder: URL, _ name: String) -> String {
        folder.appending(path: name).absoluteString
    }

    /// ~12 varied rows in the main store, 2 in the second one, fake WAVs, a dictionary store.
    static func makeWorld() throws -> World {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "captylo-legacy-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let main = LegacySource(
            name: "VocaType",
            storeURL: root.appending(path: "com.dawidkawalec.VocaType/default.store"),
            dictionaryStoreURL: root.appending(path: "com.dawidkawalec.VocaType/dictionary.store"),
            recordingsURL: root.appending(path: "com.prakashjoshipax.VocaType/Recordings", directoryHint: .isDirectory)
        )
        let second = LegacySource(
            name: "VoiceInk",
            storeURL: root.appending(path: "com.prakashjoshipax.VoiceInk/default.store"),
            dictionaryStoreURL: root.appending(path: "com.prakashjoshipax.VoiceInk/dictionary.store"),
            recordingsURL: root.appending(path: "com.prakashjoshipax.VoiceInk/Recordings", directoryHint: .isDirectory)
        )
        for folder in [main.recordingsURL, second.recordingsURL] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("RIFF-a1".utf8).write(to: main.recordingsURL.appending(path: "A 1.wav"))
        try Data("RIFF-a2".utf8).write(to: main.recordingsURL.appending(path: "A2.wav"))
        try Data("RIFF-b1".utf8).write(to: second.recordingsURL.appending(path: "B1.wav"))

        let store = try LegacyTestStore(url: main.storeURL)
        let t0 = 788_745_334.0
        let rows: [LegacyRow] = [
            LegacyRow(pk: 1, id: completedID, timestamp: t0, duration: 3.5, transcriptionDuration: 0.42,
                      text: "raz dwa trzy", status: "completed",
                      audioFileURL: fileURL(main.recordingsURL, "A 1.wav"), transcriptionModelName: "Parakeet V3"),
            LegacyRow(pk: 2, id: failedID, timestamp: t0 + 10, duration: 2,
                      text: "Transcription Failed: The core transcription engine failed.", status: "failed",
                      audioFileURL: fileURL(main.recordingsURL, "A2.wav")),
            LegacyRow(pk: 3, id: pendingID, timestamp: t0 + 20, duration: 4, text: "czekało ale jest", status: "pending"),
            LegacyRow(pk: 4, id: emptyID, timestamp: t0 + 30, duration: 1, text: "   ", status: "completed"),
            LegacyRow(pk: 5, id: UUID(), timestamp: t0 + 40, text: "[PREWARM] ", status: "pending"),
            LegacyRow(pk: 6, id: enhancedID, timestamp: t0 + 50, duration: 6, transcriptionDuration: 0.5, enhancementDuration: 1.25,
                      text: "to jest tekst", enhancedText: "To jest poprawiony tekst.", status: "completed",
                      transcriptionModelName: "Soniox (stt-async-v3)", enhancementModelName: "gemini-2.5-flash", promptName: "Default"),
            LegacyRow(pk: 7, id: enhancementFailedID, timestamp: t0 + 60, duration: 2, enhancementDuration: 3,
                      text: "a b", enhancedText: "Enhancement failed: networkError", status: "completed",
                      enhancementModelName: "gpt-5.1", powerModeName: "Mail"),
            LegacyRow(pk: 8, id: nil, timestamp: t0 + 70, duration: 1, text: "bez identyfikatora", status: "completed"),
            LegacyRow(pk: 9, id: missingAudioID, timestamp: t0 + 80, duration: 5, text: "nagranie zginęło", status: "completed",
                      audioFileURL: fileURL(main.recordingsURL, "missing.wav")),
            LegacyRow(pk: 10, id: duplicateID, timestamp: t0 + 90, duration: 1, text: "z pierwszego źródła", status: "completed"),
            LegacyRow(pk: 11, id: oldRuleID, timestamp: t0 + 100, duration: 1, text: "jeden  dwa\ntrzy", status: "completed"),
            LegacyRow(pk: 12, id: UUID(), timestamp: t0 + 110, text: nil, status: "pending"),
        ]
        for row in rows {
            try store.insert(row)
        }
        store.close()

        let dictionaryStore = try LegacyTestStore(url: try #require(main.dictionaryStoreURL))
        try dictionaryStore.insertWord("Captylo", date: 1)
        try dictionaryStore.insertWord("Kawalec", date: 2)
        try dictionaryStore.insertReplacement("kaptylo, kapitylo", "Captylo")
        try dictionaryStore.insertReplacement("kaptilo", "Captylo")
        try dictionaryStore.insertReplacement("foo", "bar", enabled: false)
        dictionaryStore.close()

        let secondStore = try LegacyTestStore(url: second.storeURL)
        try secondStore.insert(LegacyRow(pk: 1, id: duplicateID, timestamp: t0 - 100, text: "z drugiego źródła", status: "completed"))
        try secondStore.insert(LegacyRow(pk: 2, id: secondSourceID, timestamp: t0 - 50, duration: 2, text: "drugie źródło",
                                         status: "completed", audioFileURL: fileURL(second.recordingsURL, "B1.wav")))
        try secondStore.insertWord("captylo")
        secondStore.close()

        let container = try Store.makeInMemoryContainer()
        let dictionary = DictionaryStore(fileURL: root.appending(path: "captylo/dictionary.json"), paragraphs: false)
        return World(
            root: root,
            sources: [main, second],
            recordings: root.appending(path: "captylo/Recordings", directoryHint: .isDirectory),
            database: Database(modelContainer: container),
            container: container,
            dictionary: dictionary
        )
    }

    private static func inode(_ url: URL) -> (ino: UInt64, links: UInt16)? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt16(info.st_nlink))
    }

    // MARK: Tests

    @Test func importsMapsAndCounts() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }

        let report = try await world.importer().run(dryRun: false)

        #expect(report.dryRun == false)
        #expect(report.sourcesFound == 2)
        #expect(report.rowsFound == 14)
        #expect(report.imported == 10)
        #expect(report.skippedExisting == 0)
        #expect(report.skippedDuplicate == 1)
        #expect(report.importableRows == 10)
        #expect(report.skippedEmpty == 2)
        #expect(report.skippedPrewarm == 1)
        #expect(report.failedRowsImported == 1)
        #expect(report.withAI == 1)
        #expect(report.usageStatsAdded == 9)
        #expect(report.audioLinked == 3)
        #expect(report.audioMissing == 1)
        #expect(report.audioNotLinkable == 0)
        #expect(report.recordingsFound == 3)
        #expect(report.vocabularyAdded == 2)
        #expect(report.rulesAdded == 1)
        // raz dwa trzy (3) + czekało ale jest (3) + To jest poprawiony tekst. (4) + a b (2)
        // + bez identyfikatora (2) + nagranie zginęło (2) + z pierwszego źródła (3)
        // + "jeden  dwa\ntrzy" (2, old rule) + drugie źródło (2)
        #expect(report.totalWords == 23)
        #expect(report.wordsFound == 23)

        // Rows.
        let completed = try #require(await world.database.record(id: Self.completedID))
        #expect(completed.text == "raz dwa trzy")
        #expect(completed.status == .completed)
        #expect(completed.source == .imported)
        #expect(completed.createdAt == Date(timeIntervalSinceReferenceDate: 788_745_334))
        #expect(completed.audioDuration == 3.5)
        #expect(completed.transcriptionMs == 420)
        #expect(completed.modelName == "Parakeet V3")
        #expect(completed.audioFileName == "A 1.wav")
        #expect(completed.wordCount == 3)

        let failed = try #require(await world.database.record(id: Self.failedID))
        #expect(failed.status == .failed)
        #expect(failed.text == "")
        #expect(failed.errorMessage == "Transcription Failed: The core transcription engine failed.")
        #expect(failed.audioFileName == "A2.wav")

        #expect(await world.database.record(id: Self.pendingID)?.status == .completed)
        #expect(await world.database.record(id: Self.emptyID) == nil)

        let enhanced = try #require(await world.database.record(id: Self.enhancedID))
        #expect(enhanced.enhancedText == "To jest poprawiony tekst.")
        #expect(enhanced.enhancementModel == "gemini-2.5-flash")
        #expect(enhanced.enhancementMs == 1250)
        #expect(enhanced.enhancementMode == "Default")
        #expect(enhanced.wordCount == 4)

        let enhancementFailed = try #require(await world.database.record(id: Self.enhancementFailedID))
        #expect(enhancementFailed.enhancedText == nil)
        #expect(enhancementFailed.enhancementNote == "Enhancement failed: networkError")
        #expect(enhancementFailed.enhancementMode == "Mail")

        let noID = LegacyMapper.deterministicID(sourcePath: world.sources[0].storePath, pk: world.noIDPK)
        #expect(await world.database.record(id: noID)?.text == "bez identyfikatora")
        #expect(await world.database.record(id: Self.missingAudioID)?.audioFileName == nil)
        #expect(await world.database.record(id: Self.duplicateID)?.text == "z pierwszego źródła")
        #expect(await world.database.record(id: Self.oldRuleID)?.wordCount == 2)
        #expect(await world.database.record(id: Self.secondSourceID)?.audioFileName == "B1.wav")

        // One UsageStat per completed row, same date, words and duration.
        let stats = try world.usageStats()
        #expect(stats.count == 9)
        #expect(Set(stats.map(\.source)) == ["imported"])
        #expect(!stats.contains { $0.dictationID == Self.failedID })
        let completedStat = try #require(stats.first { $0.dictationID == Self.completedID })
        #expect(completedStat.createdAt == completed.createdAt)
        #expect(completedStat.wordCount == 3)
        #expect(completedStat.audioDuration == 3.5)
        #expect(stats.reduce(0) { $0 + $1.wordCount } == report.totalWords)

        // Dictionary merged and deduped (the second source's "captylo" is the same word).
        #expect(world.dictionary.data.vocabulary == ["Captylo", "Kawalec"])
        #expect(world.dictionary.data.replacements.count == 1)
        #expect(world.dictionary.data.replacements.first?.triggers == ["kaptylo", "kapitylo", "kaptilo"])
        #expect(world.dictionary.data.replacements.first?.replacement == "Captylo")
    }

    @Test func recordingsAreHardLinksOfTheOldFiles() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let source = world.mainRecordings.appending(path: "A 1.wav")
        let before = try #require(Self.inode(source))
        #expect(before.links == 1)

        _ = try await world.importer().run(dryRun: false)

        let linked = world.recordings.appending(path: "A 1.wav")
        let after = try #require(Self.inode(source))
        let target = try #require(Self.inode(linked))
        #expect(target.ino == before.ino)
        #expect(after.links == 2)
        #expect(try Data(contentsOf: linked) == Data("RIFF-a1".utf8))
        #expect(Self.inode(world.recordings.appending(path: "B1.wav"))?.ino == Self.inode(world.secondRecordings.appending(path: "B1.wav"))?.ino)

        // Deleting the Captylo copy (Historia delete, retention) leaves the old file in place.
        try FileManager.default.removeItem(at: linked)
        #expect(Self.inode(source)?.links == 1)
        #expect(try Data(contentsOf: source) == Data("RIFF-a1".utf8))
    }

    @Test func secondRunImportsNothingTwice() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let first = try await world.importer().run(dryRun: false)
        let second = try await world.importer().run(dryRun: false)

        #expect(first.imported == 10)
        #expect(second.imported == 0)
        #expect(second.skippedExisting == 10)
        #expect(second.skippedDuplicate == 1)
        #expect(second.importableRows == 10)
        #expect(second.usageStatsAdded == 0)
        #expect(second.audioLinked == 0)
        #expect(second.vocabularyAdded == 0)
        #expect(second.rulesAdded == 0)
        #expect(second.wordsFound == first.wordsFound)
        #expect(try world.dictations().count == 10)
        #expect(try world.usageStats().count == 9)
        #expect(Self.inode(world.mainRecordings.appending(path: "A 1.wav"))?.links == 2)
    }

    @Test func aRowDeletedFromHistoryIsNotImportedAgain() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        _ = try await world.importer().run(dryRun: false)
        _ = try await world.database.delete(ids: [Self.completedID])

        let again = try await world.importer().run(dryRun: false)
        #expect(again.imported == 0)
        #expect(await world.database.record(id: Self.completedID) == nil)
        #expect(try world.usageStats().count == 9)
    }

    @Test func dryRunCountsTheSameAndWritesNothing() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let dictionaryBefore = world.dictionary.data

        let dry = try await world.importer().run(dryRun: true)

        #expect(dry.dryRun)
        #expect(dry.imported == 10)
        #expect(dry.usageStatsAdded == 9)
        #expect(dry.audioLinked == 3)
        #expect(dry.audioMissing == 1)
        #expect(dry.vocabularyAdded == 2)
        #expect(dry.rulesAdded == 1)
        #expect(dry.totalWords == 23)
        #expect(try world.dictations().isEmpty)
        #expect(try world.usageStats().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: world.recordings.path(percentEncoded: false)))
        #expect(Self.inode(world.mainRecordings.appending(path: "A 1.wav"))?.links == 1)
        #expect(world.dictionary.data == dictionaryBefore)
        #expect(!FileManager.default.fileExists(atPath: world.root.appending(path: "captylo/dictionary.json").path(percentEncoded: false)))

        let real = try await world.importer().run(dryRun: false)
        var comparable = real
        comparable.dryRun = true
        comparable.seconds = dry.seconds
        #expect(comparable == dry)
    }

    @Test func existingRecordingWithTheSameNameIsReused() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        try FileManager.default.createDirectory(at: world.recordings, withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: world.recordings.appending(path: "A2.wav"))

        let report = try await world.importer().run(dryRun: false)

        #expect(report.audioLinked == 3)
        #expect(try Data(contentsOf: world.recordings.appending(path: "A2.wav")) == Data("already here".utf8))
        #expect(Self.inode(world.mainRecordings.appending(path: "A2.wav"))?.links == 1)
        #expect(await world.database.record(id: Self.failedID)?.audioFileName == "A2.wav")
    }

    @Test func retentionCutoffSkipsOldRecordings() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let report = try await world.importer().run(dryRun: false, audioCutoff: .distantFuture)
        #expect(report.audioLinked == 0)
        #expect(report.audioSkippedByRetention == 3)
        #expect(report.audioMissing == 1)
        #expect(await world.database.record(id: Self.completedID)?.audioFileName == nil)
        #expect(!FileManager.default.fileExists(atPath: world.recordings.appending(path: "A 1.wav").path(percentEncoded: false)))
    }

    @Test func readsRowsThatLiveOnlyInTheWAL() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let url = world.root.appending(path: "wal/default.store")
        let writer = try LegacyTestStore(url: url, wal: true)
        defer { writer.close() }
        let id = UUID()
        try writer.insert(LegacyRow(pk: 1, id: id, timestamp: 1, text: "tylko w WAL", status: "completed"))
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false) + "-wal"))

        let source = LegacySource(name: "WAL", storeURL: url, dictionaryStoreURL: nil, recordingsURL: world.mainRecordings)
        let importer = LegacyImporter(sources: [source], database: world.database, recordingsDirectory: world.recordings,
                                      tempRoot: world.root.appending(path: "tmp", directoryHint: .isDirectory))
        let report = try await importer.run(dryRun: false)
        #expect(report.imported == 1)
        #expect(await world.database.record(id: id)?.text == "tylko w WAL")
        // The temp copies are gone.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: world.root.appending(path: "tmp").path(percentEncoded: false))) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func progressReachesTheTotal() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let seen = ProgressLog()
        _ = try await world.importer().run(dryRun: true, progress: { processed, total in
            seen.append(processed, total)
        })
        #expect(seen.last == .init(processed: 14, total: 14))
    }

    @Test func noSourcesIsAnError() async throws {
        let container = try Store.makeInMemoryContainer()
        let importer = LegacyImporter(sources: [], database: Database(modelContainer: container))
        await #expect(throws: LegacyImportError.noSources) {
            _ = try await importer.run(dryRun: true)
        }
    }

    @Test func cancelledRunStopsWithCancelled() async throws {
        let world = try Self.makeWorld()
        defer { world.cleanUp() }
        let importer = world.importer()
        let task = Task { try await importer.run(dryRun: false) }
        task.cancel()
        await #expect(throws: LegacyImportError.cancelled) {
            _ = try await task.value
        }
    }
}

/// Thread-safe record of progress callbacks.
final class ProgressLog: @unchecked Sendable {
    struct Entry: Equatable {
        var processed: Int
        var total: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(_ processed: Int, _ total: Int) {
        lock.withLock { entries.append(Entry(processed: processed, total: total)) }
    }

    var last: Entry? {
        lock.withLock { entries.last }
    }
}
