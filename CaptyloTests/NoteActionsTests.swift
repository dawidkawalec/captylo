import Foundation
import os
import Testing
@testable import Captylo

private final class NotesFakeRouter: TranscriptionRouting, Sendable {
    private let text: String
    private let failure: DictationError?

    init(text: String = "przepisany tekst", failure: DictationError? = nil) {
        self.text = text
        self.failure = failure
    }

    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        if let failure { throw failure }
        return TranscriptionResult(text: text, modelName: "fake-model", ms: 5)
    }
}

private final class NotesFakeEnhancer: TextEnhancing, Sendable {
    private let outcome: EnhancementOutcome
    private let jobs = OSAllocatedUnfairLock<[EnhancementJob]>(initialState: [])

    init(_ outcome: EnhancementOutcome) {
        self.outcome = outcome
    }

    var lastJob: EnhancementJob? { jobs.withLock { $0.last } }

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        jobs.withLock { $0.append(job) }
        return outcome
    }

    func prewarm() async {}
}

/// Enhancer fake that runs `during` while the "model" thinks (the user edits the note meanwhile).
private final class NotesSlowEnhancer: TextEnhancing, Sendable {
    private let during: @Sendable () async -> Void

    init(during: @escaping @Sendable () async -> Void) {
        self.during = during
    }

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        await during()
        return .enhanced(text: "- wynik AI", ms: 1, model: "m")
    }

    func prewarm() async {}
}

@MainActor
struct NoteActionsTests {
    /// The user typed while the AI ran: their text stays, the AI result is not forced over it.
    @Test func anAIPassNeverOverwritesTextChangedDuringTheWait() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let note = NoteRecord(body: "pierwsza wersja")
        try await db.createNote(note)
        let id = note.id
        let actions = NoteActions(
            database: db,
            router: NotesFakeRouter(),
            enhancer: NotesSlowEnhancer(during: { _ = try? await db.modifyNote(id: id) { $0.body = "pierwsza wersja i dopisek" } }),
            vocabulary: { [] },
            processor: { Self.processor },
            engine: { .local },
            language: { "pl" },
            didChange: {}
        )
        #expect(await actions.applyAI(noteID: id, mode: BuiltInAIModes.english) != nil)
        let read = try #require(try await db.note(id: id))
        #expect(read.body == "pierwsza wersja i dopisek")
        #expect(read.originalBody == nil)
        #expect(read.aiMode == nil)
    }

    /// A retried transcription adds its text under what the user already typed into the note.
    @Test func retryKeepsTextTypedIntoTheFailedNote() async throws {
        let (actions, db) = try Self.make()
        let note = NoteRecord(body: "Moja uwaga.", audioFileName: "v.wav", audioDuration: 1, transcriptError: "Brak internetu")
        try await db.createNote(note)
        #expect(await actions.retryTranscription(noteID: note.id) == nil)
        let read = try #require(try await db.note(id: note.id))
        #expect(read.body == "Moja uwaga.\n\n" + Self.processor.process("przepisany tekst", language: "pl"))
    }

    private static let processor = TextProcessor(dictionary: .default, paragraphs: true)

    private static func make(
        enhancer: NotesFakeEnhancer = NotesFakeEnhancer(.enhanced(text: "- punkt pierwszy", ms: 1, model: "m")),
        router: NotesFakeRouter = NotesFakeRouter(),
        removed: OSAllocatedUnfairLock<[String]> = .init(initialState: [])
    ) throws -> (NoteActions, Database) {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let actions = NoteActions(
            database: db,
            router: router,
            enhancer: enhancer,
            vocabulary: { [] },
            processor: { Self.processor },
            engine: { .local },
            language: { "pl" },
            decode: { _ in ([Float](repeating: 0.1, count: 16_000), 1.0) },
            removeFile: { name in removed.withLock { $0.append(name) } },
            didChange: {}
        )
        return (actions, db)
    }

    @Test func aiKeepsTheUsersTextOnceAndRestoreBringsItBack() async throws {
        let enhancer = NotesFakeEnhancer(.enhanced(text: "- punkt pierwszy", ms: 1, model: "m"))
        let (actions, db) = try Self.make(enhancer: enhancer)
        let note = NoteRecord(body: "punkt pierwszy i jeszcze coś")
        try await db.createNote(note)
        #expect(await actions.applyAI(noteID: note.id, mode: BuiltInAIModes.english) == nil)
        // A second pass runs on the AI text but never overwrites the user's own text.
        #expect(await actions.applyAI(noteID: note.id, mode: BuiltInAIModes.english) == nil)
        #expect(enhancer.lastJob?.deadline == nil)
        let tidied = try #require(try await db.note(id: note.id))
        #expect(tidied.body == "- punkt pierwszy")
        #expect(tidied.originalBody == "punkt pierwszy i jeszcze coś")
        #expect(tidied.aiMode == BuiltInAIModes.english.name)

        await actions.restoreOriginal(noteID: note.id)
        let restored = try #require(try await db.note(id: note.id))
        #expect(restored.body == "punkt pierwszy i jeszcze coś")
        #expect(restored.originalBody == nil)
        #expect(restored.aiMode == nil)
    }

    @Test func aFailedAIPassLeavesTheBodyAndReturnsTheMessage() async throws {
        let (actions, db) = try Self.make(enhancer: NotesFakeEnhancer(.failed(.http(status: 401), ms: 0)))
        let note = NoteRecord(body: "treść")
        try await db.createNote(note)
        #expect(await actions.applyAI(noteID: note.id, mode: BuiltInAIModes.english) != nil)
        let read = try #require(try await db.note(id: note.id))
        #expect(read.body == "treść")
        #expect(read.originalBody == nil)
    }

    @Test func anEmptyNoteIsNotSentToTheAI() async throws {
        let enhancer = NotesFakeEnhancer(.enhanced(text: "x", ms: 1, model: "m"))
        let (actions, db) = try Self.make(enhancer: enhancer)
        let note = NoteRecord(body: "  \n ")
        try await db.createNote(note)
        #expect(await actions.applyAI(noteID: note.id, mode: BuiltInAIModes.english) != nil)
        #expect(enhancer.lastJob == nil)
    }

    @Test func deleteRemovesTheAudioFileOnlyWhenThereIsOne() async throws {
        let removed = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (actions, db) = try Self.make(removed: removed)
        let voice = NoteRecord(body: "x", audioFileName: "abc.wav")
        let typed = NoteRecord(body: "y")
        try await db.createNote(voice)
        try await db.createNote(typed)
        await actions.delete(noteID: voice.id)
        await actions.delete(noteID: typed.id)
        #expect(removed.withLock { $0 } == ["abc.wav"])
        #expect(try await db.note(id: voice.id) == nil)
        #expect(try await db.note(id: typed.id) == nil)
    }

    @Test func retryFillsTheBodyOfAFailedVoiceNote() async throws {
        let (actions, db) = try Self.make()
        let note = NoteRecord(body: "", audioFileName: "v.wav", audioDuration: 1, transcriptError: "Brak internetu")
        try await db.createNote(note)
        #expect(await actions.retryTranscription(noteID: note.id) == nil)
        let read = try #require(try await db.note(id: note.id))
        #expect(read.body == Self.processor.process("przepisany tekst", language: "pl"))
        #expect(!read.body.isEmpty)
        #expect(read.transcriptError == nil)
        #expect(read.transcriptModel == "fake-model")
    }

    @Test func aFailedRetryKeepsTheAudioAndUpdatesTheError() async throws {
        let (actions, db) = try Self.make(router: NotesFakeRouter(failure: .emptyResult))
        let note = NoteRecord(body: "", audioFileName: "v.wav", audioDuration: 1, transcriptError: "Brak internetu")
        try await db.createNote(note)
        #expect(await actions.retryTranscription(noteID: note.id) != nil)
        let read = try #require(try await db.note(id: note.id))
        #expect(read.body.isEmpty)
        #expect(read.audioFileName == "v.wav")
        #expect(read.transcriptError != nil)
        #expect(read.transcriptError != "Brak internetu")
    }
}
