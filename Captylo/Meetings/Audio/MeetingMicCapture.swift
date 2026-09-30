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
final class MeetingMicCapture: MeetingAudioSource, @unchecked Sendable {
    static let tapBufferSize: AVAudioFrameCount = 4_096
    static let retryDelay: DispatchTimeInterval = .seconds(2)

    /// State shared with the tap thread; replaced only under the lock.
    private struct Hot {
        var isActive = false
        var pipeline: AudioConversionPipeline?
        var onSamples: (@Sendable ([Float]) -> Void)?
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
            hot.withLockUnchecked { $0 = Hot(isActive: true, pipeline: nil, onSamples: onSamples) }
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
        hot.withLockUnchecked { $0.pipeline = pipeline }
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: native) { [weak self] buffer, _ in
            self?.handleTap(buffer)
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
        do {
            try buildLocked()
            if attempt > 1 {
                Log.audio.info("Meeting mic rebuilt after \(attempt) attempts")
            }
        } catch {
            teardownLocked()
            if attempt == 1 {
                Log.audio.error("Meeting mic rebuild failed, retrying: \(error.localizedDescription, privacy: .public)")
            }
            control.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.rebuildLocked(session: session, attempt: attempt + 1)
            }
        }
    }

    // MARK: Tap thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        let levelLock = self.levelLock
        let converted = hot.withLockUnchecked { state -> (samples: [Float], sink: @Sendable ([Float]) -> Void)? in
            guard state.isActive, let pipeline = state.pipeline, let sink = state.onSamples,
                  let output = pipeline.convert(buffer), output.frameLength > 0,
                  let channel = output.floatChannelData?[0] else { return nil }
            // The pipeline reuses its output buffer: copy before the next tap call.
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            levelLock.withLock { $0 = AudioLevel.rms(samples) }
            return (samples, sink)
        }
        guard let converted else { return }
        delivery.async { converted.sink(converted.samples) }
    }
}
