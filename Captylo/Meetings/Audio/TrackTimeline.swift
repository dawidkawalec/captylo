/// Keeps a live meeting track in step with the clock across holes in its capture.
///
/// Segment times are sample counts from a track's first sample, so time a source did not record
/// (the mic rebuilding on a new input, no input device for a while) still needs its samples.
/// Without them every later segment of that track lands too early against the other track
/// (echo removal, the order of lines and playback break) and its file ends up shorter.
///
/// Times are host-clock seconds. Only a hole opened by `interrupt()` is filled, so ordinary
/// jitter between buffers never adds samples. The owner delivers the returned silence before
/// the buffer it was asked about.
struct TrackTimeline: Sendable {
    /// Longest hole filled in one go, 10 minutes. While no input exists `fill(until:)` keeps pace
    /// in small steps, so only a bogus timestamp or an input that starts but stays mute for this
    /// long gets here; the cap keeps such a hole from flooding the track.
    static let maximumGap: Double = 600
    /// Silence is handed over in pieces of at most one second, never as one large array.
    static let silenceChunk = SampleBuffer.sampleRate

    let sampleRate: Double
    /// Where the delivered audio ends; nil until the session begins.
    private(set) var end: Double?
    private(set) var isInterrupted = false
    /// Silence filled for the current hole, or the last one closed (for the log).
    private(set) var filledInHole = 0

    init(sampleRate: Double = Double(SampleBuffer.sampleRate)) {
        self.sampleRate = sampleRate
    }

    /// A new session whose audio starts at `now`: nothing to fill yet.
    mutating func begin(at now: Double) {
        end = now
        isInterrupted = false
        filledInHole = 0
    }

    /// Capture stopped mid-session. Repeats while the hole is still open change nothing.
    mutating func interrupt() {
        guard !isInterrupted else { return }
        isInterrupted = true
        filledInHole = 0
    }

    /// Samples of silence to deliver before a buffer of `duration` seconds recorded from `start`:
    /// the hole since the audio delivered last, and zero unless this buffer closes a hole.
    mutating func silence(before start: Double, duration: Double) -> Int {
        defer { end = start + duration }
        guard isInterrupted else { return 0 }
        isInterrupted = false
        let silence = samples(from: end, to: start)
        filledInHole += silence
        return silence
    }

    /// Silence up to `now` while a hole is open, so a long outage keeps the track on the clock
    /// step by step instead of as one block when the input returns.
    mutating func fill(until now: Double) -> Int {
        guard isInterrupted, let end else { return 0 }
        let silence = samples(from: end, to: now)
        // Advance by exactly what was delivered, so rounding never drifts.
        self.end = end + Double(silence) / sampleRate
        filledInHole += silence
        return silence
    }

    /// Piece sizes for `count` samples of silence.
    static func silenceChunks(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: silenceChunk).map { min(silenceChunk, count - $0) }
    }

    private func samples(from start: Double?, to next: Double) -> Int {
        guard let start, (next - start).isFinite else { return 0 }
        let seconds = min(max(0, next - start), Self.maximumGap)
        return Int((seconds * sampleRate).rounded())
    }
}
