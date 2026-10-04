import AVFoundation
import Testing
@testable import Captylo

struct AudioConversionPipelineTests {
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    /// Streams `seconds` of audio in 2048-frame chunks and returns every converted sample.
    private func stream(
        native: AVAudioFormat, seconds: Double, fill: (Int, Int) -> Float
    ) throws -> [Float] {
        let pipeline = try #require(AudioConversionPipeline(native: native, target: AudioCapture.targetFormat))
        let chunk = AVAudioFrameCount(AudioCapture.tapBufferSize)
        let total = Int(seconds * native.sampleRate)
        var produced: [Float] = []
        var offset = 0
        while offset < total {
            let frames = min(Int(chunk), total - offset)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: native, frameCapacity: chunk))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<Int(native.channelCount) {
                for frame in 0..<frames {
                    channels[channel][frame] = fill(channel, offset + frame)
                }
            }
            let out = try #require(pipeline.convert(buffer))
            let data = try #require(out.floatChannelData)
            produced.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            offset += frames
        }
        return produced
    }

    @Test func resamplesStereo48kToMono16kPickingTheLouderChannel() throws {
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let amplitude: Float = 0.5
        let samples = try stream(native: native, seconds: 1) { channel, index in
            // Channel 0 silent, channel 1 carries the tone: averaging would halve it.
            channel == 1 ? amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) : 0
        }

        // 1 s at 16 kHz, allowing for converter priming latency.
        #expect(samples.count > 15_000 && samples.count <= 16_100)
        let expectedRMS = amplitude * Float(1 / 2.0.squareRoot())
        #expect(abs(rms(samples) - expectedRMS) < 0.03)
    }

    @Test func monoInputPassesThroughWithoutDuplication() throws {
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        // A slow ramp: duplicated or dropped buffers would break monotonicity.
        let samples = try stream(native: native, seconds: 0.5) { _, index in Float(index) / 44_100 }

        #expect(samples.count > 7_500 && samples.count <= 8_100)
        let tail = samples.suffix(from: 200)
        var previous = samples[199]
        var monotonic = true
        for sample in tail {
            if sample < previous - 0.001 { monotonic = false; break }
            previous = sample
        }
        #expect(monotonic)
        #expect(abs(samples.last! - 0.5) < 0.02)
    }

    @Test func sameRateMonoIsIdentity() throws {
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let samples = try stream(native: native, seconds: 0.25) { _, index in index % 2 == 0 ? 0.25 : -0.25 }
        #expect(samples.count == 4_000)
        #expect(samples[0] == 0.25)
        #expect(samples[1] == -0.25)
    }
}
