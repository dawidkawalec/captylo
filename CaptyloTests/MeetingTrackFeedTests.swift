import Foundation
import Testing
@testable import Captylo

/// Buffers of 1600 samples (0.1 s); times are made-up clock seconds, the meeting starts at 100.
struct MeetingTrackFeedTests {
    private let buffer = [Float](repeating: 0.1, count: 1_600)

    private func makeFeed(startedAt: Double = 100) throws -> (MeetingTrackFeed, TrackFileWriter) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "meeting-feed-\(UUID().uuidString)")
            .appending(path: MeetingTrack.them.fileName)
        let writer = try TrackFileWriter(url: url)
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: nil, engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: nil) },
            save: { _ in }
        )
        return (MeetingTrackFeed(track: .them, writer: writer, transcriber: transcriber, startedAt: startedAt), writer)
    }

    @Test func aTrackThatStartsLateIsPaddedToTheMeetingStart() throws {
        let (feed, writer) = try makeFeed()
        // Recorded from 100.5 to 100.6: half a second after the meeting started.
        feed.deliver(buffer, session: 0, at: 100.6)
        #expect(writer.sampleCount == 8_000 + 1_600)
    }

    @Test func aTrackThatStartsWithTheMeetingGetsNothingExtra() throws {
        let (feed, writer) = try makeFeed()
        feed.deliver(buffer, session: 0, at: 100.05)
        #expect(writer.sampleCount == 1_600)
    }

    @Test func jitterBetweenBuffersNeverAddsSilence() throws {
        let (feed, writer) = try makeFeed()
        feed.deliver(buffer, session: 0, at: 100.1)
        feed.deliver(buffer, session: 0, at: 100.35)
        feed.deliver(buffer, session: 0, at: 100.4)
        #expect(writer.sampleCount == 3 * 1_600)
    }

    @Test func aRebuiltSourceFillsTheHoleSinceTheLastAudio() throws {
        let (feed, writer) = try makeFeed()
        feed.deliver(buffer, session: 0, at: 100.1)
        // The new tap's first buffer was recorded from 100.5: 0.4 s were never captured.
        feed.deliver(buffer, session: 1, at: 100.6)
        #expect(writer.sampleCount == 1_600 + 6_400 + 1_600)
        feed.deliver(buffer, session: 1, at: 100.9)
        #expect(writer.sampleCount == 1_600 + 6_400 + 1_600 + 1_600)
    }

    @Test func nothingIsWrittenAfterClose() throws {
        let (feed, writer) = try makeFeed()
        feed.deliver(buffer, session: 0, at: 100.1)
        feed.close()
        feed.deliver(buffer, session: 0, at: 100.2)
        #expect(writer.sampleCount == 1_600)
    }

    @Test func aTrackWithoutAFileStillFeedsTheTranscriber() async throws {
        let sink = SegmentSink()
        let transcriber = MeetingTranscriber(
            meetingID: UUID(), language: nil, engine: CountingMeetingTranscriber(),
            detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
            save: { await sink.save($0) },
            config: .init(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 1_000_000)
        )
        let feed = MeetingTrackFeed(track: .me, writer: nil, transcriber: transcriber, startedAt: 100)
        await transcriber.start()
        feed.deliver([Float](repeating: 0.2, count: 4_096 * 5), session: 0, at: 101.3)
        _ = await transcriber.finish()
        let saved = await sink.saved
        #expect(saved.map(\.track) == [.me])
    }
}
