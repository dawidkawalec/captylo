import AVFoundation
import CoreMedia
import Foundation

enum AudioDecoderError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case noAudioTrack
    case cannotRead(String)
    case emptyAudio
    case cannotWrite(String)
    case unsupportedBySystem

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return String(localized: "Nieobsługiwany format pliku (.\(ext)).")
        case .unsupportedBySystem:
            return String(localized: "Ten format nie jest obsługiwany przez macOS na tym komputerze.")
        case .noAudioTrack:
            return String(localized: "Plik nie zawiera ścieżki audio.")
        case .cannotRead(let reason):
            return String(localized: "Nie udało się odczytać pliku audio: \(reason)")
        case .emptyAudio:
            return String(localized: "Plik audio jest pusty.")
        case .cannotWrite(let reason):
            return String(localized: "Nie udało się zapisać pliku WAV: \(reason)")
        }
    }
}

/// File decoding to 16 kHz mono Float32 (gotcha 86) and 16 kHz Int16 WAV writing.
/// `AVAssetReader` comes first: it handles mp4/mov and the m4a files on which `AVAudioFile`
/// fails with -50. `AVAudioFile` decodes Ogg/Opus voice notes, which `AVURLAsset` cannot open,
/// and is the fallback when `AVAssetReader` fails (e.g. a file saved without a name extension).
enum AudioDecoder {
    static let sampleRate = 16_000

    static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aiff", "aif", "aac", "flac", "caf", "mp4", "mov", "ogg", "opus", "oga",
    ]

    /// Ogg containers (messenger voice notes): only Core Audio reads them, through `AVAudioFile`.
    static let oggExtensions: Set<String> = ["ogg", "opus", "oga"]

    /// Serial queue for the blocking decode loops (never on the cooperative pool).
    private static let queue = DispatchQueue(label: "com.captylo.app.audio.decoder", qos: .userInitiated)

    static func isSupported(_ url: URL) -> Bool {
        formatExtension(of: url) != nil
    }

    /// The extension that names the file's format: its own when we know it, otherwise the one its
    /// first bytes point to (voice notes downloaded without a name extension). Nil when neither fits.
    static func formatExtension(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return ext }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12) else { return nil }
        return sniffedExtension(head)
    }

    /// Recognises a supported audio file by its signature in the first 12 bytes.
    static func sniffedExtension(_ head: Data) -> String? {
        let bytes = [UInt8](head.prefix(12))
        func ascii(_ range: Range<Int>) -> String? {
            guard bytes.count >= range.upperBound else { return nil }
            return String(bytes: bytes[range], encoding: .ascii)
        }
        switch ascii(0..<4) {
        case "OggS": return "ogg"
        case "fLaC": return "flac"
        case "caff": return "caf"
        case "RIFF" where ascii(8..<12) == "WAVE": return "wav"
        case "FORM" where ascii(8..<12) == "AIFF" || ascii(8..<12) == "AIFC": return "aiff"
        default: break
        }
        if ascii(4..<8) == "ftyp" { return "m4a" }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF {
            if bytes[1] & 0xF6 == 0xF0 { return "aac" }   // ADTS: sync word, layer 00
            if bytes[1] & 0xE0 == 0xE0 { return "mp3" }   // MPEG audio frame sync
        }
        return nil
    }

    /// Decodes any supported file to 16 kHz mono Float32 samples in [-1, 1].
    static func decode16kMono(_ url: URL) async throws -> (samples: [Float], duration: TimeInterval) {
        guard let format = formatExtension(of: url) else {
            throw AudioDecoderError.unsupportedFormat(url.pathExtension.lowercased())
        }

        let signpost = Log.signposter.beginInterval("DecodeFile")
        defer { Log.signposter.endInterval("DecodeFile", signpost) }

        let samples: [Float]
        if oggExtensions.contains(format) {
            do {
                samples = try await onQueue { try readWithAudioFile(url) }
            } catch {
                Log.audio.error("Ogg decode failed: \(error.localizedDescription, privacy: .public)")
                throw AudioDecoderError.unsupportedBySystem
            }
        } else {
            do {
                samples = try await readWithAssetReader(url)
            } catch {
                // Keep the reader's error (no audio track, unreadable) when the fallback fails too.
                guard let fallback = try? await onQueue({ try readWithAudioFile(url) }) else { throw error }
                Log.audio.notice("AVAssetReader failed, decoded with AVAudioFile instead")
                samples = fallback
            }
        }
        guard !samples.isEmpty else { throw AudioDecoderError.emptyAudio }
        let duration = Double(samples.count) / Double(sampleRate)
        Log.audio.info("Decoded \(url.lastPathComponent, privacy: .public): \(samples.count) samples, \(duration, format: .fixed(precision: 2)) s")
        return (samples, duration)
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readWithAssetReader(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioDecoderError.cannotRead(error.localizedDescription)
        }
        guard let track = tracks.first else { throw AudioDecoderError.noAudioTrack }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try readSamples(asset: asset, track: track))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking `AVAudioFile` read, converted chunk by chunk to 16 kHz mono; runs on `queue`.
    private static func readWithAudioFile(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecoderError.cannotRead(error.localizedDescription)
        }
        let source = file.processingFormat
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw AudioDecoderError.cannotRead("AVAudioConverter") }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 32_768
        let ratio = Double(sampleRate) / source.sampleRate
        guard
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
            let output = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: AVAudioFrameCount((Double(chunk) * ratio).rounded(.up)) + 1024)
        else { throw AudioDecoderError.cannotRead("AVAudioPCMBuffer") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(max(file.length, 0)) * ratio) + 1024)
        var readError: Error?
        var finished = false
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if !finished, file.framePosition < file.length {
                    do {
                        try file.read(into: input, frameCount: chunk)
                    } catch {
                        readError = error
                    }
                    if readError == nil, input.frameLength > 0 {
                        outStatus.pointee = .haveData
                        return input
                    }
                }
                finished = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if let readError { throw AudioDecoderError.cannotRead(readError.localizedDescription) }
            if let conversionError { throw AudioDecoderError.cannotRead(conversionError.localizedDescription) }
            guard status != .error else { throw AudioDecoderError.cannotRead("AVAudioConverter") }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return sanitized(samples)
    }

    /// Blocking reader loop; runs on `queue`.
    private static func readSamples(asset: AVURLAsset, track: AVAssetTrack) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecoderError.cannotRead(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecoderError.cannotRead("AVAssetReaderTrackOutput") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecoderError.cannotRead(reader.error?.localizedDescription ?? "startReading")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var pointer: UnsafeMutablePointer<CChar>?
            var contiguous = 0
            let status = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil, dataPointerOut: &pointer)
            if status == kCMBlockBufferNoErr, let pointer, contiguous == length {
                let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / MemoryLayout<Float>.size))
            } else {
                var bytes = [UInt8](repeating: 0, count: length)
                let copied = bytes.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                guard copied == kCMBlockBufferNoErr else { continue }
                bytes.withUnsafeBytes { raw in
                    samples.append(contentsOf: raw.bindMemory(to: Float.self))
                }
            }
        }

        if reader.status == .failed {
            throw AudioDecoderError.cannotRead(reader.error?.localizedDescription ?? "AVAssetReader")
        }
        return sanitized(samples)
    }

    /// Float files (WAV, CAF, AIFF-C) pass NaN and infinity through unchanged; they become silence
    /// here so neither the engines nor the Int16 conversion ever see them.
    static func sanitized(_ samples: [Float]) -> [Float] {
        guard samples.contains(where: { !$0.isFinite }) else { return samples }
        var clean = samples
        for index in clean.indices where !clean[index].isFinite {
            clean[index] = 0
        }
        Log.audio.notice("Decoded audio contained non-finite samples; replaced them with silence")
        return clean
    }

    // MARK: WAV output

    /// Writes 16 kHz mono Int16 PCM WAV (file-transcription uploads).
    static func writeWAV16k(_ samples: [Float], to url: URL) throws {
        do {
            try wavData16k(samples).write(to: url, options: .atomic)
        } catch {
            throw AudioDecoderError.cannotWrite(error.localizedDescription)
        }
    }

    /// In-memory 16 kHz mono Int16 PCM WAV with the canonical 44-byte header.
    static func wavData16k(_ samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))

        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            // `min`/`max` keep NaN, and `Int16(NaN)` traps: non-finite samples become silence.
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            pcm[index] = Int16((clamped * 32767).rounded())
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
