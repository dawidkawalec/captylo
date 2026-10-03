import Foundation
import Testing
@testable import Captylo

/// Launch resume: a meeting a quit left "processing" gets its missing AI steps once, through the
/// recorder's serial post-processing chain, never the diarizer or the cloud pass.
@MainActor
struct MeetingResumeTests {
    private static func environment(db: Database) -> MeetingEnvironment {
        let folder = FileManager.default.temporaryDirectory.appending(path: "meeting-resume-tests-\(UUID().uuidString)")
        return MeetingEnvironment(
            makeMic: { FakeAudioSource() },
            makeSystem: { FakeAudioSource() },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: CountingMeetingTranscriber(),
                                   detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
                                   save: save,
                                   config: .init(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 1_000_000))
            },
            database: db,
            trackURL: { id, track in folder.appending(path: "\(id.uuidString)/\(track.fileName)") },
            expectingSystemAudio: { false },
            language: { "pl" },
            setMuteSuppressed: { _ in },
            postProcessors: []
        )
    }

    private static func processingMeeting(_ title: String, createdAt: Date = Date()) -> MeetingRecord {
        var meeting = MeetingRecord(createdAt: createdAt, title: title)
        meeting.status = .processing
        meeting.duration = 120
        return meeting
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 where await !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Review focus 5: the resume list runs (not the stop list), once, and the row reads
    /// "completed" with `processedCount` bumped so Spotkania reloads.
    @Test func aMeetingLeftProcessingGetsTheResumeStepsOnce() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let meeting = Self.processingMeeting("Przerwane notatki")
        try await db.createMeeting(meeting)
        let log = ProcessingLog()
        var env = Self.environment(db: db)
        env.postProcessors = [NamedPostProcessor(name: "diarizer", database: db, log: log)]
        env.resumeProcessors = [NamedPostProcessor(name: "notes", database: db, log: log)]
        let recorder = MeetingRecorder(environment: env)
        recorder.recoverInterruptedMeetings()
        recorder.recoverInterruptedMeetings()
        await waitUntil { recorder.processedCount == 1 }
        await recorder.waitForPostProcessing()
        #expect(await log.entries == ["notes Przerwane notatki"])
        #expect(try await db.meeting(id: meeting.id)?.status == .completed)
        #expect(recorder.processedCount == 1)

        // The next launch finds nothing left to resume.
        let next = MeetingRecorder(environment: env)
        next.recoverInterruptedMeetings()
        await next.start()
        await next.stop()
        await next.waitForPostProcessing()
        #expect(await log.entries.filter { $0.hasPrefix("notes") } == ["notes Przerwane notatki"])
    }

    /// Two meetings cut short come back in stop order, each through the whole resume list in
    /// order, with retention last.
    @Test func resumedMeetingsRunInStopOrderWithRetentionLast() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let first = Self.processingMeeting("Pierwsze", createdAt: Date(timeIntervalSinceNow: -7_200))
        let second = Self.processingMeeting("Drugie", createdAt: Date(timeIntervalSinceNow: -3_600))
        try await db.createMeeting(second)
        try await db.createMeeting(first)
        let log = ProcessingLog()
        var env = Self.environment(db: db)
        env.resumeProcessors = [
            NamedPostProcessor(name: "fix", database: db, log: log),
            NamedPostProcessor(name: "notes", database: db, log: log),
            NamedPostProcessor(name: "retention", database: db, log: log),
        ]
        let recorder = MeetingRecorder(environment: env)
        recorder.recoverInterruptedMeetings()
        await waitUntil { recorder.processedCount == 2 }
        await recorder.waitForPostProcessing()
        #expect(await log.entries == [
            "fix Pierwsze", "notes Pierwsze", "retention Pierwsze",
            "fix Drugie", "notes Drugie", "retention Drugie",
        ])
        #expect(try await db.meeting(id: first.id)?.status == .completed)
        #expect(try await db.meeting(id: second.id)?.status == .completed)
    }

    /// A meeting left "recording" becomes "interrupted" and is never resumed: its stop never
    /// ran, so there is no transcript to write notes from.
    @Test func anInterruptedMeetingIsNotResumed() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let live = MeetingRecord(title: "W trakcie")
        try await db.createMeeting(live)
        let log = ProcessingLog()
        var env = Self.environment(db: db)
        env.resumeProcessors = [NamedPostProcessor(name: "notes", database: db, log: log)]
        let recorder = MeetingRecorder(environment: env)
        recorder.recoverInterruptedMeetings()
        await recorder.start()
        await recorder.stop()
        await recorder.waitForPostProcessing()
        #expect(try await db.meeting(id: live.id)?.status == .interrupted)
        #expect(await log.entries.isEmpty)
        #expect(recorder.processedCount == 1)
    }

    /// The resumed meeting reads "processing" while its steps run, and a meeting stopped right
    /// after launch is processed after it, in the same chain.
    @Test func aStopAfterLaunchWaitsForTheResumedMeeting() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let old = Self.processingMeeting("Stare", createdAt: Date(timeIntervalSinceNow: -3_600))
        try await db.createMeeting(old)
        let gate = TestGate()
        let gated = GatedPostProcessor(gate: gate, database: db)
        let log = ProcessingLog()
        var env = Self.environment(db: db)
        env.resumeProcessors = [gated]
        env.postProcessors = [NamedPostProcessor(name: "stop", database: db, log: log)]
        let recorder = MeetingRecorder(environment: env)
        recorder.recoverInterruptedMeetings()
        await waitUntil { await gated.events == [.started(old.id)] }
        #expect(try await db.meeting(id: old.id)?.status == .processing)

        await recorder.start(title: "Nowe")
        let new = try #require(recorder.currentMeetingID)
        await recorder.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.entries.isEmpty)
        #expect(try await db.meeting(id: new)?.status == .processing)

        await gate.open()
        await recorder.waitForPostProcessing()
        #expect(await gated.events == [.started(old.id), .finished(old.id)])
        #expect(await log.entries == ["stop Nowe"])
        #expect(try await db.meeting(id: old.id)?.status == .completed)
        #expect(try await db.meeting(id: new)?.status == .completed)
        #expect(recorder.processedCount == 2)
    }

    // MARK: Resume steps

    /// A step whose work is already on the row (notes written before the quit) is skipped; one
    /// whose work is missing runs the processor.
    @Test func aResumeStepSkipsWorkAlreadyOnTheRow() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        var done = Self.processingMeeting("Z notatkami")
        done.summary = "## Podsumowanie"
        let missing = Self.processingMeeting("Bez notatek")
        try await db.createMeeting(done)
        try await db.createMeeting(missing)
        let log = ProcessingLog()
        let step = MeetingResumeStep(
            database: db,
            isDone: { $0.summary != nil },
            processor: NamedPostProcessor(name: "notes", database: db, log: log)
        )
        await step.process(meetingID: done.id)
        await step.process(meetingID: missing.id)
        await step.process(meetingID: UUID())
        #expect(await log.entries == ["notes Bez notatek"])
    }

    /// Without Pro the AI notes never run on resume either: the processor's own gate decides,
    /// so a Free user's resumed meeting just becomes "completed".
    @Test func resumeSkipsTheAINotesWithoutPro() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let meeting = Self.processingMeeting("Bez Pro")
        try await db.createMeeting(meeting)
        let summarizer = MeetingSummarizer(session: .shared, route: { AIRoute(client: OpenRouterClient(), key: "k", model: "m") })
        let notes = MeetingNotesProcessor(database: db, summarizer: summarizer, isAllowed: { false })
        var env = Self.environment(db: db)
        env.resumeProcessors = [MeetingResumeStep(database: db, isDone: { $0.summary != nil }, processor: notes)]
        let recorder = MeetingRecorder(environment: env)
        recorder.recoverInterruptedMeetings()
        await waitUntil { recorder.processedCount == 1 }
        await recorder.waitForPostProcessing()
        let read = try #require(try await db.meeting(id: meeting.id))
        #expect(read.status == .completed)
        #expect(read.summary == nil)
        #expect(read.summaryError == nil)
    }
}
