import Foundation
import os

/// One live meeting track on its way to its file and to the transcriber, kept on the meeting clock.
///
/// Segment times and the file length come from sample counts, so a track needs a sample for every
/// moment of the meeting. The feed pads what its source never recorded: the time between the
/// meeting start and the source's first buffer (the tap starts after the mic, the first tap start
/// can wait on the system prompt), and the hole a source leaves when it is rebuilt mid-meeting
/// (a new `session`). Buffers of one session count as continuous, so delivery jitter never adds
/// samples; gaps inside a session are the source's own job (`MeetingMicCapture`).
///
/// Thread safe: sources deliver on their own serial queues, the recorder closes on the main actor.
/// Writing happens under the lock, so the file and the transcriber always get the same order.
final class MeetingTrackFeed: Sendable {
    private struct Clock {
        var timeline = TrackTimeline()
        /// Session of the last buffer; nil before the first one.
        var session: Int?
        var isClosed = false
    }

    let track: MeetingTrack
    private let writer: TrackFileWriter?
    private let transcriber: MeetingTranscriber
    private let clock: OSAllocatedUnfairLock<Clock>

    /// - Parameters:
    ///   - writer: nil when the track file could not be created; the transcript still gets the audio.
    ///   - startedAt: the meeting start on the `now()` clock.
    init(track: MeetingTrack, writer: TrackFileWriter?, transcriber: MeetingTranscriber, startedAt: Double) {
        self.track = track
        self.writer = writer
        self.transcriber = transcriber
        var clock = Clock()
        clock.timeline.begin(at: startedAt)
        self.clock = OSAllocatedUnfairLock(initialState: clock)
    }

    /// Monotonic seconds for `startedAt` and `deliver(_:session:at:)`.
    static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    /// A buffer that arrived at `now` from source session `session`. The first buffer of every
    /// session is preceded by silence for the time since the audio delivered last (or since the
    /// meeting start). Ignored after `close()`.
    func deliver(_ samples: [Float], session: Int, at now: Double = MeetingTrackFeed.now()) {
        guard !samples.isEmpty else { return }
        let duration = Double(samples.count) / Double(SampleBuffer.sampleRate)
        let writer = self.writer
        let transcriber = self.transcriber
        let track = self.track
        let padded = clock.withLock { state -> Int in
            guard !state.isClosed else { return 0 }
            if state.session != session {
                state.session = session
                state.timeline.interrupt()
            }
            let silence = state.timeline.silence(before: now - duration, duration: duration)
            for size in TrackTimeline.silenceChunks(silence) {
                let zeros = [Float](repeating: 0, count: size)
                writer?.append(zeros)
                transcriber.feed(zeros, track: track)
            }
            writer?.append(samples)
            transcriber.feed(samples, track: track)
            return silence
        }
        if padded > 0 {
            let seconds = Double(padded) / Double(SampleBuffer.sampleRate)
            Log.audio.info("Meeting track \(track.rawValue, privacy: .public): \(seconds, format: .fixed(precision: 2)) s without audio filled with silence")
        }
    }

    /// Finalizes the file; later buffers are dropped.
    func close() {
        clock.withLock { $0.isClosed = true }
        writer?.close()
    }
}
