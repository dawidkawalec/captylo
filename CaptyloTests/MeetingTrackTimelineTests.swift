import Testing
@testable import Captylo

struct MeetingTrackTimelineTests {
    /// 0.1 s tap buffers as the mic delivers them, with host times in seconds.
    private let buffer = 0.1

    @Test func ordinaryBuffersNeverAddSilenceEvenWithJitter() {
        var timeline = TrackTimeline()
        timeline.begin(at: 100)
        var start = 100.0
        for index in 0..<50 {
            // A few milliseconds late or early: clock jitter, not a hole.
            let jitter = index.isMultiple(of: 2) ? 0.004 : -0.003
            #expect(timeline.silence(before: start + jitter, duration: buffer) == 0)
            start += buffer
        }
        #expect(!timeline.isInterrupted)
    }

    @Test func theFirstBufferAfterARebuildFillsTheHole() {
        var timeline = TrackTimeline()
        timeline.begin(at: 10)
        #expect(timeline.silence(before: 10, duration: buffer) == 0)
        #expect(timeline.silence(before: 10.1, duration: buffer) == 0)
        // Audio ends at 10.2; the new engine records from 10.55.
        timeline.interrupt()
        #expect(timeline.silence(before: 10.55, duration: buffer) == 5_600)
        #expect(timeline.filledInHole == 5_600)
        #expect(!timeline.isInterrupted)
        // Back to normal: the next buffer adds nothing.
        #expect(timeline.silence(before: 10.65, duration: buffer) == 0)
    }

    @Test func aLongOutageKeepsPaceInStepsAndTheTrackStaysOnTheClock() {
        // 48 kHz buffers of 4 800 frames give 1 600 samples each at 16 kHz. Two seconds of audio,
        // then no input device for about a minute (a fill every 2 s, as the retries run), then
        // the mic returns. The first sample after the hole must sit where the clock says.
        var timeline = TrackTimeline()
        let sessionStart = 1_000.0
        timeline.begin(at: sessionStart)
        var delivered = 0
        var start = sessionStart
        for _ in 0..<20 {
            delivered += timeline.silence(before: start, duration: buffer) + 1_600
            start += buffer
        }
        timeline.interrupt()
        var now = start + 0.03
        var largestStep = 0
        while now < start + 61 {
            timeline.interrupt()
            let step = timeline.fill(until: now)
            largestStep = max(largestStep, step)
            delivered += step
            now += 2
        }
        let resumedAt = now + 0.2
        delivered += timeline.silence(before: resumedAt, duration: buffer)
        let trackTime = Double(delivered) / 16_000
        #expect(abs(trackTime - (resumedAt - sessionStart)) < 0.001)
        // No step is larger than one retry period (plus the first late start).
        #expect(largestStep <= 2 * 16_000 + 1)
        #expect(timeline.filledInHole == delivered - 20 * 1_600)
    }

    @Test func anOverlapOrAStaleTimestampAddsNothing() {
        var timeline = TrackTimeline()
        timeline.begin(at: 5)
        #expect(timeline.silence(before: 5, duration: buffer) == 0)
        timeline.interrupt()
        // The new engine reports a start before the old audio ended.
        #expect(timeline.silence(before: 5.05, duration: buffer) == 0)
        timeline.interrupt()
        #expect(timeline.fill(until: 4) == 0)
    }

    @Test func aHugeHoleIsCappedSoABogusTimestampCannotFloodTheTrack() {
        var timeline = TrackTimeline()
        timeline.begin(at: 0)
        #expect(timeline.silence(before: 0, duration: buffer) == 0)
        timeline.interrupt()
        let silence = timeline.silence(before: 1_000_000, duration: buffer)
        #expect(silence == Int(TrackTimeline.maximumGap * 16_000))
    }

    @Test func nothingIsFilledOutsideAHoleOrBeforeTheSessionBegins() {
        var fresh = TrackTimeline()
        fresh.interrupt()
        #expect(fresh.fill(until: 50) == 0)
        #expect(fresh.silence(before: 50, duration: 0.1) == 0)

        var running = TrackTimeline()
        running.begin(at: 1)
        #expect(running.fill(until: 30) == 0)
    }

    @Test func aRepeatedInterruptKeepsTheHoleItIsIn() {
        var timeline = TrackTimeline()
        timeline.begin(at: 0)
        #expect(timeline.silence(before: 0, duration: 1) == 0)
        timeline.interrupt()
        #expect(timeline.fill(until: 3) == 32_000)
        // Another failed attempt of the same rebuild must not forget what was filled.
        timeline.interrupt()
        #expect(timeline.silence(before: 3.5, duration: 0.1) == 8_000)
        #expect(timeline.filledInHole == 40_000)
    }

    @Test func beginStartsAFreshSession() {
        var timeline = TrackTimeline()
        timeline.begin(at: 0)
        timeline.interrupt()
        #expect(timeline.fill(until: 1) == 16_000)
        timeline.begin(at: 500)
        #expect(!timeline.isInterrupted)
        #expect(timeline.filledInHole == 0)
        #expect(timeline.silence(before: 500.02, duration: 0.1) == 0)
    }

    @Test func silenceIsHandedOverInPiecesOfAtMostOneSecond() {
        #expect(TrackTimeline.silenceChunks(0).isEmpty)
        #expect(TrackTimeline.silenceChunks(5_600) == [5_600])
        #expect(TrackTimeline.silenceChunks(16_000) == [16_000])
        #expect(TrackTimeline.silenceChunks(40_000) == [16_000, 16_000, 8_000])
    }
}
