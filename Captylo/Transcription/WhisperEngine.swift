import Foundation
import os
@preconcurrency import WhisperKit

/// The local speech engine for the whole app: Whisper large-v3-turbo through WhisperKit (Core ML,
/// Neural Engine). Exactly one `WhisperKit` instance, loaded once and reused by every pass;
/// `unload()` runs only when the user deletes the model.
///
/// Passes run one at a time (WhisperKit keeps per-call state on the instance). Final passes queue
/// in order; a preview never waits: it returns "" while the model is busy, and a running preview
/// stops decoding as soon as a final pass is waiting, so a live preview never delays the text.
actor WhisperEngine: LocalTranscribing, MeetingSpeechTranscribing {
    enum State: Sendable, Equatable {
        case missing
        case loading
        case ready
        case failed(String)
    }

    /// Full precision turbo: the 626 MB palettized variant lost clearly on Polish (131 vs 109
    /// substituted words on the owner's meeting, 2026-10-02).
    static let variant = "openai_whisper-large-v3-v20240930"
    static let sampleRate = 16_000
    /// One Whisper window is 30 s; previews keep a little headroom.
    static let maxPreviewSamples = 29 * sampleRate
    /// Shorter slices decode to noise or a phantom phrase, so they return "".
    static let minimumSamples = sampleRate * 3 / 10
    /// Longer audio is cut at pauses by WhisperKit's energy VAD into windows of at most 30 s.
    static let maxSingleWindowSamples = 30 * sampleRate

    static var modelFolder: URL {
        AppPaths.whisperDownloadBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(variant)", directoryHint: .isDirectory)
    }

    static var tokenizerFile: URL {
        AppPaths.whisperDownloadBase.appending(path: "models/openai/whisper-large-v3/tokenizer.json")
    }

    /// True when the three Core ML bundles and the tokenizer are on disk.
    static var isDownloaded: Bool {
        let files = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].map { modelFolder.appending(path: $0) }
            + [tokenizerFile]
        return files.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .missing)
    /// Final passes waiting for the model; a running preview stops decoding while this is above 0.
    private let pendingFinals = OSAllocatedUnfairLock(initialState: 0)
    private var kit: WhisperKit?
    private var loadTask: Task<Void, any Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Set while `deleteModel()` runs: loads are refused.
    private var deleting = false

    /// No vocabulary prompt: on the owner's meeting (2026-10-02) a prompt of 3 or 11 terms fixed
    /// one surname but dropped 2-3 times more words (168-209 deletions vs 63) and ran slower.
    init() {}

    /// Readable from any isolation domain without a hop (the model store polls it from the main actor).
    nonisolated var state: State {
        stateLock.withLock { $0 }
    }

    // MARK: - Files

    /// Fetches the model and the tokenizer into `AppPaths.whisperDownloadBase`. Progress 0...1
    /// covers the model files (the tokenizer is 3 MB and follows).
    static func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: AppPaths.whisperDownloadBase, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(variant: variant, downloadBase: AppPaths.whisperDownloadBase) { value in
            progress?(min(max(value.fractionCompleted, 0), 1))
        }
        _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: AppPaths.whisperDownloadBase)
    }

    /// Removes the model and the tokenizer (the whole download base: nothing else lives there).
    private static func deleteFiles() throws {
        let base = AppPaths.whisperDownloadBase
        if FileManager.default.fileExists(atPath: base.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: base)
        }
    }

    // MARK: - Loading

    /// Loads and prewarms the model (deduped: concurrent callers await the same task). Throws
    /// `DictationError.modelNotReady` when the files are not on disk; never downloads. The first
    /// load of a model compiles it for the Neural Engine (a few minutes), later loads take seconds.
    func load() async throws {
        if kit != nil, state == .ready { return }
        guard !deleting else { throw DictationError.modelNotReady }
        if let loadTask { return try await loadTask.value }
        let task = Task { try await performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// Releases the model and removes its files, exclusively: no load starts meanwhile, a running
    /// load finishes first, and the model is taken like a pass (a running pass ends first, waiting
    /// finals run before it), so nothing decodes on an unloaded model or reloads half-deleted files.
    func deleteModel() async throws {
        deleting = true
        defer { deleting = false }
        _ = try? await loadTask?.value
        await acquire()
        defer { release() }
        await kit?.unloadModels()
        kit = nil
        setState(.missing)
        try Self.deleteFiles()
        Log.transcription.notice("Whisper model unloaded and deleted")
    }

    private func performLoad() async throws {
        guard Self.isDownloaded else {
            setState(.missing)
            throw DictationError.modelNotReady
        }
        setState(.loading)
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Log.signposter.beginInterval("whisper.load", id: Log.signposter.makeSignpostID())
        do {
            let config = WhisperKitConfig(
                downloadBase: AppPaths.whisperDownloadBase,
                modelFolder: Self.modelFolder.path(percentEncoded: false),
                tokenizerFolder: AppPaths.whisperDownloadBase,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            kit = try await WhisperKit(config)
            setState(.ready)
            Log.signposter.endInterval("whisper.load", interval)
            Log.transcription.info("Whisper ready in \(Self.milliseconds(since: start, clock: clock)) ms")
        } catch {
            kit = nil
            setState(.failed(error.localizedDescription))
            Log.signposter.endInterval("whisper.load", interval)
            Log.transcription.error("Whisper load failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - LocalTranscribing

    /// Full pass over a finished recording. Waits for an in-flight load and for earlier passes.
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let segments = try await finalPass(samples, language: language, words: false, label: "whisper.transcribe")
        return Self.text(of: segments)
    }

    /// Best effort: "" until the model is ready or while another pass runs.
    func preview(_ tail: [Float], language: String?) async throws -> String {
        guard let kit, state == .ready, !busy else { return "" }
        busy = true
        defer { release() }
        let capped = Array(tail.suffix(Self.maxPreviewSamples))
        let pendingFinals = pendingFinals
        let segments = try await run(capped, language: language, words: false, isFinal: false, on: kit, label: "whisper.preview") { _ in
            pendingFinals.withLock { $0 } == 0
        }
        return Self.text(of: segments)
    }

    // MARK: - MeetingSpeechTranscribing

    /// One utterance (at most one 30 s window). Word times are relative to the start of `samples`.
    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript {
        let segments = try await finalPass(samples, language: language, words: true, label: "whisper.meeting")
        let timings = segments
            .filter { !WhisperOutputFilter.isPhantom($0.text) }
            .flatMap { $0.words ?? [] }
            .map { WordTimings.Timed(word: $0.word, start: Double($0.start), end: Double($0.end)) }
        let duration = Double(samples.count) / Double(Self.sampleRate)
        return TimedTranscript(text: Self.text(of: segments), words: WordTimings.words(from: timings, duration: duration))
    }

    /// The grey "w trakcie" line of a meeting: a preview, so it never holds up a final.
    func previewText(_ samples: [Float], language: String?) async throws -> String {
        try await preview(samples, language: language)
    }

    // MARK: - Passes

    private func finalPass(_ samples: [Float], language: String?, words: Bool, label: StaticString) async throws -> [TranscriptionSegment] {
        if kit == nil {
            try await load()
        }
        pendingFinals.withLock { $0 += 1 }
        await acquire()
        pendingFinals.withLock { $0 -= 1 }
        defer { release() }
        // Read after the wait: the model may have been deleted meanwhile.
        guard let kit else { throw DictationError.modelNotReady }
        return try await run(samples, language: language, words: words, isFinal: true, on: kit, label: label)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the model to the next waiting final pass, or frees it.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// The segments of one pass (WhisperKit's result type shares its name with ours, so it stays inside).
    private func run(
        _ samples: [Float],
        language: String?,
        words: Bool,
        isFinal: Bool,
        on kit: WhisperKit,
        label: StaticString,
        shouldContinue: (@Sendable (TranscriptionProgress) -> Bool?)? = nil
    ) async throws -> [TranscriptionSegment] {
        guard samples.count >= Self.minimumSamples else { return [] }
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Log.signposter.beginInterval(label, id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval(label, interval) }
        // No first-token threshold: a low first token ends the segment empty and leaves it to the
        // temperature fallback, and utterances cut at 14 s often start mid-sentence, so whole
        // utterances of real speech vanished at random (seen on the owner's meeting). Final passes
        // also skip the no-speech check: the audio is known to hold speech (the meeting VAD cut
        // it, or the user held the hotkey); silence in a dictation is caught by the router's filter.
        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: words,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: isFinal ? nil : 0.6,
            chunkingStrategy: samples.count > Self.maxSingleWindowSamples ? .vad : nil
        )
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: shouldContinue)
        Log.transcription.debug("\(label, privacy: .public): \(samples.count) samples in \(Self.milliseconds(since: start, clock: clock)) ms")
        return results.flatMap(\.segments)
    }

    /// Segment texts without phantom lines and annotations, joined with single spaces.
    private static func text(of segments: [TranscriptionSegment]) -> String {
        segments
            .map(\.text)
            .filter { !WhisperOutputFilter.isPhantom($0) }
            .map(WhisperOutputFilter.strippingAnnotations)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated func setState(_ newState: State) {
        stateLock.withLock { $0 = newState }
    }

    private static func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        Int(start.duration(to: clock.now) / .milliseconds(1))
    }
}

/// Whisper's known non-speech output: sound annotations ("*szum*", "[MUZYKA]", "(śmiech)") and
/// subtitle credits learned from its training data. Real Polish words are never removed here.
enum WhisperOutputFilter {
    // Computed: `Regex` is not Sendable, so it cannot be a stored static under Swift 6.
    private static var annotation: Regex<Substring> { /^[\*\[\(][^\*\]\)]{1,40}[\*\]\)][.,!?]?$/ }
    private static var inlineAnnotation: Regex<Substring> { /[\*\[][^\*\]]{1,40}[\*\]]/ }
    private static var credits: Regex<Substring> {
        /(?i)amara\.org|napisy (?:stworzone|wykonane|przygotowane|zrobione)|subtitles by|tłumaczenie i napisy/
    }

    /// A whole segment that is a credit line or nothing but annotations.
    static func isPhantom(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(credits) || isAnnotation(trimmed) { return true }
        return strippingAnnotations(trimmed).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    static func isAnnotation(_ word: String) -> Bool {
        word.wholeMatch(of: annotation) != nil
    }

    static func strippingAnnotations(_ text: String) -> String {
        text.replacing(inlineAnnotation, with: "")
            .replacing(/\s{2,}/, with: " ")
    }
}
