import AVFoundation
import Foundation

/// Reads a saved recording back into the 16 kHz mono Float32 samples the engines expect.
/// Our WAVs are already 16 kHz mono Int16, so the converter only runs for foreign files.
enum RecordingReader {
    static let sampleRate: Double = 16_000

    enum ReadError: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "Nie udało się odczytać nagrania.")
            case .empty: return String(localized: "Nagranie jest puste.")
            }
        }
    }

    /// Blocking file read; call it off the main actor.
    static func load(_ url: URL) throws -> CapturedAudio {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw ReadError.empty }
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw ReadError.unreadable
        }
        try file.read(into: source)

        let samples = try monoSamples(from: source)
        guard !samples.isEmpty else { throw ReadError.empty }
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
        return CapturedAudio(
            id: id,
            fileURL: url,
            samples: samples,
            duration: Double(samples.count) / sampleRate
        )
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let format = buffer.format
        if format.sampleRate == sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
        }
        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: target)
        else { throw ReadError.unreadable }

        let ratio = sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ReadError.unreadable
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, let channel = output.floatChannelData?[0] else { throw ReadError.unreadable }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
