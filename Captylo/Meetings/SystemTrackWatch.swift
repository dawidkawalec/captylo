import Foundation

/// What the meeting recorder does about exact zeros on the "Rozmówcy" track: its policy on top
/// of `SilenceWatchdog`. It sits behind the recorder's lock because the sink runs on the tap's queue.
///
/// Zeros after real audio while another app plays look the same whether the other side is only
/// quiet (a call app keeps its output running and plays exact zeros, for minutes while the user
/// presents) or the tap hit the HAL zero-buffer bug (zeros for minutes while the call is audible,
/// only a rebuild recovers: research 04). So one silent run is handled in steps:
/// - The watchdog's `.stalled` every `stallAfter` (6 s) only measures the run. The tap is rebuilt
///   quietly after `rebuildIntervals`: 30 s of zeros, then 30 s, 60 s and every 120 s more. A
///   rebuild in a quiet stretch loses nothing, so it stores no gap.
/// - Real audio from the rebuilt tap within `recoveryWindow` of its first buffer: the rebuild
///   fixed a stall, the run is a gap ("przerwa w nagraniu") where its zeros began. Later audio:
///   the other side was only quiet, no gap.
/// - A rebuild that brought nothing back raises the warning (the live bar says the other side
///   cannot be heard) until real audio comes back or nothing plays anymore. A run that ends while
///   warning, without audio, is a gap too (`finish`), and so is a run whose rebuild failed
///   (`rebuildFailed`): the other side may be missing from there on.
///
/// Before any real audio, zeros while another app plays are either a call nobody spoke in yet,
/// a denied grant, or a tap created before the grant (the first meeting: it can stay on zeros
/// after "Allow"). The tap is rebuilt after `preAudioRebuildIntervals` (8 s, then 12 s, 20 s, 40 s
/// and every 120 s more), which costs nothing in a quiet call, and "no access" is only reported
/// after `noAccessAfter` (30 s), so a call that starts in silence does not raise it at once.
struct SystemTrackWatch: Sendable {
    /// What the recorder has to do after a buffer; usually nothing.
    struct Report: Equatable, Sendable {
        /// Zeros from the start while another app plays: "Brak dostępu do dźwięku systemu".
        var noAccess = false
        /// These samples are the first real audio of the meeting.
        var firstAudio = false
        /// Rebuild the tap now.
        var rebuild = false
        /// true raises the "cannot hear the other side" warning, false clears it.
        var warning: Bool?
        /// A gap to keep on the meeting, at the moment its silent run began.
        var gap: Date?

        var needsAction: Bool { self != Report() }
    }

    /// Seconds of zeros before each rebuild of one run; the last one repeats.
    static let rebuildIntervals: [Double] = [30, 30, 60, 120]
    /// Before any real audio: seconds of zeros (while another app plays) before each rebuild;
    /// the last one repeats.
    static let preAudioRebuildIntervals: [Double] = [8, 12, 20, 40, 120]
    /// Zeros from the start while another app plays, in seconds, before "no access" is reported.
    static let noAccessAfter: Double = 30
    /// Real audio this soon after the rebuilt tap's first buffer means the rebuild fixed a stall.
    static let recoveryWindow: Double = 3

    /// Zeros after real audio while another app plays, until real audio or nothing playing.
    private struct Run {
        /// Where the first zero of the run was recorded.
        let startedAt: Date
        /// Zeros so far, in the watchdog's `stallAfter` steps.
        var seconds: Double = 0
        var nextRebuild = SystemTrackWatch.rebuildIntervals[0]
        var rebuilds = 0
        /// The source session that asked for the last rebuild: later sessions are the rebuilt tap.
        var rebuiltFrom: Int?
        /// Samples the rebuilt tap delivered so far.
        var sinceRebuild = 0
        var isWarning = false
        var gapKept = false
    }

    private var dog = SilenceWatchdog(noAccessAfter: SystemTrackWatch.noAccessAfter)
    private var run: Run?
    /// Before any real audio: zero samples while another app plays, since the last time nothing played.
    private var preAudioZeros = 0
    private var preAudioRebuilds = 0
    private var nextPreAudioRebuild = SystemTrackWatch.preAudioRebuildIntervals[0]

    /// One buffer from source session `session` (a rebuilt tap is a new session), recorded by `now`.
    /// `expectingAudio` is only asked for silent buffers: another app plays output.
    mutating func observe(_ samples: [Float], session: Int, silent: Bool, expectingAudio: Bool, at now: Date) -> Report {
        var report = Report()
        guard !samples.isEmpty else { return report }
        let heardBefore = dog.heardAudio
        let verdict = dog.observe(samples, expectingAudio: expectingAudio)
        report.noAccess = verdict == .noAccess
        report.firstAudio = !heardBefore && dog.heardAudio

        guard silent, expectingAudio else {
            // Real audio, or nothing plays: the run is over.
            if let run {
                end(run, heardAudio: !silent, session: session, into: &report)
                self.run = nil
            }
            resetPreAudio()
            return report
        }
        // Before any real audio this is the watchdog's "no access" case, not a stall.
        guard heardBefore else {
            preAudioZeros += samples.count
            if Double(preAudioZeros) / Double(SampleBuffer.sampleRate) >= nextPreAudioRebuild {
                report.rebuild = true
                preAudioRebuilds += 1
                let intervals = Self.preAudioRebuildIntervals
                nextPreAudioRebuild += intervals[min(preAudioRebuilds, intervals.count - 1)]
            }
            return report
        }

        let duration = Double(samples.count) / Double(SampleBuffer.sampleRate)
        var current = run ?? Run(startedAt: now.addingTimeInterval(-duration))
        if let from = current.rebuiltFrom, session > from {
            current.sinceRebuild += samples.count
        }
        if verdict == .stalled {
            current.seconds += dog.stallAfter
            if current.seconds >= current.nextRebuild {
                report.rebuild = true
                if current.rebuilds > 0, !current.isWarning {
                    current.isWarning = true
                    report.warning = true
                }
                current.rebuilds += 1
                current.nextRebuild += Self.rebuildIntervals[min(current.rebuilds, Self.rebuildIntervals.count - 1)]
                current.rebuiltFrom = session
                current.sinceRebuild = 0
            }
        }
        run = current
        return report
    }

    /// The meeting stops: a run still warning is a gap where it began. Once per run.
    mutating func finish() -> Date? {
        guard let current = run, current.isWarning else { return nil }
        return keepGap()
    }

    /// The rebuild this watch asked for failed, so the tap is gone: the run is a gap where it
    /// began. Once per run.
    mutating func rebuildFailed() -> Date? {
        guard let current = run, current.rebuilds > 0 else { return nil }
        return keepGap()
    }

    private mutating func resetPreAudio() {
        preAudioZeros = 0
        preAudioRebuilds = 0
        nextPreAudioRebuild = Self.preAudioRebuildIntervals[0]
    }

    private mutating func keepGap() -> Date? {
        guard var current = run, !current.gapKept else { return nil }
        current.gapKept = true
        run = current
        return current.startedAt
    }

    private func end(_ run: Run, heardAudio: Bool, session: Int, into report: inout Report) {
        if run.isWarning {
            report.warning = false
        }
        guard !run.gapKept else { return }
        if heardAudio {
            let window = Int(Self.recoveryWindow * Double(SampleBuffer.sampleRate))
            if let from = run.rebuiltFrom, session > from, run.sinceRebuild < window {
                report.gap = run.startedAt
            }
        } else if run.isWarning {
            report.gap = run.startedAt
        }
    }
}
