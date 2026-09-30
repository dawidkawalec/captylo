/// A denied "System Audio Recording" grant and the long-session HAL bug both deliver exact zeros
/// while `noErr` is returned everywhere. Exact zeros for a few seconds while another app is
/// playing means: no access (never heard anything) or a stalled tap (heard audio before).
///
/// Verdicts are events: `.noAccess` fires once when a silent run crosses `noAccessAfter`,
/// `.stalled` fires every `stallAfter` seconds of the run; one alone means little, because a call
/// app plays exact zeros while the other side is quiet (the meeting recorder's `SystemTrackWatch`
/// counts them and decides when to rebuild the tap). A run ends when real audio arrives or
/// nothing is playing.
struct SilenceWatchdog: Sendable {
    enum Verdict: Equatable, Sendable { case ok, noAccess, stalled }

    let noAccessAfter: Double
    let stallAfter: Double
    private(set) var heardAudio = false
    /// Zero samples in the current run. Counted in samples, not summed seconds, so ten
    /// 0.1 s buffers really make 1 s.
    private var zeroSamples = 0

    init(noAccessAfter: Double = 4, stallAfter: Double = 6) {
        self.noAccessAfter = noAccessAfter
        self.stallAfter = stallAfter
    }

    mutating func observe(_ samples: [Float], expectingAudio: Bool, sampleRate: Double = 16_000) -> Verdict {
        guard !samples.isEmpty else { return .ok }
        if samples.contains(where: { $0 != 0 }) {
            heardAudio = true
            zeroSamples = 0
            return .ok
        }
        guard expectingAudio else {
            zeroSamples = 0
            return .ok
        }
        let before = Double(zeroSamples) / sampleRate
        zeroSamples += samples.count
        let run = Double(zeroSamples) / sampleRate
        if !heardAudio {
            return before < noAccessAfter && run >= noAccessAfter ? .noAccess : .ok
        }
        if run >= stallAfter {
            zeroSamples = 0
            return .stalled
        }
        return .ok
    }
}
