import Foundation
import SwiftData
import Testing
@testable import Captylo

/// The store schema before "Tryby AI" (no `enhancementMode` / `enhancementNote`), frozen here
/// so the lightweight migration of a real on-disk store can be tested. Entity names match the
/// app's (`Dictation`, `UsageStat`), like a `VersionedSchema` would declare them.
enum CaptyloStoreSchemaV1 {
    @Model
    final class Dictation {
        @Attribute(.unique) var id: UUID = UUID()
        var createdAt: Date = Date()
        var text: String = ""
        var enhancedText: String? = nil
        var status: String = "completed"
        var errorMessage: String? = nil
        var source: String = "dictation"
        var audioDuration: Double = 0
        var audioFileName: String? = nil
        var language: String? = nil
        var modelName: String? = nil
        var transcriptionMs: Int? = nil
        var enhancementModel: String? = nil
        var enhancementMs: Int? = nil
        var wordCount: Int = 0

        init(id: UUID, createdAt: Date, text: String, enhancedText: String?, audioDuration: Double, enhancementModel: String?, wordCount: Int) {
            self.id = id
            self.createdAt = createdAt
            self.text = text
            self.enhancedText = enhancedText
            self.audioDuration = audioDuration
            self.enhancementModel = enhancementModel
            self.wordCount = wordCount
        }
    }

    @Model
    final class UsageStat {
        var dictationID: UUID = UUID()
        var createdAt: Date = Date()
        var wordCount: Int = 0
        var audioDuration: Double = 0
        var source: String = "dictation"

        init(dictationID: UUID, createdAt: Date, wordCount: Int, audioDuration: Double) {
            self.dictationID = dictationID
            self.createdAt = createdAt
            self.wordCount = wordCount
            self.audioDuration = audioDuration
        }
    }

    static var schema: Schema { Schema([Dictation.self, UsageStat.self]) }

    static func container(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            Store.configurationName,
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

@Suite(.serialized)
struct DatabaseMigrationTests {
    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Writes `count` rows (every second one with an AI version) and their stats with the old schema.
    private static func seedOldStore(at url: URL, count: Int) throws -> [UUID] {
        let container = try CaptyloStoreSchemaV1.container(at: url)
        let context = ModelContext(container)
        var ids: [UUID] = []
        for index in 0..<count {
            let id = UUID()
            ids.append(id)
            let enhanced = index.isMultiple(of: 2) ? "Tekst \(index) po AI." : nil
            context.insert(CaptyloStoreSchemaV1.Dictation(
                id: id,
                createdAt: base.addingTimeInterval(Double(index) * 60),
                text: "tekst \(index) oryginał",
                enhancedText: enhanced,
                audioDuration: 2 + Double(index),
                enhancementModel: enhanced == nil ? nil : "openai/gpt-4.1-mini",
                wordCount: 3
            ))
            context.insert(CaptyloStoreSchemaV1.UsageStat(
                dictationID: id,
                createdAt: base.addingTimeInterval(Double(index) * 60),
                wordCount: 3,
                audioDuration: 2 + Double(index)
            ))
        }
        try context.save()
        return ids
    }

    @Test func oldStoreOpensWithTheNewSchemaAndKeepsEveryRow() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: Store.configurationName + ".store")
        let ids = try Self.seedOldStore(at: url, count: 7)

        // Same code path as the app's launch (`Store.makeContainer` minus the data directory).
        let database = Database(modelContainer: try Store.openContainer(at: url))
        #expect(await database.count() == 7)
        let snapshot = try await database.dashboard(days: 30, now: Self.base.addingTimeInterval(3600))
        #expect(snapshot.sessions == 7)
        #expect(snapshot.words == 21)

        let first = try #require(await database.record(id: ids[0]))
        #expect(first.text == "tekst 0 oryginał")
        #expect(first.enhancedText == "Tekst 0 po AI.")
        #expect(first.enhancementModel == "openai/gpt-4.1-mini")
        #expect(first.enhancementMode == nil)
        #expect(first.enhancementNote == nil)
        #expect(first.createdAt == Self.base)

        // The new columns take values and keep them across a reopen.
        var changed = first
        changed.applyEnhancement(.enhanced(text: "Text 0 in English.", ms: 700, model: "m"), mode: "Po angielsku")
        try await database.updateEnhancement(changed)
        let second = try #require(await database.record(id: ids[1]))
        var noted = second
        noted.applyEnhancement(.failed(.deadline(seconds: 3), ms: 3000), mode: "Czyszczenie")
        try await database.updateEnhancement(noted)

        let reopened = Database(modelContainer: try Store.openContainer(at: url))
        #expect(await reopened.count() == 7)
        #expect(await reopened.record(id: ids[0])?.enhancementMode == "Po angielsku")
        #expect(await reopened.record(id: ids[0])?.enhancedText == "Text 0 in English.")
        #expect(await reopened.record(id: ids[1])?.enhancementNote == EnhancementFailure.deadline(seconds: 3).note)
        #expect(await reopened.record(id: ids[1])?.text == "tekst 1 oryginał")
    }

    /// Today's `Dictation` and `UsageStat` without the meeting tables: the store every
    /// install had before meetings.
    private static func preMeetingContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Dictation.self, UsageStat.self])
        let configuration = ModelConfiguration(
            Store.configurationName,
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    @Test func storeWithoutMeetingsOpensWithTheMeetingTables() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: Store.configurationName + ".store")
        let record = DictationRecord(text: "przed spotkaniami", status: .completed, audioDuration: 2, wordCount: 2)
        do {
            let old = Database(modelContainer: try Self.preMeetingContainer(at: url))
            try await old.save(record)
        }

        // Same code path as the app's launch (`Store.makeContainer` minus the data directory).
        let database = Database(modelContainer: try Store.openContainer(at: url))
        #expect(await database.count() == 1)
        #expect(try await database.meetings(query: "", limit: 1).isEmpty)
        #expect(try await database.markInterruptedMeetings().isEmpty)

        let meeting = MeetingRecord(title: "Pierwsze spotkanie")
        try await database.createMeeting(meeting)
        try await database.appendSegment(
            MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 1, text: "dzień dobry")
        )

        let reopened = Database(modelContainer: try Store.openContainer(at: url))
        #expect(await reopened.record(id: record.id)?.text == "przed spotkaniami")
        #expect(try await reopened.meeting(id: meeting.id)?.title == "Pierwsze spotkanie")
        #expect(try await reopened.segments(meetingID: meeting.id).map(\.text) == ["dzień dobry"])
        #expect(try await reopened.meetings(query: "dzien dobry", limit: 5).map(\.id) == [meeting.id])
    }

    /// Rolling back to a build without meetings must not lose the history: the pre-meeting
    /// schema opens a store that already has the meeting tables.
    @Test func storeWithMeetingsStillOpensWithThePreMeetingSchema() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: Store.configurationName + ".store")
        let record = DictationRecord(text: "dyktowanie", status: .completed, audioDuration: 1, wordCount: 1)
        do {
            let database = Database(modelContainer: try Store.openContainer(at: url))
            try await database.save(record)
            try await database.createMeeting(MeetingRecord(title: "Spotkanie"))
        }

        let old = try Self.preMeetingContainer(at: url)
        let context = ModelContext(old)
        #expect(try context.fetchCount(FetchDescriptor<Dictation>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<UsageStat>()) == 1)
    }

    /// Rolling back to a build without "Tryby AI" must not lose the history: the old schema
    /// opens a migrated store (the two new columns are simply ignored).
    @Test func migratedStoreStillOpensWithTheOldSchema() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: Store.configurationName + ".store")
        _ = try Self.seedOldStore(at: url, count: 3)
        do {
            let container = try Store.openContainer(at: url)
            let context = ModelContext(container)
            #expect(try context.fetchCount(FetchDescriptor<Dictation>()) == 3)
        }

        let old = try CaptyloStoreSchemaV1.container(at: url)
        let context = ModelContext(old)
        #expect(try context.fetchCount(FetchDescriptor<CaptyloStoreSchemaV1.Dictation>()) == 3)
    }
}
