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

/// Throws on its first `failures` passes (a missing or broken speech model), then answers like
/// `CountingMeetingTranscriber`.
actor FlakyMeetingTranscriber: MeetingSpeechTranscribing {
    private(set) var calls = 0
    private let failures: Int

    init(failures: Int) {
        self.failures = failures
    }

    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript {
        calls += 1
        guard calls > failures else { throw ScriptedFailure() }
        let text = "słowa \(calls)"
        return TimedTranscript(text: text, words: [MeetingWord(text: text, start: 0, end: Double(samples.count) / 16_000)])
    }
}

/// Holds everyone who waits on it until `open()`; afterwards nobody waits.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Callers that had to wait so far.
    private(set) var waited = 0

    func wait() async {
        guard !isOpen else { return }
        waited += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let held = waiters
        waiters = []
        for waiter in held { waiter.resume() }
    }
}

/// A speech model whose every pass waits for `gate`: keeps a meeting's stop in "finishing".
actor GatedMeetingTranscriber: MeetingSpeechTranscribing {
    private let gate: TestGate

    init(gate: TestGate) {
        self.gate = gate
    }

    func transcribeTimed(_ samples: [Float], language: String?) async throws -> TimedTranscript {
        await gate.wait()
        return TimedTranscript(text: "słowa", words: [MeetingWord(text: "słowa", start: 0, end: Double(samples.count) / 16_000)])
    }
}

/// A post-processor that logs when it starts and finishes each meeting, reads the meeting's
/// title as it starts, and holds every run until `gate` opens.
actor GatedPostProcessor: MeetingPostProcessing {
    enum Event: Equatable {
        case started(UUID)
        case finished(UUID)
    }

    private(set) var events: [Event] = []
    private(set) var titles: [String] = []
    private let gate: TestGate
    private let database: Database

    init(gate: TestGate, database: Database) {
        self.gate = gate
        self.database = database
    }

    func process(meetingID: UUID) async {
        events.append(.started(meetingID))
        if let title = try? await database.meeting(id: meetingID)?.title {
            titles.append(title)
        }
        await gate.wait()
        events.append(.finished(meetingID))
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

/// Returns fixed speaker turns (or throws) and remembers every file it was asked to diarize.
actor ScriptedDiarizer: SpeakerDiarizing {
    private(set) var urls: [URL] = []
    private let turns: [SpeakerTurn]
    private let fails: Bool

    init(turns: [SpeakerTurn], fails: Bool = false) {
        self.turns = turns
        self.fails = fails
    }

    func diarize(url: URL) async throws -> [SpeakerTurn] {
        urls.append(url)
        if fails { throw ScriptedFailure() }
        return turns
    }
}

/// A calendar the test fills by hand: a fixed access state, what a prompt would grant, the
/// events every read returns, and `signalChange()` for "the calendar database changed".
final class FakeCalendarSource: CalendarEventSource, @unchecked Sendable {
    private struct State {
        var access: CalendarAccess
        var grants: CalendarAccess
        var events: [CalendarEvent]
        var requestCount = 0
        var readCount = 0
        var lastWindow: (from: Date, to: Date)?
        var listeners: [AsyncStream<Void>.Continuation] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(access: CalendarAccess, grants: CalendarAccess, events: [CalendarEvent]) {
        state = OSAllocatedUnfairLock(initialState: State(access: access, grants: grants, events: events))
    }

    var events: [CalendarEvent] {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    var requestCount: Int { state.withLock { $0.requestCount } }
    var readCount: Int { state.withLock { $0.readCount } }
    var lastWindow: (from: Date, to: Date)? { state.withLock { $0.lastWindow } }

    func access() -> CalendarAccess { state.withLock { $0.access } }

    func requestAccess() async -> CalendarAccess {
        state.withLock {
            $0.requestCount += 1
            $0.access = $0.grants
            return $0.access
        }
    }

    func events(from: Date, to: Date) async -> [CalendarEvent] {
        state.withLock {
            $0.readCount += 1
            $0.lastWindow = (from, to)
            return $0.events
        }
    }

    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            state.withLock { $0.listeners.append(continuation) }
        }
    }

    func signalChange() {
        for listener in state.withLock({ $0.listeners }) {
            listener.yield()
        }
    }
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
