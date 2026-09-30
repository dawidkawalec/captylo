@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

enum AudioCaptureError: LocalizedError, Sendable, Equatable {
    case deviceSelection(String)
    case invalidFormat
    case converterUnavailable
    case fileCreation(String)
    case engineStart(String)

    var errorDescription: String? {
        switch self {
        case .deviceSelection(let reason):
            return String(localized: "Nie udało się wybrać mikrofonu: \(reason)")
        case .invalidFormat:
            return String(localized: "Mikrofon zgłasza nieprawidłowy format dźwięku.")
        case .converterUnavailable:
            return String(localized: "Nie udało się przygotować konwersji dźwięku.")
        case .fileCreation(let reason):
            return String(localized: "Nie udało się utworzyć pliku nagrania: \(reason)")
        case .engineStart(let reason):
            return String(localized: "Nie udało się uruchomić nagrywania: \(reason)")
        }
    }
}

/// `AVAudioEngine` input tap on one chosen device (architecture decision "Audio capture").
///
/// Every engine call (configure, prepare, start, stop) runs on one serial queue bridged with
/// continuations. The tap block runs on the engine's tap thread and touches only the
/// lock-guarded `HotState`: it converts the native buffer to 16 kHz mono Float32 through one
/// persistent `AVAudioConverter`, appends the samples to the `SampleBuffer`, writes the WAV
/// and stores the level. A tap firing after `stop()` sees `isActive == false` and drops out.
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    static let targetFormat = AVAudioFormat(standardFormatWithSampleRate: Double(SampleBuffer.sampleRate), channels: 1)!
    static let tapBufferSize: AVAudioFrameCount = 2048

    /// 16 kHz mono Int16 WAV; the file converts from the Float32 processing format.
    private static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SampleBuffer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// State shared with the tap thread. `pipeline` and `file` are replaced only under the lock.
    private struct HotState {
        var isActive = false
        var isPaused = false
        var diedFired = false
        var samplesWritten = 0
        var pipeline: AudioConversionPipeline?
        var file: AVAudioFile?
        var buffer: SampleBuffer?
        var writeErrorLogged = false
    }

    private let level: LevelMeter
    private let queue = DispatchQueue(label: "com.captylo.app.audio.capture", qos: .userInitiated)
    private let hot = OSAllocatedUnfairLock(uncheckedState: HotState())
    private let deviceDiedHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    // Engine state, touched only on `queue`.
    private var engine: AVAudioEngine?
    private var device: AudioDeviceID?
    private var tapInstalled = false
    private var engineStale = false
    private var fileURL: URL?
    private var configObserver: (any NSObjectProtocol)?
    private var aliveListener: AudioObjectListener?

    init(level: LevelMeter) {
        self.level = level
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    // MARK: AudioCapturing

    var onDeviceDied: (@Sendable () -> Void)? {
        get { deviceDiedHandler.withLock { $0 } }
        set { deviceDiedHandler.withLock { $0 = newValue } }
    }

    func prepare(device: AudioDeviceID) async throws {
        try await onQueue {
            let started = ContinuousClock.now
            try self.configureLocked(device: device)
            self.installTapLocked()
            self.engine?.prepare()
            let elapsed = ContinuousClock.now - started
            Log.audio.info("Capture prepared for device \(device) in \(elapsed.milliseconds) ms")
        }
    }

    func start(device: AudioDeviceID, fileURL: URL, into buffer: SampleBuffer) async throws {
        try await onQueue {
            let signpost = Log.signposter.beginInterval("CaptureStart")
            defer { Log.signposter.endInterval("CaptureStart", signpost) }
            let started = ContinuousClock.now

            try self.configureLocked(device: device)
            self.installTapLocked()
            guard let engine = self.engine else { throw AudioCaptureError.invalidFormat }

            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file: AVAudioFile
            do {
                file = try AVAudioFile(
                    forWriting: fileURL, settings: Self.wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw AudioCaptureError.fileCreation(error.localizedDescription)
            }

            self.fileURL = fileURL
            self.level.reset()
            self.hot.withLockUnchecked { state in
                state.file = file
                state.buffer = buffer
                state.samplesWritten = 0
                state.isPaused = false
                state.diedFired = false
                state.writeErrorLogged = false
                state.isActive = true
            }

            do {
                try engine.start()
            } catch {
                self.hot.withLockUnchecked { state in
                    state.isActive = false
                    state.file = nil
                    state.buffer = nil
                }
                try? FileManager.default.removeItem(at: fileURL)
                self.fileURL = nil
                // A failed start (format or route change without a configuration notification)
                // leaves the engine unusable: rebuild engine, tap and converter on the next start.
                self.teardownEngineLocked()
                throw AudioCaptureError.engineStart(error.localizedDescription)
            }
            let elapsed = ContinuousClock.now - started
            Log.audio.info("Capture started on device \(device) in \(elapsed.milliseconds) ms")
        }
    }

    func setPaused(_ paused: Bool) {
        hot.withLockUnchecked { $0.isPaused = paused }
        Log.audio.info("Capture \(paused ? "paused" : "resumed", privacy: .public)")
    }

    func stop() async throws -> TimeInterval {
        try await onQueue {
            self.stopLocked().duration
        }
    }

    func abort() async {
        _ = try? await onQueue {
            self.abortLocked()
        }
    }

    func abortSynchronously() {
        queue.sync {
            self.abortLocked()
        }
    }

    private func abortLocked() {
        let (_, url) = stopLocked()
        if let url {
            try? FileManager.default.removeItem(at: url)
            Log.audio.info("Capture aborted, deleted \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: Queue-only engine management

    /// Builds the engine for `device` unless it is already configured for it.
    private func configureLocked(device: AudioDeviceID) throws {
        if self.device == device, engine != nil, !engineStale { return }
        teardownEngineLocked()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            // Select the device BEFORE reading the format or installing the tap.
            try input.auAudioUnit.setDeviceID(device)
        } catch {
            throw AudioCaptureError.deviceSelection(error.localizedDescription)
        }
        let native = input.inputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }
        guard let pipeline = AudioConversionPipeline(native: native, target: Self.targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        hot.withLockUnchecked { $0.pipeline = pipeline }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        aliveListener = AudioObjectListener(object: device, selector: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, !AudioDevices.isAlive(device) else { return }
            self.handleDeviceDied(reason: "device is no longer alive")
        }

        self.engine = engine
        self.device = device
        self.engineStale = false
        Log.audio.info("Capture engine configured: device \(device), \(native.sampleRate, format: .fixed(precision: 0)) Hz, \(native.channelCount) ch")
    }

    private func installTapLocked() {
        guard let engine, !tapInstalled else { return }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: input.inputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
    }

    private func removeTapLocked() {
        guard let engine, tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Stop sequence: flag inactive, remove the tap, stop the engine, drop the file (header
    /// finalizes), reset the meter. Returns the recorded duration and the WAV location.
    private func stopLocked() -> (duration: TimeInterval, url: URL?) {
        let wasActive = hot.withLockUnchecked { state -> Bool in
            let active = state.isActive
            state.isActive = false
            return active
        }
        guard wasActive else {
            Log.audio.info("Capture stop requested while idle")
            return (0, nil)
        }

        let signpost = Log.signposter.beginInterval("CaptureStop")
        defer { Log.signposter.endInterval("CaptureStop", signpost) }
        let started = ContinuousClock.now

        removeTapLocked()
        engine?.stop()

        let samples = finalizeFileLocked()
        level.reset()
        let url = fileURL
        fileURL = nil
        if engineStale {
            teardownEngineLocked()
        }

        let duration = Double(samples) / Double(SampleBuffer.sampleRate)
        let elapsed = ContinuousClock.now - started
        Log.audio.info("Capture stopped: \(duration, format: .fixed(precision: 2)) s, stop took \(elapsed.milliseconds) ms")
        return (duration, url)
    }

    /// Releases the `AVAudioFile` so the WAV header is written. Any in-flight tap write
    /// finished before we took the lock, so nothing touches the file afterwards.
    private func finalizeFileLocked() -> Int {
        let (file, samples) = hot.withLockUnchecked { state -> (AVAudioFile?, Int) in
            defer {
                state.file = nil
                state.buffer = nil
            }
            return (state.file, state.samplesWritten)
        }
        if let file {
            if #available(macOS 15.0, *) {
                file.close()
            }
        }
        return samples
    }

    private func teardownEngineLocked() {
        removeTapLocked()
        engine?.stop()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        aliveListener = nil
        engine = nil
        device = nil
        engineStale = false
        hot.withLockUnchecked { $0.pipeline = nil }
    }

    // MARK: Tap thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        hot.withLockUnchecked { state in
            guard state.isActive, let pipeline = state.pipeline else { return }
            guard let converted = pipeline.convert(buffer) else { return }
            let frames = Int(converted.frameLength)
            guard frames > 0, let channel = converted.floatChannelData?[0] else { return }

            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))
            level.store(rmsDB: 20 * log10(max(rms, 1e-6)))

            guard !state.isPaused else { return }
            state.buffer?.append(UnsafeBufferPointer(start: channel, count: frames))
            if let file = state.file {
                do {
                    try file.write(from: converted)
                } catch {
                    if !state.writeErrorLogged {
                        state.writeErrorLogged = true
                        Log.audio.error("WAV write failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            state.samplesWritten += frames
        }
    }

    // MARK: Device loss

    private func handleConfigurationChange() {
        Log.audio.warning("AVAudioEngineConfigurationChange received")
        queue.async { [weak self] in
            guard let self else { return }
            let active = self.hot.withLockUnchecked { $0.isActive }
            guard active else {
                // Prepared but idle: rebuild on the next prepare/start.
                self.teardownEngineLocked()
                return
            }
            let deviceAlive = self.device.map(AudioDevices.isAlive) ?? false
            if deviceAlive, self.engine?.isRunning == true {
                // Another device came or went; ours still records. Rebuild after this take.
                Log.audio.info("Configuration change ignored: capture device alive and engine running")
                self.engineStale = true
                return
            }
            self.engineStale = true
            self.handleDeviceDied(reason: "engine configuration changed")
        }
    }

    private func handleDeviceDied(reason: String) {
        let fire = hot.withLockUnchecked { state -> Bool in
            guard state.isActive, !state.diedFired else { return false }
            state.diedFired = true
            return true
        }
        guard fire else { return }
        Log.audio.error("Capture device died: \(reason, privacy: .public)")
        onDeviceDied?()
    }

    // MARK: Queue bridge

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Conversion pipeline

/// Native tap format -> 16 kHz mono Float32 through one persistent `AVAudioConverter`
/// (gotchas 25, 26, 29). Multi-channel input is reduced to the louder channel per buffer
/// before conversion; averaging would make a mono mic on channel 1 of 2 six dB quieter.
/// Used only under `AudioCapture`'s hot lock.
final class AudioConversionPipeline {
    /// Hands the current buffer to the converter exactly once per `convert` call.
    private final class InputHandoff: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var consumed = false
    }

    let nativeFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let ratio: Double
    private let mixdown: Bool
    private var mono: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer
    private let handoff = InputHandoff()
    private var errorLogged = false

    init?(native: AVAudioFormat, target: AVAudioFormat) {
        nativeFormat = native
        targetFormat = target
        mixdown = native.channelCount > 1 && native.commonFormat == .pcmFormatFloat32 && !native.isInterleaved
        let inputFormat: AVAudioFormat
        if mixdown {
            guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: native.sampleRate, channels: 1) else { return nil }
            inputFormat = monoFormat
        } else {
            inputFormat = native
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        self.converter = converter
        ratio = target.sampleRate / native.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(AudioCapture.tapBufferSize * 4) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        self.output = output
        if mixdown {
            mono = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AudioCapture.tapBufferSize * 4)
        }
    }

    /// Returns the reusable output buffer with `frameLength` set, or nil on a converter error.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = mixdown ? louderChannel(of: input) : input
        guard let source else { return nil }

        let needed = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        if output.frameCapacity < needed {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: needed) else { return nil }
            output = bigger
        }
        output.frameLength = 0

        handoff.buffer = source
        handoff.consumed = false
        let handoff = self.handoff
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if handoff.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            handoff.consumed = true
            outStatus.pointee = .haveData
            return handoff.buffer
        }
        handoff.buffer = nil
        if status == .error {
            if !errorLogged {
                errorLogged = true
                Log.audio.error("AVAudioConverter failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            return nil
        }
        return output
    }

    /// Copies the channel with the highest RMS into the mono scratch buffer.
    private func louderChannel(of input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let channels = input.floatChannelData else { return nil }
        let frames = input.frameLength
        guard frames > 0 else { return nil }
        if let existing = mono, existing.frameCapacity >= frames {
            // Reuse the scratch buffer.
        } else {
            mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frames)
        }
        guard let mono, let destination = mono.floatChannelData?[0] else { return nil }

        var best = 0
        var bestRMS: Float = -1
        for channel in 0..<Int(input.format.channelCount) {
            var rms: Float = 0
            vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(frames))
            if rms > bestRMS {
                bestRMS = rms
                best = channel
            }
        }
        destination.update(from: channels[best], count: Int(frames))
        mono.frameLength = frames
        return mono
    }
}

private extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
