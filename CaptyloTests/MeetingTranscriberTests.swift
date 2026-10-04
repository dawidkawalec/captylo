import Foundation
import Testing
@testable import Captylo

struct MeetingTranscriberTests {
    private func chunk(_ n: Int = 4_096) -> [Float] { Array(repeating: 0.1, count: n) }

    /// No partials, no pre-roll: every test sees exactly the chunks it scripted.
    private let quick = UtteranceSegmenter.Config(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 1_000_000)

    @Test func eachTrackProducesTimedSegmentsThatAreSaved() async throws {
        let sink = SegmentSink()
        let meetingID = UUID()
        let transcriber = MeetingTranscriber(
            meetingID: meetingID, language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 1, endAt: 5) },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        for _ in 0..<8 {
            transcriber.feed(chunk(), track: .me)
            transcriber.feed(chunk(), track: .them)
        }
        let result = await transcriber.finish()
        let saved = await sink.saved
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.track)) == [.me, .them])
        let me = try #require(saved.first { $0.track == .me })
        #expect(me.meetingID == meetingID)
        #expect(abs(me.start - 4_096.0 / 16_000) < 0.001)
        #expect(abs(me.end - me.start - 5.0 * 4_096 / 16_000) < 0.001)
        #expect(me.words.first?.start == me.start)
        #expect(result.segments.count == 2)
    }

    @Test func feedingAcrossOddSizesKeepsOrder() async throws {
        let sink = SegmentSink()
        let engine = CountingMeetingTranscriber(keepsSamples: true)
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: engine,
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        let ramp = (0..<16_000).map(Float.init)
        var index = 0
        for size in [1_000, 3_000, 5_000, 7_000] {
            transcriber.feed(Array(ramp[index..<(index + size)]), track: .me)
            index += size
        }
        _ = await transcriber.finish()
        #expect(await sink.saved.count == 1)
        #expect(await sink.saved.first?.start == 0)
        // Three whole VAD chunks plus the drained remainder, in the order they were fed.
        #expect(await engine.received == [ramp])
    }

    @Test func memoryStaysBoundedDuringLongSpeech() async throws {
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: nil) },
            save: { _ in },
            config: .init()
        )
        await transcriber.start()
        for _ in 0..<(60 * 16_000 / 4_096) { transcriber.feed(chunk(), track: .them) } // 60 s of speech
        for _ in 0..<20 {
            #expect(await transcriber.bufferedSampleCount() <= 14 * 16_000 + 2 * 4_096)
            try await Task.sleep(for: .milliseconds(15))
        }
        let result = await transcriber.finish()
        #expect(result.segments.count >= 4) // 60 s cut into 14 s pieces
        #expect(await transcriber.bufferedSampleCount() == 0)
    }

    @Test func echoIsMarkedAtTheEnd() async throws {
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl",
            engine: CountingMeetingTranscriber(fixedText: "wdrożenie przesuwamy na piątek bo testy"),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 1, endAt: 5) },
            save: { _ in },
            config: quick
        )
        await transcriber.start()
        for _ in 0..<8 {
            transcriber.feed(chunk(), track: .them)
            transcriber.feed(chunk(), track: .me)
        }
        let result = await transcriber.finish()
        #expect(result.echoChanges.count == 1)
        #expect(result.echoChanges.first?.track == .me)
        #expect(result.echoChanges.first?.isEcho == true)
        // The returned segments carry the final flag too.
        #expect(result.segments.filter(\.isEcho).map(\.track) == [.me])
    }

    @Test func liveUpdatesShowPartialsThenTheSegment() async throws {
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
            save: { _ in },
            config: .init(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 4_096)
        )
        await transcriber.start()
        for _ in 0..<4 { transcriber.feed(chunk(), track: .me) }
        _ = await transcriber.finish()
        var updates: [MeetingLiveUpdate] = []
        for await update in transcriber.updates { updates.append(update) }
        try #require(updates.count == 5)
        #expect(Array(updates.prefix(3)) == [.partial(.me, "słowa 1"), .partial(.me, "słowa 2"), .partial(.me, "słowa 3")])
        guard case .segment(let segment) = updates[3] else {
            Issue.record("expected the final segment, got \(updates[3])")
            return
        }
        #expect(segment.text == "słowa 4")
        #expect(updates[4] == .partial(.me, "")) // the grey line is cleared
    }

    @Test func aFailedVadChunkKeepsTheTrackTimeline() async throws {
        let sink = SegmentSink()
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 2, endAt: 5, failAt: 1) },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        for _ in 0..<8 { transcriber.feed(chunk(), track: .me) }
        _ = await transcriber.finish()
        let segment = try #require(await sink.saved.first)
        #expect(abs(segment.start - 2.0 * 4_096 / 16_000) < 0.001)
        #expect(abs(segment.end - segment.start - 4.0 * 4_096 / 16_000) < 0.001)
    }

    @Test func aVadThatFailsToLoadIsRetriedLaterWithoutShiftingTimes() async throws {
        let sink = SegmentSink()
        let flaky = FlakyDetectorFactory(failures: 1) { ScriptedSpeechDetector(startAt: 1, endAt: 3) }
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in try await flaky.detector() },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        // The first push fails to load the VAD; the next try waits for `detectorRetrySamples` of audio.
        let retryChunk = (MeetingTranscriber.detectorRetrySamples + 4_095) / 4_096
        for _ in 0..<(retryChunk + 8) { transcriber.feed(chunk(), track: .me) }
        _ = await transcriber.finish()
        #expect(await flaky.attempts == 2)
        let segment = try #require(await sink.saved.first)
        #expect(abs(segment.start - Double(retryChunk + 1) * 4_096 / 16_000) < 0.001)
        #expect(abs(segment.end - segment.start - 3.0 * 4_096 / 16_000) < 0.001)
    }

    private func problems(_ updates: [MeetingLiveUpdate]) -> [MeetingLiveUpdate] {
        updates.filter {
            if case .problem = $0 { return true }
            return false
        }
    }

    /// The first meeting offline: the VAD cannot download, so nothing becomes a line. The live
    /// view must say so until a retry loads it.
    @Test func aVadThatCannotLoadIsReportedUntilItLoads() async throws {
        let flaky = FlakyDetectorFactory(failures: 1) { ScriptedSpeechDetector(startAt: 1, endAt: 3) }
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in try await flaky.detector() },
            save: { _ in },
            config: quick
        )
        await transcriber.start()
        let retryChunk = (MeetingTranscriber.detectorRetrySamples + 4_095) / 4_096
        for _ in 0..<(retryChunk + 8) { transcriber.feed(chunk(), track: .me) }
        _ = await transcriber.finish()
        var updates: [MeetingLiveUpdate] = []
        for await update in transcriber.updates { updates.append(update) }
        #expect(problems(updates) == [.problem(.speechDetector), .problem(nil)])
        #expect(updates.first == .problem(.speechDetector))
        #expect(updates.contains { if case .segment = $0 { return true } else { return false } })
    }

    /// A pass that throws (the model is missing or broken) loses that line: the live view says
    /// so until a pass works again, whichever track it was on.
    @Test func aFailingPassIsReportedUntilAPassWorks() async throws {
        let sink = SegmentSink()
        let engine = FlakyMeetingTranscriber(failures: 1)
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: engine,
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        for _ in 0..<4 { transcriber.feed(chunk(), track: .me) }
        for _ in 0..<300 where await engine.calls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<4 { transcriber.feed(chunk(), track: .them) }
        _ = await transcriber.finish()
        var updates: [MeetingLiveUpdate] = []
        for await update in transcriber.updates { updates.append(update) }
        #expect(problems(updates) == [.problem(.speechModel), .problem(nil)])
        #expect(await sink.saved.map(\.track) == [.them])
    }

    @Test func partialsAreSkippedWhileTheTrackIsBehind() async throws {
        let sink = SegmentSink()
        let engine = CountingMeetingTranscriber()
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: engine,
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: nil) },
            save: { await sink.save($0) },
            config: .init(maxSamples: 1_000_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 4_096)
        )
        // 40 chunks queue up before the pipeline runs, so it starts about 10 s behind.
        let count = 40
        for _ in 0..<count { transcriber.feed(chunk(), track: .me) }
        await transcriber.start()
        _ = await transcriber.finish()
        let caughtUp = (0..<count).filter { (count - 1 - $0) * 4_096 <= MeetingTranscriber.partialBacklogLimit }.count
        #expect(caughtUp > 0)
        #expect(await engine.calls == caughtUp + 1) // partials once caught up, plus the final
        #expect(await sink.saved.count == 1)
    }

    @Test func finishWithoutStartStillTranscribesWhatWasFed() async throws {
        let sink = SegmentSink()
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 1, endAt: 5) },
            save: { await sink.save($0) },
            config: quick
        )
        for _ in 0..<8 { transcriber.feed(chunk(), track: .me) }
        let result = await transcriber.finish()
        #expect(result.segments.count == 1)
        #expect(await sink.saved.count == 1)
    }

    @Test func finishingTwiceGivesOneResult() async throws {
        let sink = SegmentSink()
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 1, endAt: nil) },
            save: { await sink.save($0) },
            config: quick
        )
        await transcriber.start()
        for _ in 0..<8 { transcriber.feed(chunk(), track: .me) }
        async let first = transcriber.finish()
        async let second = transcriber.finish()
        let (a, b) = await (first, second)
        #expect(a.segments.count == 1) // the open utterance, flushed once
        #expect(a.segments == b.segments)
        #expect(await sink.saved.count == 1)
        // Samples fed after the end are ignored.
        transcriber.feed(chunk(), track: .me)
        #expect(await transcriber.finish().segments == a.segments)
    }

    @Test func aTranscriberDroppedWithoutFinishIsReleased() async throws {
        var transcriber: MeetingTranscriber? = MeetingTranscriber(
            meetingID: UUID(), language: "pl", engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: nil) },
            save: { _ in },
            config: quick
        )
        weak let probe = transcriber
        await transcriber?.start()
        transcriber?.feed(chunk(), track: .me)
        transcriber = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while probe != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe == nil)
    }
}
