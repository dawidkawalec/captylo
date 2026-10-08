import Foundation
import os
import Testing
@testable import Captylo

private final class TitleFakeEnhancer: TextEnhancing, Sendable {
    private let outcome: EnhancementOutcome
    private let jobs = OSAllocatedUnfairLock<[EnhancementJob]>(initialState: [])

    init(_ outcome: EnhancementOutcome) {
        self.outcome = outcome
    }

    var calls: Int { jobs.withLock { $0.count } }
    var lastJob: EnhancementJob? { jobs.withLock { $0.last } }

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        jobs.withLock { $0.append(job) }
        return outcome
    }

    func prewarm() async {}
}

private final class TitleNoRouter: TranscriptionRouting, Sendable {
    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        throw DictationError.emptyResult
    }
}

struct NoteTitlesTests {
    @Test func theLocalTitleIsTheFirstSentenceCutToAFewWords() {
        #expect(NoteTitles.local(from: "Kupić mleko.\nZadzwonić do Ani.") == "Kupić mleko")
        #expect(NoteTitles.local(from: "  \n Kod do bramy: 4512! Wejście od podwórza.") == "Kod do bramy: 4512")
        #expect(NoteTitles.local(from: "Pomysł na kampanię jesienną krótkie filmy z klientami którzy dyktują maile")
            == "Pomysł na kampanię jesienną krótkie filmy…")
        #expect(NoteTitles.local(from: "   ") == "")
    }

    @Test func anAITitleIsCleanedToOneShortLine() {
        #expect(NoteTitles.clean("„Kampania jesienna”.") == "Kampania jesienna")
        #expect(NoteTitles.clean("Tytuł: Plan na czwartek\nCoś jeszcze") == "Plan na czwartek")
        #expect(NoteTitles.clean("\"Zakupy\"") == "Zakupy")
        #expect(NoteTitles.clean("   ") == nil)
        #expect(NoteTitles.clean(String(repeating: "a", count: 200))?.count == NoteTitles.maxLength)
    }
}

@MainActor
struct NoteTitleActionsTests {
    private static func make(
        _ enhancer: TitleFakeEnhancer, aiAllowed: Bool
    ) throws -> (NoteActions, Database) {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let actions = NoteActions(
            database: db,
            router: TitleNoRouter(),
            enhancer: enhancer,
            vocabulary: { [] },
            processor: { TextProcessor(dictionary: .default, paragraphs: true) },
            engine: { .local },
            language: { "pl" },
            titleAI: { aiAllowed },
            didChange: {}
        )
        return (actions, db)
    }

    private static let longBody = "Pomysł na kampanię jesienną: krótkie filmy z klientami, którzy dyktują maile w drodze do pracy."

    @Test func aNoteWithoutATitleGetsTheAITitleOnce() async throws {
        let enhancer = TitleFakeEnhancer(.enhanced(text: "„Kampania jesienna”.", ms: 1, model: "m"))
        let (actions, db) = try Self.make(enhancer, aiAllowed: true)
        let note = NoteRecord(body: Self.longBody)
        try await db.createNote(note)
        await actions.ensureTitle(noteID: note.id)
        #expect(try await db.note(id: note.id)?.title == "Kampania jesienna")
        #expect(enhancer.lastJob?.kind == .rewrite)
        await actions.ensureTitle(noteID: note.id)
        #expect(enhancer.calls == 1)
    }

    @Test func withoutAIOrWhenItFailsTheTitleIsLocal() async throws {
        let off = TitleFakeEnhancer(.enhanced(text: "x", ms: 1, model: "m"))
        let (actions, db) = try Self.make(off, aiAllowed: false)
        let note = NoteRecord(body: "Kupić mleko i chleb na jutro rano.")
        try await db.createNote(note)
        await actions.ensureTitle(noteID: note.id)
        #expect(try await db.note(id: note.id)?.title == "Kupić mleko i chleb na jutro…")
        #expect(off.calls == 0)

        let failing = TitleFakeEnhancer(.failed(.http(status: 500), ms: 0))
        let (second, secondDB) = try Self.make(failing, aiAllowed: true)
        let other = NoteRecord(body: "Kupić mleko i chleb.")
        try await secondDB.createNote(other)
        await second.ensureTitle(noteID: other.id)
        #expect(try await secondDB.note(id: other.id)?.title == "Kupić mleko i chleb")
    }

    @Test func aTypedTitleOrAnEmptyNoteIsLeftAlone() async throws {
        let enhancer = TitleFakeEnhancer(.enhanced(text: "Inny", ms: 1, model: "m"))
        let (actions, db) = try Self.make(enhancer, aiAllowed: true)
        let typed = NoteRecord(title: "Mój tytuł", body: Self.longBody)
        let empty = NoteRecord(body: "  ")
        try await db.createNote(typed)
        try await db.createNote(empty)
        await actions.ensureTitle(noteID: typed.id)
        await actions.ensureTitle(noteID: empty.id)
        #expect(try await db.note(id: typed.id)?.title == "Mój tytuł")
        #expect(try await db.note(id: empty.id)?.title == "")
        #expect(enhancer.calls == 0)
    }

    /// A very short note needs no AI: its words are the title.
    @Test func aShortNoteIsTitledLocallyWithoutAI() async throws {
        let enhancer = TitleFakeEnhancer(.enhanced(text: "Inny", ms: 1, model: "m"))
        let (actions, db) = try Self.make(enhancer, aiAllowed: true)
        let note = NoteRecord(body: "Kod 4512")
        try await db.createNote(note)
        await actions.ensureTitle(noteID: note.id)
        #expect(try await db.note(id: note.id)?.title == "Kod 4512")
        #expect(enhancer.calls == 0)
    }
}
