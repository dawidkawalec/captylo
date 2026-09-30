import FluidAudio
import Foundation
import os
@testable import Captylo

/// VAD that says "speech starts" at chunk `startAt` and "ends" at chunk `endAt` (per detector
/// instance, counted from its first chunk), and throws at chunk `failAt`.
actor ScriptedSpeechDetector: SpeechDetecting {
    private var index = 0
    private let startAt: Int
    private let endAt: Int?
    private let failAt: Int?

    init(startAt: Int, endAt: Int?, failAt: Int? = nil) {
        self.startAt = startAt
        self.endAt = endAt
        self.failAt = failAt
    }

    func initialState() async -> VadStreamState { .initial() }

    func process(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        defer { index += 1 }
        if index == failAt { throw ScriptedFailure() }
        let kind: VadStreamEvent.Kind? = index == startAt ? .speechStart : (index == endAt ? .speechEnd : nil)
        return VadStreamResult(state: state, event: kind.map { VadStreamEvent(kind: $0, sampleIndex: 0) }, probability: 0.9)
    }
}

struct ScriptedFailure: Error {}

/// A detector factory that fails its first `failures` calls (the VAD model could not load).
actor FlakyDetectorFactory {
    private(set) var attempts = 0
    private let failures: Int
    private let make: @Sendable () -> any SpeechDetecting

    init(failures: Int, make: @escaping @Sendable () -> any SpeechDetecting) {
        self.failures = failures
        self.make = make
    }

    func detector() throws -> any SpeechDetecting {
        attempts += 1
        guard attempts > failures else { throw ScriptedFailure() }
        return make()
    }
}

/// Returns "słowa <n>" with one word spanning the slice. With `keepsSamples` it also keeps
/// every slice it was given (only for short tests: partials copy the open utterance).
actor CountingMeetingTranscriber: MeetingSpeechTranscribing {
    private(set) var calls = 0
    private(set) var received: [[Float]] = []
    let fixedText: String?
    let keepsSamples: Bool

    init(fixedText: String? = nil, keepsSamples: Bool = false) {
        self.fixedText = fixedText
        self.keepsSamples = keepsSamples
    }

    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript {
        calls += 1
        if keepsSamples { received.append(samples) }
        let text = fixedText ?? "słowa \(calls)"
        return TimedTranscript(text: text, words: [MeetingWord(text: text, start: 0, end: Double(samples.count) / 16_000)])
    }
}

actor SegmentSink {
    private(set) var saved: [MeetingSegmentRecord] = []
    func save(_ segment: MeetingSegmentRecord) { saved.append(segment) }
}

/// A meeting source the test drives by hand: `push` delivers samples synchronously on the
/// caller's thread, like a source queue would.
final class FakeAudioSource: MeetingAudioSource, @unchecked Sendable {
    private struct Counts {
        var starts = 0
        var stops = 0
    }

    private let sink = OSAllocatedUnfairLock<(@Sendable ([Float]) -> Void)?>(initialState: nil)
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    var failOnStart = false
    var startCount: Int { counts.withLock { $0.starts } }
    var stopCount: Int { counts.withLock { $0.stops } }
    /// A sink is installed: `push` reaches the current session.
    var isRunning: Bool { sink.withLock { $0 != nil } }
    var level: Float { 0 }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        if failOnStart { throw MeetingAudioError.format }
        counts.withLock { $0.starts += 1 }
        sink.withLock { $0 = onSamples }
    }

    func stop() {
        counts.withLock { $0.stops += 1 }
        sink.withLock { $0 = nil }
    }

    func push(_ samples: [Float]) { sink.withLock { $0 }?(samples) }
}

@MainActor
final class MuteSpy {
    var calls: [Bool] = []
}

/// Counts VAD loads; fails the first `failures` of them.
actor CountingDetectorLoader {
    private(set) var loads = 0
    private let failures: Int

    init(failures: Int = 0) {
        self.failures = failures
    }

    func load() async throws -> any SpeechDetecting {
        loads += 1
        // Long enough for a second caller to arrive while this load runs.
        try await Task.sleep(for: .milliseconds(20))
        guard loads > failures else { throw ScriptedFailure() }
        return ScriptedSpeechDetector(startAt: 0, endAt: nil)
    }
}
