import AVFoundation

/// A meeting track for the cloud: the 16 kHz mono CAF re-encoded as AAC in an `.m4a` (about
/// 15 MB per hour instead of 115 MB of WAV), read and written in chunks so a 2 h track never sits
/// in memory as samples. When the AAC encoder is not available the track goes as WAV. With
/// `ranges` only those stretches go, `SpeechOnlyUpload.separator` of silence between them, and
/// `timeMap` puts the cloud's times back on the meeting's clock.
enum TrackUploadEncoder {
    struct Encoded: Sendable {
        let url: URL
        let mimeType: String
        /// The upload's length (what the cloud bills), not the track's.
        let seconds: Double
        /// Set when only stretches were sent.
        var timeMap: UploadTimeMap? = nil
    }

    /// Frames per read/write step (about 4 s).
    static let chunkFrames: AVAudioFrameCount = 65_536

    /// The track's length in seconds.
    static func duration(of source: URL) throws -> Double {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// Encodes `source` (or only its `ranges`, in meeting seconds) into `folder` (created when
    /// missing). The caller removes the file.
    static func encode(_ source: URL, into folder: URL, ranges: [ClosedRange<Double>]? = nil) throws -> Encoded {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString
        let m4a = folder.appending(path: name + ".m4a")
        let timeMap = ranges.map { UploadTimeMap(ranges: $0) }
        do {
            let seconds = try convert(source, to: m4a, ranges: ranges, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: SampleBuffer.sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
            return Encoded(url: m4a, mimeType: "audio/mp4", seconds: seconds, timeMap: timeMap)
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            Log.audio.warning("AAC encoding of a meeting track failed, sending WAV: \(error.localizedDescription, privacy: .public)")
        }
        let wav = folder.appending(path: name + ".wav")
        let seconds = try convert(source, to: wav, ranges: ranges, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SampleBuffer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        return Encoded(url: wav, mimeType: "audio/wav", seconds: seconds, timeMap: timeMap)
    }

    /// Copies the frames of `source` (all, or only `ranges` with silence between them) into a new
    /// file with `settings`; returns its length in seconds.
    private static func convert(_ source: URL, to destination: URL, ranges: [ClosedRange<Double>]?, settings: [String: Any]) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadUnknown)
        }
        let rate = format.sampleRate
        let spans: [(start: AVAudioFramePosition, end: AVAudioFramePosition)] = ranges.map { ranges in
            ranges.map { (AVAudioFramePosition(($0.lowerBound * rate).rounded()), min(input.length, AVAudioFramePosition(($0.upperBound * rate).rounded()))) }
        } ?? [(AVAudioFramePosition(0), input.length)]
        var frames: AVAudioFramePosition = 0
        for (index, span) in spans.enumerated() where span.end > span.start {
            if index > 0, ranges != nil {
                frames += try writeSilence(seconds: SpeechOnlyUpload.separator, format: format, to: output)
            }
            input.framePosition = span.start
            while input.framePosition < span.end {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), span.end - input.framePosition))
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
        }
        return rate > 0 ? Double(frames) / rate : 0
    }

    /// Writes `seconds` of silence; returns the frames written.
    private static func writeSilence(seconds: Double, format: AVAudioFormat, to output: AVAudioFile) throws -> AVAudioFramePosition {
        let count = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        guard count > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return 0 }
        silence.frameLength = count
        // Zero bytes are silence in every PCM sample format.
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        try output.write(from: silence)
        return AVAudioFramePosition(count)
    }
}
