import Foundation
import Testing
@testable import Captylo

struct MeetingSpeakerLabelProcessorTests {
    private struct Fixture {
        let database: Database
        let meetingID: UUID
        let trackURL: URL
    }

    /// A meeting with "Ja" 0-2 s and two "Rozmówcy" segments (3-5 s, 6-8 s) and, unless
    /// `withTrackFile` is false, a stand-in `them` file (the fake diarizer never reads it).
    private static func fixture(withTrackFile: Bool = true, otherSide: Bool = true) async throws -> Fixture {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let meeting = MeetingRecord(title: "Spotkanie")
        try await database.createMeeting(meeting)
        var segments = [MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 2, text: "Dzień dobry")]
        if otherSide {
            segments.append(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 3, end: 5, text: "Cześć"))
            segments.append(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 6, end: 8, text: "Hej"))
        }
        for segment in segments {
            try await database.appendSegment(segment)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "speaker-labels-\(UUID().uuidString).caf")
        if withTrackFile {
            try Data([0]).write(to: url)
        }
        return Fixture(database: database, meetingID: meeting.id, trackURL: url)
    }

    private static let twoSpeakers = [
        SpeakerTurn(speaker: "S3", start: 2.8, end: 5.2),
        SpeakerTurn(speaker: "S1", start: 5.8, end: 8.4),
    ]

    private static func processor(
        _ fixture: Fixture, diarizer: ScriptedDiarizer, allowed: Bool = true, supported: Bool = true
    ) -> SpeakerLabelProcessor {
        let url = fixture.trackURL
        return SpeakerLabelProcessor(
            database: fixture.database,
            diarizer: diarizer,
            isAllowed: { allowed },
            trackURL: { _, track in track == .them ? url : url.deletingLastPathComponent().appending(path: "me.caf") },
            systemSupported: supported
        )
    }

    private static func speakers(_ fixture: Fixture) async throws -> [String?] {
        try await fixture.database.segments(meetingID: fixture.meetingID).map(\.speaker)
    }

    @Test func labelsTheOtherSideOfTheCall() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers)
        await Self.processor(fixture, diarizer: diarizer).process(meetingID: fixture.meetingID)
        #expect(try await Self.speakers(fixture) == [nil, "1", "2"])
        #expect(await diarizer.urls == [fixture.trackURL])
    }

    @Test func freePlanSkipsDiarization() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers)
        await Self.processor(fixture, diarizer: diarizer, allowed: false).process(meetingID: fixture.meetingID)
        #expect(await diarizer.urls.isEmpty)
        #expect(try await Self.speakers(fixture) == [nil, nil, nil])
    }

    @Test func unsupportedSystemSkipsDiarization() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers)
        await Self.processor(fixture, diarizer: diarizer, supported: false).process(meetingID: fixture.meetingID)
        #expect(await diarizer.urls.isEmpty)
    }

    @Test func missingTrackFileSkipsDiarization() async throws {
        let fixture = try await Self.fixture(withTrackFile: false)
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers)
        await Self.processor(fixture, diarizer: diarizer).process(meetingID: fixture.meetingID)
        #expect(await diarizer.urls.isEmpty)
    }

    @Test func meetingWithoutTheOtherSideSkipsDiarization() async throws {
        let fixture = try await Self.fixture(otherSide: false)
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers)
        await Self.processor(fixture, diarizer: diarizer).process(meetingID: fixture.meetingID)
        #expect(await diarizer.urls.isEmpty)
    }

    @Test func failedDiarizationKeepsTheTrackLabels() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: Self.twoSpeakers, fails: true)
        await Self.processor(fixture, diarizer: diarizer).process(meetingID: fixture.meetingID)
        #expect(await diarizer.urls.count == 1)
        #expect(try await Self.speakers(fixture) == [nil, nil, nil])
    }

    @Test func oneRemoteSpeakerKeepsTheTrackLabels() async throws {
        let fixture = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.trackURL) }
        let diarizer = ScriptedDiarizer(turns: [SpeakerTurn(speaker: "S1", start: 2.8, end: 8.4)])
        await Self.processor(fixture, diarizer: diarizer).process(meetingID: fixture.meetingID)
        #expect(try await Self.speakers(fixture) == [nil, nil, nil])
    }
}
