import AVFoundation
import Foundation
import os
import Testing
@testable import Captylo

struct MeetingAudioSourceTests {
    // MARK: Level

    @Test func levelOfSilenceIsZeroAndLoudAudioIsClampedToOne() {
        #expect(AudioLevel.rms([]) == 0)
        #expect(AudioLevel.rms(Array(repeating: 0, count: 1_600)) == 0)
        #expect(AudioLevel.rms(Array(repeating: 0.9, count: 1_600)) == 1)
    }

    @Test func levelIsTheScaledRMS() {
        // RMS 0.1, scaled by 4 so normal speech fills the live bar.
        let samples = (0..<1_600).map { $0 % 2 == 0 ? Float(0.1) : Float(-0.1) }
        #expect(abs(AudioLevel.rms(samples) - 0.4) < 0.0001)
    }

    // MARK: Errors

    @Test func errorsDescribeWhatFailed() {
        let tap = MeetingAudioError.tap(-50).errorDescription ?? ""
        #expect(tap.contains("-50"))
        let engine = MeetingAudioError.engine("brak urządzenia").errorDescription ?? ""
        #expect(engine.contains("brak urządzenia"))
        #expect(!(MeetingAudioError.format.errorDescription ?? "").isEmpty)
    }

    // MARK: System tap stream (IOProc copy, conversion, batching)

    private final class Collected: Sendable {
        private let batches = OSAllocatedUnfairLock<[[Float]]>(initialState: [])
        var all: [[Float]] { batches.withLock { $0 } }
        func add(_ samples: [Float]) { batches.withLock { $0.append(samples) } }
    }

    /// Feeds `seconds` of audio in IOProc-sized buffers through the same copy the real-time
    /// block makes, then finishes the stream.
    private func run(
        format: AVAudioFormat, seconds: Double, framesPerCallback: Int = 512,
        fill: (Int, Int) -> Float
    ) throws -> (batches: [[Float]], level: Float) {
        let collected = Collected()
        let level = OSAllocatedUnfairLock<Float>(initialState: 0)
        let stream = try #require(SystemAudioTap.Stream(format: format, level: level) { collected.add($0) })
        let total = Int(seconds * format.sampleRate)
        var offset = 0
        var peakLevel: Float = 0
        while offset < total {
            let frames = min(framesPerCallback, total - offset)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<frames { channels[channel][frame] = fill(channel, offset + frame) }
            }
            stream.receive(SystemAudioTap.Stream.copy(buffer.audioBufferList))
            peakLevel = max(peakLevel, level.withLock { $0 })
            offset += frames
        }
        stream.finish()
        #expect(level.withLock { $0 } == 0)
        return (collected.all, peakLevel)
    }

    @Test func tapAudioArrivesAs16kMonoInBatchesOfATenthOfASecond() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let result = try run(format: format, seconds: 1) { _, index in
            0.5 * Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        let total = result.batches.reduce(0) { $0 + $1.count }
        #expect(total > 15_000 && total <= 16_100)
        // Every batch but the tail flushed by `finish` holds at least 0.1 s.
        #expect(result.batches.dropLast().allSatisfy { $0.count >= SystemAudioTap.minimumDelivery })
        #expect(result.batches.count >= 9 && result.batches.count <= 11)
        #expect(result.level > 0.5)
    }

    @Test func everyChannelOfAPlanarTapBufferIsCopied() throws {
        // Channel 0 silent, channel 1 carries the tone: a copy of only the first buffer would be silence.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let result = try run(format: format, seconds: 0.5) { channel, index in
            channel == 1 ? 0.5 * Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) : 0
        }
        let samples = result.batches.flatMap { $0 }
        #expect(samples.count > 7_500 && samples.count <= 8_100)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        #expect(abs(rms - 0.5 / Float(2.0.squareRoot())) < 0.03)
    }

    @Test func exactZerosStayExactZeros() throws {
        // The watchdog relies on a denied grant arriving as exact zeros after conversion.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let result = try run(format: format, seconds: 0.5) { _, _ in 0 }
        let samples = result.batches.flatMap { $0 }
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0 == 0 })
        #expect(result.level == 0)
    }

    @Test func nothingIsDeliveredAfterFinish() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let collected = Collected()
        let stream = try #require(SystemAudioTap.Stream(format: format, level: OSAllocatedUnfairLock(initialState: 0)) {
            collected.add($0)
        })
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        stream.receive(SystemAudioTap.Stream.copy(buffer.audioBufferList))
        #expect(collected.all.isEmpty)
        stream.finish()
        #expect(collected.all.map(\.count) == [800])
        stream.receive(SystemAudioTap.Stream.copy(buffer.audioBufferList))
        stream.finish()
        #expect(collected.all.map(\.count) == [800])
    }

    // MARK: Core Audio process list

    @Test func processListFindsThisProcessWhenCoreAudioKnowsIt() {
        // Our own object first: the first Core Audio call is what registers this process.
        let ownID = CoreAudioProcesses.ownObjectID()
        let processes = CoreAudioProcesses.all()
        #expect(processes.allSatisfy { $0.objectID != 0 })
        if let own = ownID {
            #expect(processes.contains { $0.objectID == own && $0.pid == ProcessInfo.processInfo.processIdentifier })
        }
        // Must not crash or hang; the answer depends on what the Mac plays right now.
        _ = CoreAudioProcesses.anyOtherProcessPlaying()
    }
}
