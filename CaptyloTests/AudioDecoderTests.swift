import Foundation
import Testing
@testable import Captylo

struct AudioDecoderTests {
    private func sine(seconds: Double = 1, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * Double(AudioDecoder.sampleRate))
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / Double(AudioDecoder.sampleRate)))
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "captylo-tests-\(UUID().uuidString)-\(name)")
    }

    @Test func wavHeaderFieldsAreCanonical() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = AudioDecoder.wavData16k(samples)

        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(data.readUInt32(at: 4) == UInt32(36 + samples.count * 2))
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(data.readUInt32(at: 16) == 16)
        #expect(data.readUInt16(at: 20) == 1)          // PCM
        #expect(data.readUInt16(at: 22) == 1)          // mono
        #expect(data.readUInt32(at: 24) == 16_000)     // sample rate
        #expect(data.readUInt32(at: 28) == 32_000)     // byte rate
        #expect(data.readUInt16(at: 32) == 2)          // block align
        #expect(data.readUInt16(at: 34) == 16)         // bits
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(data.readUInt32(at: 40) == UInt32(samples.count * 2))

        #expect(data.readInt16(at: 44) == 0)
        #expect(data.readInt16(at: 46) == 16_384)
        #expect(data.readInt16(at: 48) == -16_384)
        #expect(data.readInt16(at: 50) == 32_767)
        #expect(data.readInt16(at: 52) == -32_767)
    }

    @Test func wavClampsOutOfRangeSamples() {
        let data = AudioDecoder.wavData16k([2, -2])
        #expect(data.readInt16(at: 44) == 32_767)
        #expect(data.readInt16(at: 46) == -32_767)
    }

    @Test func nonFiniteSamplesBecomeSilenceInsteadOfTrapping() {
        let data = AudioDecoder.wavData16k([.nan, .infinity, -.infinity, 0.5])
        #expect(data.readInt16(at: 44) == 0)
        #expect(data.readInt16(at: 46) == 0)
        #expect(data.readInt16(at: 48) == 0)
        #expect(data.readInt16(at: 50) == 16_384)

        let clean = AudioDecoder.sanitized([0.25, .nan, -.infinity, -0.5])
        #expect(clean == [0.25, 0, 0, -0.5])
        #expect(AudioDecoder.sanitized([0.1, 0.2]) == [0.1, 0.2])
    }

    @Test func roundTripThroughAVAssetReader() async throws {
        let amplitude: Float = 0.5
        let original = sine(amplitude: amplitude)
        let url = temporaryURL("tone.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioDecoder.writeWAV16k(original, to: url)

        let decoded = try await AudioDecoder.decode16kMono(url)

        #expect(abs(decoded.samples.count - 16_000) <= 16)
        #expect(abs(decoded.duration - 1) < 0.002)
        let expectedRMS = amplitude * Float(1 / 2.0.squareRoot())
        #expect(abs(rms(decoded.samples) - expectedRMS) < 0.01)
        #expect(decoded.samples.max()! <= 1)
        #expect(decoded.samples.min()! >= -1)
    }

    @Test func rejectsUnsupportedExtension() async {
        let url = temporaryURL("notes.txt")
        await #expect(throws: AudioDecoderError.unsupportedFormat("txt")) {
            _ = try await AudioDecoder.decode16kMono(url)
        }
    }

    @Test func failsOnMissingFile() async {
        let url = temporaryURL("missing.wav")
        await #expect(throws: (any Error).self) {
            _ = try await AudioDecoder.decode16kMono(url)
        }
    }

    @Test func supportedExtensionsCoverTheBrief() {
        for ext in ["wav", "mp3", "m4a", "aiff", "aac", "flac", "caf", "mp4", "mov", "ogg", "opus", "oga"] {
            #expect(AudioDecoder.supportedExtensions.contains(ext))
        }
        #expect(AudioDecoder.isSupported(URL(fileURLWithPath: "/tmp/A.WAV")))
        #expect(AudioDecoder.isSupported(URL(fileURLWithPath: "/tmp/a.ogg")))
        #expect(!AudioDecoder.isSupported(URL(fileURLWithPath: "/tmp/missing-voice-note")))
    }

    @Test func sniffsFormatsFromTheirFirstBytes() {
        func head(_ text: String, padTo count: Int = 12) -> Data {
            var data = Data(text.utf8)
            data.append(contentsOf: [UInt8](repeating: 0, count: max(0, count - data.count)))
            return data
        }
        #expect(AudioDecoder.sniffedExtension(head("OggS")) == "ogg")
        #expect(AudioDecoder.sniffedExtension(head("RIFF\0\0\0\0WAVE")) == "wav")
        #expect(AudioDecoder.sniffedExtension(head("RIFF\0\0\0\0AVI ")) == nil)
        #expect(AudioDecoder.sniffedExtension(head("FORM\0\0\0\0AIFC")) == "aiff")
        #expect(AudioDecoder.sniffedExtension(head("\0\0\0\u{20}ftypM4A ")) == "m4a")
        #expect(AudioDecoder.sniffedExtension(head("fLaC")) == "flac")
        #expect(AudioDecoder.sniffedExtension(head("caff")) == "caf")
        #expect(AudioDecoder.sniffedExtension(head("ID3\u{4}")) == "mp3")
        #expect(AudioDecoder.sniffedExtension(Data([0xFF, 0xFB, 0x90, 0x00])) == "mp3")
        #expect(AudioDecoder.sniffedExtension(Data([0xFF, 0xF1, 0x50, 0x80])) == "aac")
        #expect(AudioDecoder.sniffedExtension(head("%PDF-1.7")) == nil)
        #expect(AudioDecoder.sniffedExtension(Data()) == nil)
    }

    @Test func decodesAWAVSavedWithoutAnExtension() async throws {
        let original = sine()
        let url = temporaryURL("tone")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioDecoder.writeWAV16k(original, to: url)

        #expect(AudioDecoder.isSupported(url))
        let decoded = try await AudioDecoder.decode16kMono(url)
        #expect(abs(decoded.samples.count - 16_000) <= 16)
    }

    /// A synthetic 1 s, 440 Hz Opus tone (generated with ffmpeg, no recorded voice), decoded the
    /// way a messenger voice note arrives: as `.ogg` and with no name extension at all.
    @Test(arguments: ["voice.ogg", "voice"])
    func decodesOggOpusVoiceNotes(name: String) async throws {
        let fixture = try #require(
            Bundle(for: FixtureToken.self).url(forResource: "tone-opus", withExtension: "ogg"), "missing tone-opus.ogg")
        let url = temporaryURL(name)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: fixture, to: url)

        #expect(AudioDecoder.isSupported(url))
        let decoded: (samples: [Float], duration: TimeInterval)
        do {
            decoded = try await AudioDecoder.decode16kMono(url)
        } catch AudioDecoderError.unsupportedBySystem {
            // Ogg in Core Audio depends on the macOS version; the error itself is the expected outcome there.
            return
        }
        #expect(abs(decoded.duration - 1) < 0.05)
        // ffmpeg's `sine` source has amplitude 1/8, halved when the fixture was made: 0.0625 / √2.
        #expect(abs(rms(decoded.samples) - 0.0442) < 0.01)
    }

    @Test func errorsHavePolishDescriptions() {
        #expect(AudioDecoderError.noAudioTrack.errorDescription?.isEmpty == false)
        #expect(AudioDecoderError.unsupportedFormat("ogg").errorDescription?.contains(".ogg") == true)
    }
}

private final class FixtureToken {}

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readInt16(at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(at: offset))
    }
}
