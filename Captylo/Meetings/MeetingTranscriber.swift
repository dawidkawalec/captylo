import FluidAudio
import Foundation
import os

/// Live meeting transcription. Each track runs its own ordered pipeline:
/// samples -> 4096-sample chunks -> Silero VAD -> utterances (max 14 s) -> timed Parakeet pass ->
/// segment saved immediately (a crash loses at most the open utterance).
/// Partials (the grey "w trakcie" line) are re-transcribed about once per second of speech and
/// skipped while a track is more than `partialBacklogLimit` behind, so the finals catch up first.
///
/// Times come from sample counts: a segment starts at its first sample's index in its track
/// divided by 16 000. Both tracks must be fed from the meeting start and without gaps (a source
/// that pauses feeds silence for the pause), or the later segments of that track land too early.
/// Echo between the tracks is marked once, in `finish()`.
///
/// Memory per track: at most one open utterance (14 s), its pre-roll and one VAD chunk. The input
/// streams never drop audio, so they only hold more while the model falls behind.
actor MeetingTranscriber {
    typealias Outcome = (segments: [MeetingSegmentRecord], echoChanges: [MeetingSegmentRecord])

    private struct TrackState {
        var accumulator = ChunkAccumulator()
        var segmenter: UtteranceSegmenter
        var detector: (any SpeechDetecting)?
        var vadState: VadStreamState?
        /// Samples received on this track so far.
        var received = 0
        /// The earliest `received` at which a VAD that failed to load is tried again.
        var nextDetectorAttempt = 0
        /// The last VAD chunk failed (logged once per run of failures, not per chunk).
        var vadFailing = false
    }

    /// A VAD that failed to load is tried again after this much track audio (10 s), not on every buffer.
    static let detectorRetrySamples = 10 * SampleBuffer.sampleRate
    /// Samples a track may have waiting before its partial passes are skipped (1 s).
    static let partialBacklogLimit = SampleBuffer.sampleRate
    private static let sampleRate = Double(SampleBuffer.sampleRate)

    nonisolated let updates: AsyncStream<MeetingLiveUpdate>
    private let updatesContinuation: AsyncStream<MeetingLiveUpdate>.Continuation
    private nonisolated let inputs: [MeetingTrack: AsyncStream<[Float]>.Continuation]
    /// Samples fed but not yet taken by a pipeline, per track (written from audio threads).
    private nonisolated let queued = OSAllocatedUnfairLock(initialState: [MeetingTrack: Int]())
    private let streams: [MeetingTrack: AsyncStream<[Float]>]

    private let meetingID: UUID
    private let language: String?
    private let engine: any MeetingSpeechTranscribing
    private let detectorFactory: @Sendable (MeetingTrack) async throws -> any SpeechDetecting
    private let save: @Sendable (MeetingSegmentRecord) async -> Void
    private var tracks: [MeetingTrack: TrackState]
    private var consumers: [Task<Void, Never>] = []
    private var finishing: Task<Outcome, Never>?
    private var segments: [MeetingSegmentRecord] = []

    /// - Parameters:
    ///   - detectorFactory: called once per track on its first samples (and again later if it throws);
    ///     each track keeps its own VAD stream state, so one stateless detector may serve both.
    ///   - save: persists a finished segment; awaited before the segment is announced in `updates`.
    init(
        meetingID: UUID,
        language: String?,
        engine: any MeetingSpeechTranscribing,
        detectorFactory: @escaping @Sendable (MeetingTrack) async throws -> any SpeechDetecting,
        save: @escaping @Sendable (MeetingSegmentRecord) async -> Void,
        config: UtteranceSegmenter.Config = .init()
    ) {
        self.meetingID = meetingID
        self.language = language
        self.engine = engine
        self.detectorFactory = detectorFactory
        self.save = save
        let (updates, updatesContinuation) = AsyncStream<MeetingLiveUpdate>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.updates = updates
        self.updatesContinuation = updatesContinuation
        var inputs: [MeetingTrack: AsyncStream<[Float]>.Continuation] = [:]
        var streams: [MeetingTrack: AsyncStream<[Float]>] = [:]
        var tracks: [MeetingTrack: TrackState] = [:]
        for track in MeetingTrack.allCases {
            let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
            inputs[track] = continuation
            streams[track] = stream
            tracks[track] = TrackState(segmenter: UtteranceSegmenter(config: config))
        }
        self.inputs = inputs
        self.streams = streams
        self.tracks = tracks
    }

    deinit {
        // Dropped without `finish()`: end the streams so the consumers and any listener stop.
        for continuation in inputs.values { continuation.finish() }
        updatesContinuation.finish()
    }

    /// Any thread (audio callbacks). Order per track is kept by the stream; samples fed after
    /// `finish()` are ignored.
    nonisolated func feed(_ samples: [Float], track: MeetingTrack) {
        guard !samples.isEmpty, let input = inputs[track] else { return }
        queued.withLock { $0[track, default: 0] += samples.count }
        if case .terminated = input.yield(samples) {
            queued.withLock { $0[track, default: 0] -= samples.count }
        }
    }

    /// Starts one pipeline per track. `finish()` starts them too if this was never called.
    func start() {
        guard consumers.isEmpty else { return }
        for track in MeetingTrack.allCases {
            guard let stream = streams[track] else { continue }
            // Weak: a transcriber dropped without `finish()` must still be released (its deinit ends the streams).
            consumers.append(Task { [weak self] in
                for await samples in stream {
                    guard let self else { return }
                    await self.process(samples, track: track)
                }
            })
        }
    }

    /// Ends both inputs, transcribes what is still queued, closes the open utterances, marks echo
    /// over the whole meeting and ends `updates`. `segments` (sorted by start) carry the final echo
    /// flags; `echoChanges` are the segments whose flag differs from what `save` stored, to write back.
    /// Calling it again (even while the first call runs) returns the same result.
    func finish() async -> Outcome {
        if let finishing { return await finishing.value }
        let task = Task { await self.closeAll() }
        finishing = task
        return await task.value
    }

    /// Samples held in the pipelines right now (open utterances, pre-rolls, partial VAD chunks),
    /// not counting input still queued in the streams.
    func bufferedSampleCount() -> Int {
        tracks.values.reduce(0) { $0 + $1.segmenter.bufferedSampleCount + $1.accumulator.pendingCount }
    }

    // MARK: Pipeline

    private func closeAll() async -> Outcome {
        start()
        for continuation in inputs.values { continuation.finish() }
        for consumer in consumers { await consumer.value }
        for track in MeetingTrack.allCases {
            guard var state = tracks[track] else { continue }
            let rest = state.accumulator.drain()
            var outputs = rest.isEmpty ? [] : state.segmenter.push(rest, speechStarted: false, speechEnded: false)
            outputs += state.segmenter.flush()
            tracks[track] = state
            await handle(outputs.filter(Self.isFinal), track: track, allowPartials: false)
        }
        let changes = EchoFilter.mark(segments)
        let changed = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        segments = segments.map { changed[$0.id] ?? $0 }
        updatesContinuation.finish()
        return (segments.sorted { $0.start < $1.start }, changes)
    }

    private func process(_ samples: [Float], track: MeetingTrack) async {
        queued.withLock { $0[track, default: 0] -= samples.count }
        guard var state = tracks[track] else { return }
        if state.detector == nil, state.received >= state.nextDetectorAttempt {
            do {
                let detector = try await detectorFactory(track)
                state.vadState = await detector.initialState()
                state.detector = detector
            } catch {
                state.nextDetectorAttempt = state.received + Self.detectorRetrySamples
                Log.transcription.error("Meeting VAD failed to load (\(track.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
        state.received += samples.count
        let chunks = state.accumulator.push(samples)
        tracks[track] = state
        for (index, chunk) in chunks.enumerated() {
            await process(chunk: chunk, track: track, chunksLeft: chunks.count - index - 1)
        }
    }

    /// One VAD chunk. Without a detector (or when it fails) the chunk still goes through the
    /// segmenter, with no speech events, so sample positions and all later times stay right.
    private func process(chunk: [Float], track: MeetingTrack, chunksLeft: Int) async {
        guard var state = tracks[track] else { return }
        var started = false
        var ended = false
        if let detector = state.detector, let vad = state.vadState {
            do {
                let result = try await detector.process(chunk, state: vad)
                state.vadState = result.state
                started = result.event?.isStart == true
                ended = result.event?.isEnd == true
                state.vadFailing = false
            } catch {
                if !state.vadFailing {
                    Log.transcription.error("Meeting VAD chunk failed (\(track.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
                state.vadFailing = true
            }
        }
        let outputs = state.segmenter.push(chunk, speechStarted: started, speechEnded: ended)
        tracks[track] = state
        let behind = chunksLeft * chunk.count + queued.withLock { $0[track, default: 0] }
        await handle(outputs, track: track, allowPartials: behind <= Self.partialBacklogLimit)
    }

    private func handle(_ outputs: [UtteranceSegmenter.Output], track: MeetingTrack, allowPartials: Bool) async {
        for output in outputs {
            switch output {
            case .partial(_, let samples):
                guard allowPartials else { continue }
                if let text = try? await engine.transcribeTimed(samples, language: language).text, !text.isEmpty {
                    updatesContinuation.yield(.partial(track, text))
                }
            case .final(let start, let samples):
                await transcribeFinal(start: start, samples: samples, track: track)
                // The grey line showed this utterance; it is final now (or turned out empty).
                updatesContinuation.yield(.partial(track, ""))
            }
        }
    }

    private func transcribeFinal(start: Int, samples: [Float], track: MeetingTrack) async {
        let timed: TimedTranscript
        do {
            timed = try await engine.transcribeTimed(samples, language: language)
        } catch {
            Log.transcription.error("Meeting pass failed (\(track.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !timed.text.isEmpty else { return }
        let offset = Double(start) / Self.sampleRate
        let segment = MeetingSegmentRecord(
            meetingID: meetingID,
            track: track,
            start: offset,
            end: offset + Double(samples.count) / Self.sampleRate,
            text: timed.text,
            words: timed.words.map { MeetingWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        )
        segments.append(segment)
        await save(segment)
        updatesContinuation.yield(.segment(segment))
    }

    private static func isFinal(_ output: UtteranceSegmenter.Output) -> Bool {
        if case .final = output { return true }
        return false
    }
}
