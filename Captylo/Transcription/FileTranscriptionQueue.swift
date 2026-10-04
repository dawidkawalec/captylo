import Foundation
import Observation

/// Sequential "Transkrypcja pliku" queue (brief 1.1, port note 2.6). Every item goes through
/// decode -> WAV -> router -> `TextProcessor` -> optional AI (15 s deadline) -> history row
/// (`source = .file`). Services are injected so tests drive it with fakes.
@MainActor
@Observable
final class FileTranscriptionQueue {
    /// AI cleanup budget for files (longer than the 3 s dictation deadline).
    nonisolated static let enhancementDeadline: Duration = .seconds(15)
    /// Output cap for file cleanup: files run longer than dictations, so the 2048 dictation cap
    /// would cut them off (`finish_reason == "length"`) and the sanity guard would reject them.
    nonisolated static let enhancementTokenCap = 8192

    enum Status: Equatable, Sendable {
        case waiting
        case decoding
        case transcribing
        case enhancing
        case done(text: String)
        case failed(message: String)

        var isFinished: Bool {
            switch self {
            case .done, .failed: return true
            case .waiting, .decoding, .transcribing, .enhancing: return false
            }
        }

        var isActive: Bool {
            switch self {
            case .decoding, .transcribing, .enhancing: return true
            case .waiting, .done, .failed: return false
            }
        }

        var text: String? {
            if case .done(let text) = self { return text }
            return nil
        }
    }

    struct Item: Identifiable, Equatable, Sendable {
        /// Also the history row id and the WAV name (`<id>.wav`).
        let id: UUID
        let url: URL
        var status: Status

        var name: String { url.lastPathComponent }
    }

    /// AI for one file: the enhancer (15 s file deadline) and the mode it runs.
    struct FileEnhancement {
        var enhancer: any TextEnhancing
        var mode: AIMode
        var vocabulary: [String]
    }

    /// Everything the pipeline touches, as closures and seams (fakes in tests).
    struct Services {
        var decode: @Sendable (URL) async throws -> (samples: [Float], duration: TimeInterval)
        var writeWAV: @Sendable ([Float], URL) throws -> Void
        var recordingURL: @Sendable (UUID) -> URL
        var router: any TranscriptionRouting
        var engine: @MainActor () -> STTEngine
        var language: @MainActor () -> String?
        var vocabulary: @MainActor () -> [String]
        var processor: @MainActor () -> TextProcessor
        /// nil when AI is off; otherwise the file enhancer plus the active AI mode.
        var enhancement: @MainActor () -> FileEnhancement?
        /// Inserts the row, or replaces the row with the same id (a retry reuses its id, gotcha 85).
        var save: @Sendable (DictationRecord) async throws -> Void
        var didSave: @MainActor () -> Void
        /// The "Zapisuj historię" setting: when false nothing is saved and the WAV copy is deleted.
        var saveHistory: @MainActor () -> Bool

        init(
            decode: @escaping @Sendable (URL) async throws -> (samples: [Float], duration: TimeInterval) = { try await AudioDecoder.decode16kMono($0) },
            writeWAV: @escaping @Sendable ([Float], URL) throws -> Void = { try AudioDecoder.writeWAV16k($0, to: $1) },
            recordingURL: @escaping @Sendable (UUID) -> URL = { AppPaths.recordingURL(for: $0) },
            router: any TranscriptionRouting,
            engine: @escaping @MainActor () -> STTEngine,
            language: @escaping @MainActor () -> String?,
            vocabulary: @escaping @MainActor () -> [String],
            processor: @escaping @MainActor () -> TextProcessor,
            enhancement: @escaping @MainActor () -> FileEnhancement?,
            save: @escaping @Sendable (DictationRecord) async throws -> Void,
            didSave: @escaping @MainActor () -> Void,
            saveHistory: @escaping @MainActor () -> Bool = { true }
        ) {
            self.decode = decode
            self.writeWAV = writeWAV
            self.recordingURL = recordingURL
            self.router = router
            self.engine = engine
            self.language = language
            self.vocabulary = vocabulary
            self.processor = processor
            self.enhancement = enhancement
            self.save = save
            self.didSave = didSave
            self.saveHistory = saveHistory
        }
    }

    private(set) var items: [Item] = []
    /// Names of files skipped by `add(urls:)` because their extension is unsupported.
    private(set) var rejectedNames: [String] = []

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// The item being processed and its task, so `cancel(id:)` can stop it.
    @ObservationIgnored private var running: (id: UUID, task: Task<Void, Never>)?

    init(services: Services) {
        self.services = services
    }

    var isProcessing: Bool { items.contains { $0.status.isActive } }
    var hasFinishedItems: Bool { items.contains { $0.status.isFinished } }

    // MARK: - Queue management

    /// Enqueues the supported files (by extension) and starts processing. Unsupported ones land in `rejectedNames`.
    func add(urls: [URL]) {
        var accepted: [Item] = []
        var rejected: [String] = []
        for url in urls {
            if AudioDecoder.isSupported(url) {
                accepted.append(Item(id: UUID(), url: url, status: .waiting))
            } else {
                rejected.append(url.lastPathComponent)
            }
        }
        rejectedNames = rejected
        guard !accepted.isEmpty else { return }
        items.append(contentsOf: accepted)
        Log.transcription.info("File queue: added \(accepted.count) files, skipped \(rejected.count)")
        drainIfNeeded()
    }

    /// Puts a failed item back in line under the same id, so the rerun overwrites its failed
    /// history row and `<id>.wav` instead of adding a second copy.
    func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .failed = items[index].status else { return }
        items[index].status = .waiting
        drainIfNeeded()
    }

    /// Removes a waiting or finished item (active ones go through `cancel(id:)`).
    func remove(id: UUID) {
        items.removeAll { $0.id == id && !$0.status.isActive }
    }

    /// Stops the item being processed and takes it off the list: no history row is saved and its
    /// WAV copy is deleted. A waiting or finished item is simply removed. The queue moves on to
    /// the next file once the engine lets go (a running local pass stops at its next window).
    func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status.isActive else {
            remove(id: id)
            return
        }
        Log.transcription.info("File \(self.items[index].name, privacy: .public) cancelled")
        items.remove(at: index)
        if let running, running.id == id {
            running.task.cancel()
        }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
        rejectedNames = []
    }

    /// Waits for the running drain to finish (tests and shutdown).
    func waitUntilIdle() async {
        await drainTask?.value
    }

    // MARK: - Processing

    private func drainIfNeeded() {
        guard drainTask == nil else { return }
        // Strong self on purpose: a queue that loses its view still finishes the files it accepted.
        drainTask = Task {
            await self.drain()
            self.drainTask = nil
            if self.items.contains(where: { $0.status == .waiting }) {
                self.drainIfNeeded()
            }
        }
    }

    private func drain() async {
        while let next = items.first(where: { $0.status == .waiting }) {
            let task = Task { await self.process(next) }
            running = (next.id, task)
            await task.value
            running = nil
        }
    }

    private func process(_ item: Item) async {
        let id = item.id
        let fileURL = services.recordingURL(id)
        var record = DictationRecord(
            id: id,
            text: "",
            source: .file,
            language: services.language()
        )
        var wavWritten = false
        // Read once: a setting flip mid-file must not save a row whose WAV was already deleted.
        let keepHistory = services.saveHistory()

        do {
            setStatus(.decoding, for: id)
            let decoded = try await services.decode(item.url)
            try Task.checkCancellation()
            let samples = decoded.samples
            let writeWAV = services.writeWAV
            try await Task.detached(priority: .userInitiated) {
                try writeWAV(samples, fileURL)
            }.value
            wavWritten = true
            try Task.checkCancellation()
            record.audioDuration = decoded.duration
            record.audioFileName = fileURL.lastPathComponent

            setStatus(.transcribing, for: id)
            let audio = CapturedAudio(id: id, fileURL: fileURL, samples: samples, duration: decoded.duration)
            let result = try await services.router.transcribe(
                audio,
                engine: services.engine(),
                language: services.language(),
                vocabulary: services.vocabulary()
            )
            try Task.checkCancellation()
            record.modelName = result.modelName
            record.transcriptionMs = result.ms

            let text = services.processor().process(result.text, language: services.language())
            guard !text.isEmpty else { throw DictationError.emptyResult }
            record.text = text

            var finalText = text
            if let enhancement = services.enhancement() {
                let mode = enhancement.mode
                if Enhancer.shouldSkip(text, kind: mode.kind) {
                    record.applyEnhancement(.skipped(.tooShort), mode: mode.name)
                } else {
                    setStatus(.enhancing, for: id)
                    // The file deadline (15 s) instead of the mode's: files run long.
                    var job = mode.job(vocabulary: enhancement.vocabulary)
                    job.deadline = Self.enhancementDeadline
                    let outcome = await Self.enhance(text, with: enhancement.enhancer, job: job)
                    record.applyEnhancement(outcome, mode: mode.name)
                    switch outcome {
                    case .enhanced(let enhanced, _, _):
                        finalText = enhanced
                    case .failed(let failure, _):
                        Log.enhancement.notice("File AI skipped: \(failure.errorDescription ?? "", privacy: .public)")
                    case .skipped:
                        break
                    }
                }
            }
            record.wordCount = WordCounter.count(finalText)
            record.status = .completed
            try Task.checkCancellation()

            if keepHistory {
                try await services.save(record)
                services.didSave()
            } else {
                Self.removeFile(fileURL)
            }
            setStatus(.done(text: finalText), for: id)
            Log.transcription.info("File \(item.name, privacy: .public) transcribed: \(record.wordCount) words")
        } catch {
            if error is CancellationError || Task.isCancelled {
                // `cancel(id:)` already took the item off the list: keep nothing.
                if wavWritten {
                    Self.removeFile(fileURL)
                }
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.transcription.error("File \(item.name, privacy: .public) failed: \(message, privacy: .public)")
            setStatus(.failed(message: message), for: id)
            // Keep the audio so "Transkrybuj ponownie" in Historia can retry it (gotcha 85);
            // with history off nothing is kept.
            if wavWritten, !keepHistory {
                Self.removeFile(fileURL)
            } else if wavWritten {
                record.status = .failed
                record.errorMessage = message
                do {
                    try await services.save(record)
                    services.didSave()
                } catch {
                    // No row points at the WAV, so Historia could never show or delete it.
                    Log.data.error("Could not store the failed file row: \(error.localizedDescription, privacy: .public), dropping its recording")
                    Self.removeFile(fileURL)
                }
            }
        }
    }

    /// Races the enhancer against the job's deadline (the file deadline when nil); the raw
    /// text wins on timeout.
    nonisolated static func enhance(
        _ text: String,
        with enhancer: any TextEnhancing,
        job: EnhancementJob
    ) async -> EnhancementOutcome {
        let deadline = job.deadline ?? enhancementDeadline
        return await withTaskGroup(of: EnhancementOutcome.self) { group in
            group.addTask { await enhancer.enhance(text, job: job) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                let seconds = Enhancer.seconds(deadline)
                return .failed(.deadline(seconds: seconds), ms: Int((seconds * 1000).rounded()))
            }
            // `next()` is nil only for an empty group, which cannot happen here.
            let first = await group.next() ?? .skipped(.tooShort)
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func removeFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.data.error("Could not delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setStatus(_ status: Status, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }
}
