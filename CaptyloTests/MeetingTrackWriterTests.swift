import AVFoundation
import Foundation
import Testing
@testable import Captylo

struct MeetingTrackWriterTests {
    private func trackURL(_ name: String = "them.caf") -> URL {
        FileManager.default.temporaryDirectory.appending(path: "track-\(UUID().uuidString)/\(name)")
    }

    private func removeFolder(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    @Test func writesReadable16kMonoCAF() throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        writer.append((0..<16_000).map { Float(sin(Double($0) / 10)) * 0.5 })
        writer.append(Array(repeating: 0, count: 8_000))
        #expect(writer.sampleCount == 24_000)
        writer.close()
        writer.append([1, 2, 3])
        #expect(writer.sampleCount == 24_000)

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 24_000)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
    }

    @Test func samplesSurviveTheRoundTrip() throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let written = (0..<4_000).map { Float(sin(Double($0) / 7)) * 0.8 }
        let writer = try TrackFileWriter(url: url)
        writer.append(Array(written[..<1_000]))
        writer.append(Array(written[1_000...]))
        writer.close()

        let read = try readSamples(url)
        #expect(read.count == written.count)
        let worst = zip(read, written).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.001)
    }

    /// Review Focus 1: a crash mid-meeting must leave the audio written so far readable. A reader
    /// opened while the writer is still open sees what a crash would leave on disk.
    @Test func audioWrittenSoFarIsReadableBeforeClose() throws {
        let url = trackURL("me.caf")
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        writer.append(Array(repeating: 0.25, count: 16_000))
        writer.append(Array(repeating: -0.25, count: 16_000))

        let read = try readSamples(url)
        #expect(read.count == 32_000)
        #expect(abs((read.first ?? 0) - 0.25) < 0.001)
        #expect(abs((read.last ?? 0) + 0.25) < 0.001)
        writer.close()
    }

    @Test func concurrentAppendsAreAllKept() async throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for _ in 0..<10 {
                        writer.append(Array(repeating: Float(task) / 10, count: 1_600))
                    }
                }
            }
        }
        #expect(writer.sampleCount == 128_000)
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 128_000)
    }

    @Test func loudSamplesAreClippedInsteadOfWrappingAround() throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        writer.append([1.5, -1.5, 3, -3, .infinity, -.infinity, .nan, 0.5])
        writer.close()

        let read = try readSamples(url)
        #expect(read.count == 8)
        #expect(read[0] > 0.99)
        #expect(read[1] < -0.99)
        #expect(read[2] > 0.99)
        #expect(read[3] < -0.99)
        #expect(read[4] > 0.99)
        #expect(read[5] < -0.99)
        #expect(read[6] == 0)
        #expect(abs(read[7] - 0.5) < 0.001)
    }

    @Test func emptyAppendsAndASecondCloseAreHarmless() throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        writer.append([])
        #expect(writer.sampleCount == 0)
        writer.close()
        writer.close()
        #expect(try AVAudioFile(forReading: url).length == 0)
    }

    @Test func aMissingFolderIsCreatedAndAnUnwritablePathThrows() throws {
        let url = trackURL()
        defer { removeFolder(of: url) }
        let writer = try TrackFileWriter(url: url)
        writer.close()
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let blocker = url.deletingLastPathComponent().appending(path: "not-a-folder")
        try Data([1]).write(to: blocker)
        #expect(throws: (any Error).self) {
            _ = try TrackFileWriter(url: blocker.appending(path: "me.caf"))
        }
    }
}
