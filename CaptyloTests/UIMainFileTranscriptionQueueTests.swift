import Foundation
import os
import Testing
@testable import Captylo

/// Router fake: fixed text or a fixed error, records the engine it was asked for.
private final class UIMainFakeRouter: TranscriptionRouting, Sendable {
    private let text: String
    private let failure: DictationError?
    private let calls = OSAllocatedUnfairLock<[STTEngine]>(initialState: [])

    init(text: String = "raz dwa trzy cztery pięć", failure: DictationError? = nil) {
        self.text = text
        self.failure = failure
    }

    var engines: [STTEngine] { calls.withLock { $0 } }

    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        calls.withLock { $0.append(engine) }
        if let failure { throw failure }
        return TranscriptionResult(text: text, modelName: "fake-model", ms: 42)
    }
}

/// Enhancer fake: fixed outcome, optional hang, counts calls.
private final class UIMainFakeEnhancer: TextEnhancing, Sendable {
    private let outcome: EnhancementOutcome
    private let hangs: Bool
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    init(outcome: EnhancementOutcome, hangs: Bool = false) {
        self.outcome = outcome
        self.hangs = hangs
    }

    private let jobs = OSAllocatedUnfairLock<[EnhancementJob]>(initialState: [])

    var calls: Int { counter.withLock { $0 } }
    var lastJob: EnhancementJob? { jobs.withLock { $0.last } }

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        counter.withLock { $0 += 1 }
        jobs.withLock { $0.append(job) }
        if hangs {
            try? await Task.sleep(for: .seconds(30))
        }
        return outcome
    }

    func prewarm() async {}
}

/// Router fake that fails the first call and succeeds afterwards.
private final class UIMainFlakyRouter: TranscriptionRouting, Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        let call = calls.withLock { $0 += 1; return $0 }
        if call == 1 { throw DictationError.stt(.timeout) }
        return TranscriptionResult(text: "raz dwa trzy cztery", modelName: "fake-model", ms: 7)
    }
}

/// Captures the rows the queue saves, keyed like the database (same id replaces the row).
private final class UIMainSaveRecorder: Sendable {
    private let store = OSAllocatedUnfairLock<[DictationRecord]>(initialState: [])
    let bumps = OSAllocatedUnfairLock(initialState: 0)

    var records: [DictationRecord] { store.withLock { $0 } }

    func save(_ record: DictationRecord) {
        store.withLock { rows in
            if let index = rows.firstIndex(where: { $0.id == record.id }) {
                rows[index] = record
            } else {
                rows.append(record)
            }
        }
    }
}

@MainActor
struct UIMainFileTranscriptionQueueTests {
    private nonisolated static let recordings = FileManager.default.temporaryDirectory
        .appending(path: "UIMainQueue-\(UUID().uuidString)", directoryHint: .isDirectory)

    private static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: name)
    }

    private static func makeQueue(
        router: any TranscriptionRouting = UIMainFakeRouter(),
        decodeError: (any Error)? = nil,
        enhancer: UIMainFakeEnhancer? = nil,
        mode: AIMode = BuiltInAIModes.cleanup,
        saveError: (any Error)? = nil,
        recorder: UIMainSaveRecorder = UIMainSaveRecorder(),
        saveHistory: Bool = true
    ) -> (FileTranscriptionQueue, UIMainSaveRecorder) {
        let services = FileTranscriptionQueue.Services(
            decode: { _ in
                if let decodeError { throw decodeError }
                return ([Float](repeating: 0.1, count: 16_000), 1.0)
            },
            writeWAV: { _, url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("RIFF".utf8).write(to: url)
            },
            recordingURL: { recordings.appending(path: "\($0.uuidString).wav") },
            router: router,
            engine: { .parakeet },
            language: { "pl" },
            vocabulary: { ["Captylo"] },
            processor: { TextProcessor(dictionary: .default, paragraphs: true) },
            enhancement: {
                guard let enhancer else { return nil }
                return FileTranscriptionQueue.FileEnhancement(enhancer: enhancer, mode: mode, vocabulary: ["Captylo"])
            },
            save: { record in
                if let saveError { throw saveError }
                recorder.save(record)
            },
            didSave: { recorder.bumps.withLock { $0 += 1 } },
            saveHistory: { saveHistory }
        )
        return (FileTranscriptionQueue(services: services), recorder)
    }

    // MARK: add

    @Test func addFiltersUnsupportedExtensions() async {
        let (queue, _) = Self.makeQueue()
        queue.add(urls: [Self.url("a.wav"), Self.url("notes.txt"), Self.url("b.MP3"), Self.url("c.pdf")])
        #expect(queue.items.map(\.name) == ["a.wav", "b.MP3"])
        #expect(queue.rejectedNames == ["notes.txt", "c.pdf"])
        await queue.waitUntilIdle()
        #expect(queue.items.allSatisfy { $0.status.isFinished })
    }

    @Test func addOnlyUnsupportedFilesQueuesNothing() async {
        let (queue, _) = Self.makeQueue()
        queue.add(urls: [Self.url("x.txt")])
        #expect(queue.items.isEmpty)
        #expect(queue.rejectedNames == ["x.txt"])
        #expect(!queue.isProcessing)
    }

    // MARK: pipeline

    @Test func successfulItemEndsDoneAndSavesAFileRow() async throws {
        let router = UIMainFakeRouter(text: "yyy raz dwa trzy cztery")
        let (queue, recorder) = Self.makeQueue(router: router)
        queue.add(urls: [Self.url("mowa.m4a")])
        #expect(queue.items.count == 1)
        await queue.waitUntilIdle()

        let item = try #require(queue.items.first)
        #expect(item.status == .done(text: "Raz dwa trzy cztery"), "the text processor removed the filler and capitalized the sentence")
        #expect(router.engines == [.parakeet])

        let record = try #require(recorder.records.first)
        #expect(recorder.records.count == 1)
        #expect(record.id == item.id)
        #expect(record.source == .file)
        #expect(record.status == .completed)
        #expect(record.text == "Raz dwa trzy cztery")
        #expect(record.enhancedText == nil)
        #expect(record.wordCount == 4)
        #expect(record.audioDuration == 1.0)
        #expect(record.audioFileName == "\(item.id.uuidString).wav")
        #expect(record.modelName == "fake-model")
        #expect(record.transcriptionMs == 42)
        #expect(record.language == "pl")
        #expect(recorder.bumps.withLock { $0 } == 1)
    }

    @Test func itemsRunSequentiallyInOrder() async {
        let (queue, recorder) = Self.makeQueue()
        queue.add(urls: [Self.url("1.wav"), Self.url("2.wav"), Self.url("3.wav")])
        await queue.waitUntilIdle()
        #expect(queue.items.map(\.status) == Array(repeating: .done(text: "raz dwa trzy cztery pięć"), count: 3))
        #expect(recorder.records.map(\.id) == queue.items.map(\.id))
        #expect(!queue.isProcessing)
        #expect(queue.hasFinishedItems)
    }

    @Test func decodeFailureMarksFailedAndSavesNothing() async throws {
        let (queue, recorder) = Self.makeQueue(decodeError: AudioDecoderError.noAudioTrack)
        queue.add(urls: [Self.url("video.mov")])
        await queue.waitUntilIdle()
        let status = try #require(queue.items.first?.status)
        #expect(status == .failed(message: AudioDecoderError.noAudioTrack.errorDescription ?? ""))
        #expect(recorder.records.isEmpty)
        #expect(recorder.bumps.withLock { $0 } == 0)
    }

    @Test func transcriptionFailureSavesAFailedRowWithAudioKept() async throws {
        let router = UIMainFakeRouter(failure: .modelNotReady)
        let (queue, recorder) = Self.makeQueue(router: router)
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()

        let item = try #require(queue.items.first)
        #expect(item.status == .failed(message: DictationError.modelNotReady.errorDescription ?? ""))
        let record = try #require(recorder.records.first)
        #expect(record.status == .failed)
        #expect(record.errorMessage == DictationError.modelNotReady.errorDescription)
        #expect(record.text == "", "errors never land in the transcript field")
        #expect(record.audioFileName == "\(item.id.uuidString).wav")
        #expect(record.source == .file)
    }

    @Test func emptyTranscriptFails() async throws {
        let (queue, recorder) = Self.makeQueue(router: UIMainFakeRouter(text: "   "))
        queue.add(urls: [Self.url("cisza.wav")])
        await queue.waitUntilIdle()
        #expect(queue.items.first?.status == .failed(message: DictationError.emptyResult.errorDescription ?? ""))
        #expect(recorder.records.first?.status == .failed)
    }

    @Test func saveFailureIsReportedOnTheItem() async throws {
        let (queue, recorder) = Self.makeQueue(saveError: DatabaseError.notFound(UUID()))
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()
        let status = try #require(queue.items.first?.status)
        if case .failed(let message) = status {
            #expect(message == DatabaseError.notFound(UUID()).errorDescription)
        } else {
            Issue.record("expected a failed item, got \(status)")
        }
        #expect(recorder.records.isEmpty)
        // No row points at the recording, so it must not stay on disk.
        let id = try #require(queue.items.first?.id)
        #expect(!FileManager.default.fileExists(atPath: Self.recordings.appending(path: "\(id.uuidString).wav").path))
    }

    @Test func cancellingTheActiveItemKeepsNothingAndMovesOn() async throws {
        let enhancer = UIMainFakeEnhancer(outcome: .enhanced(text: "late", ms: 1, model: "x"), hangs: true)
        let (queue, recorder) = Self.makeQueue(enhancer: enhancer)
        queue.add(urls: [Self.url("dlugie.wav"), Self.url("nastepne.wav")])
        let first = queue.items[0].id
        let second = queue.items[1].id

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while queue.items.first(where: { $0.id == first })?.status != .enhancing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(queue.items.first?.status == .enhancing)

        queue.cancel(id: first)
        #expect(!queue.items.contains { $0.id == first })

        // The second file hangs in AI cleanup too: cancel it as well so the queue drains.
        while queue.items.first(where: { $0.id == second })?.status != .enhancing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!recorder.records.contains { $0.id == first })
        #expect(!FileManager.default.fileExists(atPath: Self.recordings.appending(path: "\(first.uuidString).wav").path))
        queue.cancel(id: second)
        await queue.waitUntilIdle()
        #expect(queue.items.isEmpty)
        #expect(recorder.records.isEmpty)
    }

    // MARK: AI

    @Test func aiOutcomeIsUsedWhenEnabled() async throws {
        let enhancer = UIMainFakeEnhancer(outcome: .enhanced(text: "Raz, dwa, trzy, cztery, pięć.", ms: 300, model: "fake/llm"))
        let (queue, recorder) = Self.makeQueue(enhancer: enhancer)
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()

        #expect(queue.items.first?.status == .done(text: "Raz, dwa, trzy, cztery, pięć."))
        #expect(enhancer.calls == 1)
        let record = try #require(recorder.records.first)
        #expect(record.text == "raz dwa trzy cztery pięć")
        #expect(record.enhancedText == "Raz, dwa, trzy, cztery, pięć.")
        #expect(record.enhancementModel == "fake/llm")
        #expect(record.enhancementMs == 300)
        #expect(record.enhancementMode == BuiltInAIModes.cleanup.name)
        #expect(record.enhancementNote == nil)
        #expect(record.wordCount == 5)
        // The active mode's prompt and kind with the file deadline instead of the mode's 3 s.
        let job = try #require(enhancer.lastJob)
        #expect(job.kind == .cleanup)
        #expect(job.deadline == FileTranscriptionQueue.enhancementDeadline)
        #expect(job.systemPrompt.contains("Captylo"))
    }

    @Test func aiFailureKeepsRawTextAndRecordsTheNote() async throws {
        let enhancer = UIMainFakeEnhancer(outcome: .failed(.deadline(seconds: 15), ms: 15000))
        let (queue, recorder) = Self.makeQueue(enhancer: enhancer)
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()
        #expect(queue.items.first?.status == .done(text: "raz dwa trzy cztery pięć"))
        let record = try #require(recorder.records.first)
        #expect(record.status == .completed)
        #expect(record.enhancedText == nil)
        #expect(record.enhancementModel == nil)
        #expect(record.enhancementMode == BuiltInAIModes.cleanup.name)
        #expect(record.enhancementNote == EnhancementFailure.deadline(seconds: 15).note)
    }

    @Test func shortTranscriptsSkipCleanupButNotRewrite() async throws {
        let enhancer = UIMainFakeEnhancer(outcome: .enhanced(text: "One two three.", ms: 1, model: "x"))
        let (queue, recorder) = Self.makeQueue(router: UIMainFakeRouter(text: "raz dwa trzy"), enhancer: enhancer)
        queue.add(urls: [Self.url("krotkie.wav")])
        await queue.waitUntilIdle()
        #expect(enhancer.calls == 0)
        #expect(queue.items.first?.status == .done(text: "raz dwa trzy"))
        #expect(recorder.records.first?.enhancementNote == EnhancementSkip.tooShort.note)

        let (rewriteQueue, rewriteRecorder) = Self.makeQueue(
            router: UIMainFakeRouter(text: "raz dwa trzy"),
            enhancer: enhancer,
            mode: BuiltInAIModes.english
        )
        rewriteQueue.add(urls: [Self.url("krotkie.wav")])
        await rewriteQueue.waitUntilIdle()
        #expect(enhancer.calls == 1)
        #expect(rewriteQueue.items.first?.status == .done(text: "One two three."))
        let record = try #require(rewriteRecorder.records.first)
        #expect(record.enhancementMode == BuiltInAIModes.english.name)
        #expect(record.enhancedText == "One two three.")
    }

    @Test func enhanceRespectsTheDeadline() async {
        let enhancer = UIMainFakeEnhancer(outcome: .enhanced(text: "late", ms: 1, model: "x"), hangs: true)
        let job = EnhancementJob(systemPrompt: "p", deadline: .milliseconds(50))
        let outcome = await FileTranscriptionQueue.enhance("raz dwa trzy cztery", with: enhancer, job: job)
        #expect(outcome == .failed(.deadline(seconds: 0.05), ms: 50))
        #expect(enhancer.calls == 1)
        #expect(FileTranscriptionQueue.enhancementDeadline == .seconds(15))
    }

    // MARK: retry and cleanup

    @Test func retryRequeuesAFailedItemAndClearFinishedDropsIt() async throws {
        let (queue, recorder) = Self.makeQueue(decodeError: AudioDecoderError.emptyAudio)
        queue.add(urls: [Self.url("a.wav")])
        await queue.waitUntilIdle()
        let failed = try #require(queue.items.first)
        guard case .failed = failed.status else {
            Issue.record("expected a failed item")
            return
        }

        queue.retry(id: failed.id)
        await queue.waitUntilIdle()
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.id == failed.id, "a retry keeps its row id")
        if case .failed = queue.items.first?.status {} else {
            Issue.record("the fake still fails, so the retry must fail too")
        }
        #expect(recorder.records.isEmpty)

        queue.clearFinished()
        #expect(queue.items.isEmpty)
        #expect(!queue.hasFinishedItems)
    }

    @Test func retryAfterAFailedRowUpdatesThatRowInsteadOfAddingOne() async throws {
        let (queue, recorder) = Self.makeQueue(router: UIMainFlakyRouter())
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()
        let item = try #require(queue.items.first)
        #expect(recorder.records.map(\.status) == [.failed])

        queue.retry(id: item.id)
        await queue.waitUntilIdle()
        #expect(queue.items.first?.status == .done(text: "raz dwa trzy cztery"))
        #expect(recorder.records.count == 1, "one history row per file")
        #expect(recorder.records.first?.id == item.id)
        #expect(recorder.records.first?.status == .completed)
        #expect(recorder.records.first?.audioFileName == "\(item.id.uuidString).wav", "the same WAV is reused")
    }

    @Test func historyOffSavesNothingAndDeletesTheWAV() async throws {
        let (queue, recorder) = Self.makeQueue(saveHistory: false)
        queue.add(urls: [Self.url("prywatne.wav")])
        await queue.waitUntilIdle()
        let item = try #require(queue.items.first)
        #expect(item.status == .done(text: "raz dwa trzy cztery pięć"))
        #expect(recorder.records.isEmpty)
        #expect(recorder.bumps.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: Self.recordings.appending(path: "\(item.id.uuidString).wav").path))
    }

    @Test func historyOffFailureKeepsNoRowAndNoWAV() async throws {
        let (queue, recorder) = Self.makeQueue(router: UIMainFakeRouter(failure: .modelNotReady), saveHistory: false)
        queue.add(urls: [Self.url("prywatne.wav")])
        await queue.waitUntilIdle()
        let item = try #require(queue.items.first)
        #expect(item.status == .failed(message: DictationError.modelNotReady.errorDescription ?? ""))
        #expect(recorder.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.recordings.appending(path: "\(item.id.uuidString).wav").path))
    }

    @Test func historyOnKeepsTheWAV() async throws {
        let (queue, _) = Self.makeQueue()
        queue.add(urls: [Self.url("mowa.wav")])
        await queue.waitUntilIdle()
        let item = try #require(queue.items.first)
        #expect(FileManager.default.fileExists(atPath: Self.recordings.appending(path: "\(item.id.uuidString).wav").path))
    }

    @Test func removeIgnoresActiveItems() async {
        let (queue, _) = Self.makeQueue()
        queue.add(urls: [Self.url("a.wav")])
        let id = queue.items[0].id
        queue.remove(id: id)
        await queue.waitUntilIdle()
        // Either it was still waiting (removed) or already finished (kept); never half-processed.
        #expect(queue.items.count <= 1)
        #expect(queue.items.allSatisfy { $0.status.isFinished })
    }
}
