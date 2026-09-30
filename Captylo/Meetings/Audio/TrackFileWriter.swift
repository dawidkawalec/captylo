import AVFoundation
import os

/// Appends one meeting track to disk as it is recorded (16 kHz mono Int16 in CAF), so memory never
/// grows with the meeting and a crash keeps the audio written so far.
///
/// Thread safe: sources call `append` from their own serial queues and the recorder calls `close`
/// from the main actor. Every file access happens under one lock; `append` after `close` is a no-op.
final class TrackFileWriter: @unchecked Sendable {
    /// 16 kHz mono Int16; the file converts from the Float32 processing format.
    private static var fileSettings: [String: Any] {
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

    private struct State {
        var file: AVAudioFile?
        var count = 0
        var writeErrorLogged = false
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let format = AudioCapture.targetFormat

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(
            forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock = OSAllocatedUnfairLock(uncheckedState: State(file: file))
    }

    var sampleCount: Int { lock.withLockUnchecked { $0.count } }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        lock.withLockUnchecked { state in
            guard let file = state.file else { return }
            do {
                try file.write(from: buffer)
                state.count += samples.count
            } catch {
                guard !state.writeErrorLogged else { return }
                state.writeErrorLogged = true
                Log.audio.error("Meeting track write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finalizes the header. Any in-flight `append` finished before we took the lock, so nothing
    /// touches the file afterwards. `AVAudioFile.close()` is macOS 15+; on 14 releasing the file
    /// finalizes it.
    func close() {
        let file = lock.withLockUnchecked { state -> AVAudioFile? in
            defer { state.file = nil }
            return state.file
        }
        if let file, #available(macOS 15.0, *) {
            file.close()
        }
    }
}
