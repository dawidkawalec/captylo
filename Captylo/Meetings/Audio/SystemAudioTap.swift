@preconcurrency import AVFoundation
import CoreAudio
import os

/// "Rozmówcy": everything the Mac plays except Captylo, through a Core Audio process tap
/// (macOS 14.2+ APIs; the app floor is 14.4). Only the "System Audio Recording Only" grant,
/// no Screen Recording. The first `AudioDeviceStart` shows the system prompt; a denied grant
/// is silent (exact zeros, `noErr` everywhere), which `SilenceWatchdog` catches.
///
/// The IOProc runs on the real-time thread and only copies the tap's bytes out; conversion to
/// 16 kHz mono, batching and delivery happen on `queue` in `Stream`. `stop()` never waits on
/// `queue`, so it is safe from any thread, `onSamples` included.
///
/// The tap's format follows the output device and can change mid-meeting (a Bluetooth headset
/// entering call mode, another default output). Property listeners on the tap format and the
/// aggregate's rate re-read it on `queue`, in order with the buffers, and `Stream` switches.
final class SystemAudioTap: MeetingAudioSource, @unchecked Sendable {
    /// Samples leave `queue` in batches of at least 0.1 s. The IOProc fires every few
    /// milliseconds and every delivery costs a file write, a stream yield and a watchdog check.
    static let minimumDelivery = 1_600

    private struct Handles {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var stream: Stream?
        var formatListener: AudioObjectPropertyListenerBlock?
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: Handles())
    private let levelLock = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let queue = DispatchQueue(label: "com.captylo.app.meeting.tap", qos: .userInitiated)

    var level: Float { levelLock.withLock { $0 } }

    deinit {
        stop()
    }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        stop()

        let exclude = CoreAudioProcesses.ownObjectID().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID))

        var asbd = AudioStreamBasicDescription()
        let formatStatus = Self.readFormat(of: tapID, into: &asbd)
        guard formatStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw MeetingAudioError.tap(formatStatus)
        }
        guard asbd.mBytesPerFrame > 0,
              let tapFormat = AVAudioFormat(streamDescription: &asbd),
              let stream = Stream(format: tapFormat, level: levelLock, onSamples: onSamples) else {
            Log.audio.error("System audio tap format not supported: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags)")
            AudioHardwareDestroyProcessTap(tapID)
            throw MeetingAudioError.format
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Captylo Meeting",
            kAudioAggregateDeviceUIDKey: "com.captylo.app.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw MeetingAudioError.tap(aggregateStatus)
        }

        let queue = self.queue
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, _, _ in
            // Real-time thread: copy the bytes out and leave.
            let chunks = Stream.copy(input)
            guard !chunks.isEmpty else { return }
            queue.async { stream.receive(chunks) }
        }
        guard status == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw MeetingAudioError.tap(status)
        }

        // Re-read the format on `queue`, between the buffers, so every buffer is converted at
        // the rate it was recorded at (apart from the few the HAL delivers before it notifies).
        let refreshFormat: @Sendable () -> Void = { [tapID] in
            var current = AudioStreamBasicDescription()
            guard Self.readFormat(of: tapID, into: &current) == noErr,
                  let format = AVAudioFormat(streamDescription: &current) else { return }
            stream.adopt(format)
        }
        // The HAL calls this on its own notification thread; it only hops to `queue`, so
        // removing it in `stop()` never waits on `queue`.
        let formatListener: AudioObjectPropertyListenerBlock = { _, _ in
            queue.async(execute: refreshFormat)
        }
        for (object, address) in Self.formatWatch(tapID: tapID, aggregateID: aggregateID) {
            var address = address
            let listenStatus = AudioObjectAddPropertyListenerBlock(object, &address, nil, formatListener)
            if listenStatus != noErr {
                Log.audio.error("System audio tap: cannot watch format changes (\(listenStatus))")
            }
        }

        lock.withLockUnchecked {
            $0 = Handles(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID, stream: stream, formatListener: formatListener)
        }
        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        if startStatus != noErr {
            stop()
            throw MeetingAudioError.tap(startStatus)
        }
        // A change between the first read and the listeners going in would otherwise go unseen.
        queue.async(execute: refreshFormat)
        Log.audio.info("System audio tap started: \(asbd.mSampleRate, format: .fixed(precision: 0)) Hz, \(asbd.mChannelsPerFrame) ch")
    }

    func stop() {
        let handles = lock.withLockUnchecked { current -> Handles in
            let old = current
            current = Handles()
            return old
        }
        if let listener = handles.formatListener {
            for (object, address) in Self.formatWatch(tapID: handles.tapID, aggregateID: handles.aggregateID) {
                var address = address
                AudioObjectRemovePropertyListenerBlock(object, &address, nil, listener)
            }
        }
        if let proc = handles.ioProcID {
            AudioDeviceStop(handles.aggregateID, proc)
            AudioDeviceDestroyIOProcID(handles.aggregateID, proc)
        }
        if handles.aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(handles.aggregateID) }
        if handles.tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(handles.tapID) }
        if let stream = handles.stream {
            // After the buffers already queued: deliver the last partial batch, then go quiet.
            queue.async { stream.finish() }
            Log.audio.info("System audio tap stopped")
        }
        levelLock.withLock { $0 = 0 }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MeetingAudioError.tap(status) }
    }

    /// The tap's current format: what any aggregate device containing it delivers.
    private static func readFormat(of tapID: AudioObjectID, into asbd: inout AudioStreamBasicDescription) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
    }

    /// Properties whose change can mean the tap now delivers another format. Either one only
    /// triggers a fresh read of the tap format; an unchanged format is ignored.
    private static func formatWatch(tapID: AudioObjectID, aggregateID: AudioObjectID) -> [(AudioObjectID, AudioObjectPropertyAddress)] {
        [
            (tapID, AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)),
            (aggregateID, AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)),
        ]
    }
}

extension SystemAudioTap {
    /// One tap session's conversion state. Confined to the tap's serial queue (tests call it
    /// from one thread), so the non-Sendable converter is never shared across threads.
    final class Stream: @unchecked Sendable {
        /// The tap's current format. The converter is nil while the tap reports a format we
        /// cannot rebuild or convert: its buffers are dropped rather than converted at a wrong rate.
        private var format: AVAudioFormat
        private var pipeline: AudioConversionPipeline?
        private let level: OSAllocatedUnfairLock<Float>
        private let onSamples: @Sendable ([Float]) -> Void
        private var pending: [Float] = []
        private var finished = false

        init?(format: AVAudioFormat, level: OSAllocatedUnfairLock<Float>, onSamples: @escaping @Sendable ([Float]) -> Void) {
            guard let pipeline = Self.pipeline(for: format) else { return nil }
            self.format = format
            self.pipeline = pipeline
            self.level = level
            self.onSamples = onSamples
            pending.reserveCapacity(SystemAudioTap.minimumDelivery * 2)
        }

        private static func pipeline(for format: AVAudioFormat) -> AudioConversionPipeline? {
            guard format.streamDescription.pointee.mBytesPerFrame > 0 else { return nil }
            return AudioConversionPipeline(native: format, target: AudioCapture.targetFormat)
        }

        /// Switches to the tap's new format mid-session. The tap follows the output device, whose
        /// rate can change while a meeting records (a Bluetooth headset entering call mode drops
        /// it to 16 or 24 kHz, the default output changes); buffers at the new rate converted with
        /// the old ratio would play the rest of the track too fast or too slow. What was converted
        /// at the old rate is delivered first, so the switch is a clean cut. Returns whether the
        /// stream now converts `newFormat`; a repeat of the current format changes nothing.
        @discardableResult
        func adopt(_ newFormat: AVAudioFormat) -> Bool {
            guard !finished else { return false }
            if newFormat == format { return pipeline != nil }
            if !pending.isEmpty {
                deliver()
            }
            let oldRate = format.sampleRate
            format = newFormat
            pipeline = Self.pipeline(for: newFormat)
            let description = newFormat.streamDescription.pointee
            if pipeline != nil {
                Log.audio.info("System audio tap format changed: \(oldRate, format: .fixed(precision: 0)) -> \(description.mSampleRate, format: .fixed(precision: 0)) Hz, \(description.mChannelsPerFrame) ch")
                return true
            }
            Log.audio.error("System audio tap format not supported, dropping its audio until it changes: \(description.mSampleRate) Hz, \(description.mChannelsPerFrame) ch, flags \(description.mFormatFlags)")
            return false
        }

        /// Copies every buffer of an IOProc input list (one per channel when planar), keeping
        /// their order. Safe on the real-time thread: no locks and no Objective-C, one small
        /// allocation per buffer. Empty when the list carries no audio.
        static func copy(_ list: UnsafePointer<AudioBufferList>) -> [Data] {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, first.mData != nil, first.mDataByteSize > 0 else { return [] }
            return buffers.map { buffer in
                guard let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
                return Data(bytes: bytes, count: Int(buffer.mDataByteSize))
            }
        }

        /// Rebuilds the tap buffer, converts it to 16 kHz mono and delivers once a batch is full.
        func receive(_ chunks: [Data]) {
            guard !finished, let pipeline, let first = chunks.first else { return }
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let frames = first.count / bytesPerFrame
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let targets = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (index, chunk) in chunks.enumerated() where index < targets.count {
                guard let destination = targets[index].mData else { continue }
                let count = min(chunk.count, Int(targets[index].mDataByteSize))
                chunk.withUnsafeBytes { source in
                    guard let base = source.baseAddress else { return }
                    destination.copyMemory(from: base, byteCount: count)
                }
            }
            guard let converted = pipeline.convert(buffer), converted.frameLength > 0,
                  let channel = converted.floatChannelData?[0] else { return }
            pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            if pending.count >= SystemAudioTap.minimumDelivery {
                deliver()
            }
        }

        /// Delivers what is left and ignores anything that still arrives.
        func finish() {
            guard !finished else { return }
            finished = true
            if !pending.isEmpty {
                deliver()
            }
            level.withLock { $0 = 0 }
        }

        private func deliver() {
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            level.withLock { $0 = AudioLevel.rms(batch) }
            onSamples(batch)
        }
    }
}
