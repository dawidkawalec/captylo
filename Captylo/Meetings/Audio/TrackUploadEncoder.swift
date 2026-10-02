import AVFoundation

/// A meeting track for the cloud: the 16 kHz mono CAF re-encoded as AAC in an `.m4a` (about
/// 15 MB per hour instead of 115 MB of WAV), read and written in chunks so a 2 h track never sits
/// in memory as samples. When the AAC encoder is not available the track goes as WAV.
enum TrackUploadEncoder {
    struct Encoded: Sendable {
        let url: URL
        let mimeType: String
        let seconds: Double
    }

    /// Frames per read/write step (about 4 s).
    static let chunkFrames: AVAudioFrameCount = 65_536

    /// Encodes `source` into `folder` (created when missing). The caller removes the file.
    static func encode(_ source: URL, into folder: URL) throws -> Encoded {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString
        let m4a = folder.appending(path: name + ".m4a")
        do {
            let seconds = try convert(source, to: m4a, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: SampleBuffer.sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
            return Encoded(url: m4a, mimeType: "audio/mp4", seconds: seconds)
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            Log.audio.warning("AAC encoding of a meeting track failed, sending WAV: \(error.localizedDescription, privacy: .public)")
        }
        let wav = folder.appending(path: name + ".wav")
        let seconds = try convert(source, to: wav, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SampleBuffer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        return Encoded(url: wav, mimeType: "audio/wav", seconds: seconds)
    }

    /// Copies every frame of `source` into a new file with `settings`; returns its length in seconds.
    private static func convert(_ source: URL, to destination: URL, settings: [String: Any]) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadUnknown)
        }
        var frames: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        return format.sampleRate > 0 ? Double(frames) / format.sampleRate : 0
    }
}
