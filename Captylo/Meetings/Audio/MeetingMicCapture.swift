@preconcurrency import AVFoundation
import os

/// "Ja": the default input device (the one the call uses; forcing another mic would switch
/// AirPods to call mode and hurt the call), on its own engine so dictation keeps working.
///
/// Engine work (start, stop, rebuild) runs on `control`. The tap block converts to 16 kHz mono
/// under `hot` (the same pattern as `AudioCapture`) and hands a copy to `delivery`, so consumers
/// never run on the engine's thread. A device change mid-meeting (AirPods connect or drop, the
/// default input changes) stops an `AVAudioEngine`; instead of going silent for the rest of the
/// meeting the capture rebuilds on the new default input, retrying while no input exists.
///
/// Segment times are counted in samples, so the time the mic did not record during a rebuild is
/// delivered as silence (`TrackTimeline`, host times of the tap buffers): every 2 s while no
/// input exists, and the rest before the first buffer of the new engine. "Ja" stays in step
/// with "Rozmówcy" and `me.caf` keeps the meeting's length.
final class MeetingMicCapture: MeetingAudioSource, @unchecked Sendable {
    static let tapBufferSize: AVAudioFrameCount = 4_096
    static let retryDelay: DispatchTimeInterval = .seconds(2)

    /// State shared with the tap thread; replaced only under the lock.
    private struct Hot {
        var isActive = false
        var pipeline: AudioConversionPipeline?
        var onSamples: (@Sendable ([Float]) -> Void)?
        /// The engine build the pipeline belongs to: a late buffer of a torn-down engine is dropped.
        var build = 0
        var timeline = TrackTimeline()
    }

    private let control = DispatchQueue(label: "com.captylo.app.meeting.mic.control", qos: .userInitiated)
    private let delivery = DispatchQueue(label: "com.captylo.app.meeting.mic", qos: .userInitiated)
    private let hot = OSAllocatedUnfairLock(uncheckedState: Hot())
    private let levelLock = OSAllocatedUnfairLock<Float>(initialState: 0)

    // Touched only on `control`.
    private var engine: AVAudioEngine?
    private var nativeFormat: AVAudioFormat?
    private var configObserver: (any NSObjectProtocol)?
    /// Bumped by every start and stop, so a pending rebuild retry of an old session gives up.
    private var session = 0
    /// Bumped by every engine build, never reset, so no two taps ever share a number.
    private var builds = 0

    var level: Float { levelLock.withLock { $0 } }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        try control.sync {
            teardownLocked()
            session += 1
            let now = Self.hostSeconds()
            hot.withLockUnchecked {
                $0 = Hot(isActive: true, pipeline: nil, onSamples: onSamples)
                $0.timeline.begin(at: now)
            }
            do {
                try buildLocked()
            } catch {
                hot.withLockUnchecked { $0 = Hot() }
                teardownLocked()
                throw error
            }
        }
    }

    func stop() {
        let wasActive = control.sync { () -> Bool in
            session += 1
            let active = hot.withLockUnchecked { state -> Bool in
                let active = state.isActive
                state = Hot()
                return active
            }
            teardownLocked()
            return active
        }
        levelLock.withLock { $0 = 0 }
        if wasActive {
            Log.audio.info("Meeting mic stopped")
        }
    }

    // MARK: Control queue

    /// A fresh engine on the current default input, with tap, pipeline and change observer.
    private func buildLocked() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.inputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0,
              let pipeline = AudioConversionPipeline(native: native, target: AudioCapture.targetFormat) else {
            throw MeetingAudioError.format
        }
        builds += 1
        let build = builds
        hot.withLockUnchecked {
            $0.pipeline = pipeline
            $0.build = build
        }
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: native) { [weak self] buffer, when in
            self?.handleTap(buffer, when: when, build: build)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        self.engine = engine
        nativeFormat = native
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw MeetingAudioError.engine(error.localizedDescription)
        }
        Log.audio.info("Meeting mic started: \(native.sampleRate, format: .fixed(precision: 0)) Hz, \(native.channelCount) ch")
    }

    private func teardownLocked() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        nativeFormat = nil
        hot.withLockUnchecked { $0.pipeline = nil }
    }

    private func handleConfigurationChange() {
        control.async { [weak self] in
            guard let self, let engine = self.engine, self.hot.withLockUnchecked({ $0.isActive }) else { return }
            // Another device came or went while ours still records in the same format: keep going.
            if engine.isRunning, engine.inputNode.inputFormat(forBus: 0) == self.nativeFormat { return }
            Log.audio.warning("Meeting mic: audio configuration changed, rebuilding on the default input")
            self.rebuildLocked(session: self.session, attempt: 1)
        }
    }

    private func rebuildLocked(session: Int, attempt: Int) {
        guard session == self.session, hot.withLockUnchecked({ $0.isActive }) else { return }
        teardownLocked()
        // The hole starts at the end of the audio delivered last; the outage fills and the first
        // buffer of the new engine close it.
        hot.withLockUnchecked { $0.timeline.interrupt() }
        do {
            try buildLocked()
            if attempt > 1 {
                Log.audio.info("Meeting mic rebuilt after \(attempt) attempts")
            }
        } catch {
            teardownLocked()
            fillOutageLocked()
            if attempt == 1 {
                Log.audio.error("Meeting mic rebuild failed, retrying: \(error.localizedDescription, privacy: .public)")
            }
            control.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.rebuildLocked(session: session, attempt: attempt + 1)
            }
        }
    }

    /// No input yet: silence up to now, so while the retries run the track keeps pace in 2 s
    /// steps instead of one large block when an input returns.
    private func fillOutageLocked() {
        let now = Self.hostSeconds()
        let delivery = self.delivery
        hot.withLockUnchecked { state in
            guard state.isActive, let sink = state.onSamples else { return }
            let silence = state.timeline.fill(until: now)
            guard silence > 0 else { return }
            delivery.async { Self.deliverSilence(silence, to: sink) }
        }
        levelLock.withLock { $0 = 0 }
    }

    // MARK: Tap thread

    private func handleTap(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, build: Int) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let start = Self.startSeconds(of: when, duration: duration)
        let levelLock = self.levelLock
        let delivery = self.delivery
        let closedHole = hot.withLockUnchecked { state -> Int? in
            guard state.isActive, state.build == build, let pipeline = state.pipeline,
                  let sink = state.onSamples else { return nil }
            let closesHole = state.timeline.isInterrupted
            let silence = state.timeline.silence(before: start, duration: duration)
            let samples = Self.copy(pipeline.convert(buffer))
            if !samples.isEmpty {
                levelLock.withLock { $0 = AudioLevel.rms(samples) }
            }
            // Enqueued under the lock, so silence and audio reach `delivery` in timeline order.
            if silence > 0 || !samples.isEmpty {
                delivery.async {
                    Self.deliverSilence(silence, to: sink)
                    if !samples.isEmpty {
                        sink(samples)
                    }
                }
            }
            return closesHole ? state.timeline.filledInHole : nil
        }
        if let closedHole {
            let seconds = Double(closedHole) / Double(SampleBuffer.sampleRate)
            Log.audio.info("Meeting mic resumed, \(seconds, format: .fixed(precision: 2)) s without input filled with silence")
        }
    }

    /// The converted samples. The pipeline reuses its output buffer: copy before the next tap call.
    private static func copy(_ output: AVAudioPCMBuffer?) -> [Float] {
        guard let output, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func deliverSilence(_ count: Int, to sink: @Sendable ([Float]) -> Void) {
        for size in TrackTimeline.silenceChunks(count) {
            sink([Float](repeating: 0, count: size))
        }
    }

    // MARK: Host time

    private static func hostSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// When the buffer's first sample was recorded: its host time, or an estimate from now
    /// when the engine gives none.
    private static func startSeconds(of when: AVAudioTime, duration: Double) -> Double {
        when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : hostSeconds() - duration
    }
}
