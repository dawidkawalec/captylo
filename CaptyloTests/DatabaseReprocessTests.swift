import Foundation
import Testing
@testable import Captylo

/// Router that must never be called ("Przetwórz przez AI" never transcribes again).
private final class ReprocessUnusedRouter: TranscriptionRouting, Sendable {
    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        Issue.record("reprocess must not transcribe")
        throw DictationError.emptyResult
    }
}

@MainActor
private final class ReprocessFakeOutput: TextDelivering {
    func deliver(_ text: String, _ settings: OutputSettings) async -> OutputResult { .pasted }
    func copy(_ text: String) {}
}

@MainActor
private final class ReprocessBumpCounter {
    var value = 0
}

@MainActor
struct DatabaseReprocessTests {
    private struct Harness {
        let database: Database
        let actions: HistoryActions
        let enhancer: ModeTesterFakeEnhancer
        let bumps: @MainActor () -> Int
    }

    private static func makeHarness(outcome: EnhancementOutcome) throws -> Harness {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let enhancer = ModeTesterFakeEnhancer(outcome: outcome)
        let counter = ReprocessBumpCounter()
        let actions = HistoryActions(
            database: database,
            output: ReprocessFakeOutput(),
            router: ReprocessUnusedRouter(),
            enhancer: enhancer,
            vocabulary: { ["Captylo"] },
            didChange: { counter.value += 1 }
        )
        return Harness(database: database, actions: actions, enhancer: enhancer, bumps: { counter.value })
    }

    private static func savedRecord(in database: Database) async throws -> DictationRecord {
        let record = DictationRecord(
            text: "no więc jutro spotkanie z martą w sprawie oferty",
            status: .completed,
            audioDuration: 4,
            modelName: "Parakeet v3",
            enhancementMode: "Czyszczenie",
            enhancementNote: EnhancementFailure.deadline(seconds: 3).note,
            wordCount: 9
        )
        try await database.save(record)
        return record
    }

    @Test func reprocessUpdatesTheSameRowWithoutAUsageStat() async throws {
        let harness = try Self.makeHarness(outcome: .enhanced(text: "Tomorrow: meeting with Marta about the offer.", ms: 810, model: "openai/gpt-4.1-mini"))
        let record = try await Self.savedRecord(in: harness.database)
        let before = try await harness.database.dashboard(days: 7)

        let error = await harness.actions.reprocessWithAI(id: record.id, mode: BuiltInAIModes.english)
        #expect(error == nil)

        let updated = try #require(await harness.database.record(id: record.id))
        #expect(updated.id == record.id)
        #expect(updated.text == record.text, "the original stays")
        #expect(updated.enhancedText == "Tomorrow: meeting with Marta about the offer.")
        #expect(updated.enhancementMode == BuiltInAIModes.english.name)
        #expect(updated.enhancementModel == "openai/gpt-4.1-mini")
        #expect(updated.enhancementMs == 810)
        #expect(updated.enhancementNote == nil)
        #expect(updated.wordCount == 9)
        #expect(updated.createdAt == record.createdAt)
        #expect(await harness.database.count() == 1)

        let after = try await harness.database.dashboard(days: 7)
        #expect(after.sessions == before.sessions)
        #expect(after.words == before.words)
        #expect(harness.bumps() == 1)

        // The mode's prompt with the dictionary, its kind, and the long reprocess deadline.
        let job = try #require(harness.enhancer.lastJob)
        #expect(job.kind == .rewrite)
        #expect(job.deadline == nil)
        #expect(job.systemPrompt == BuiltInAIModes.english.systemPrompt(vocabulary: ["Captylo"]))
    }

    @Test func failureKeepsTheRowAndReturnsTheMessage() async throws {
        let harness = try Self.makeHarness(outcome: .skipped(.noKey))
        let record = try await Self.savedRecord(in: harness.database)

        let error = await harness.actions.reprocessWithAI(id: record.id, mode: BuiltInAIModes.cleanup)
        #expect(error == OpenRouterError.missingKey.errorDescription)
        #expect(await harness.database.record(id: record.id) == record)
        #expect(harness.bumps() == 0)
    }

    @Test func http401IsReportedInPolish() async throws {
        let harness = try Self.makeHarness(outcome: .failed(.http(status: 401), ms: 200))
        let record = try await Self.savedRecord(in: harness.database)
        let error = await harness.actions.reprocessWithAI(id: record.id, mode: BuiltInAIModes.email)
        #expect(error == OpenRouterError.unauthorized.errorDescription)
    }

    @Test func missingOrFailedRowsAreRefused() async throws {
        let harness = try Self.makeHarness(outcome: .enhanced(text: "x", ms: 1, model: "m"))
        #expect(await harness.actions.reprocessWithAI(id: UUID(), mode: BuiltInAIModes.cleanup) == DatabaseError.notFound(UUID()).errorDescription)

        let failed = DictationRecord(text: "", status: .failed, errorMessage: "Błąd", audioDuration: 2)
        try await harness.database.save(failed)
        #expect(await harness.actions.reprocessWithAI(id: failed.id, mode: BuiltInAIModes.cleanup) == String(localized: "Ten wpis nie ma tekstu do przetworzenia."))
        #expect(harness.enhancer.calls == 0)
    }

    @Test func updateEnhancementTouchesOnlyTheAIFields() async throws {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let record = DictationRecord(text: "raz dwa trzy cztery", status: .completed, audioDuration: 2, wordCount: 4)
        try await database.save(record)

        var change = record
        change.text = "ZMIENIONE"
        change.wordCount = 99
        change.enhancedText = "Raz, dwa, trzy, cztery."
        change.enhancementMode = "Czyszczenie"
        change.enhancementNote = nil
        try await database.updateEnhancement(change)

        let stored = try #require(await database.record(id: record.id))
        #expect(stored.text == "raz dwa trzy cztery")
        #expect(stored.wordCount == 4)
        #expect(stored.enhancedText == "Raz, dwa, trzy, cztery.")
        #expect(stored.enhancementMode == "Czyszczenie")

        await #expect(throws: DatabaseError.notFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            var ghost = record
            ghost.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            try await database.updateEnhancement(ghost)
        }
    }

    @Test func modeAndNoteRoundTripThroughTheStore() async throws {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let record = DictationRecord(
            text: "raz dwa trzy",
            status: .completed,
            enhancementMode: "Lista zadań",
            enhancementNote: EnhancementSkip.tooShort.note,
            wordCount: 3
        )
        try await database.save(record)
        #expect(await database.record(id: record.id) == record)
    }
}
