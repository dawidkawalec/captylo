import Foundation
import Testing
@testable import Captylo

struct MeetingRetentionTests {
    private func setup() throws -> (Database, URL) {
        (Database(modelContainer: try Store.makeInMemoryContainer()),
         FileManager.default.temporaryDirectory.appending(path: "retention-\(UUID().uuidString)"))
    }

    private func makeMeeting(
        _ db: Database,
        root: URL,
        createdAt: Date,
        status: MeetingStatus = .completed,
        withFiles: Bool = true
    ) async throws -> UUID {
        var meeting = MeetingRecord(createdAt: createdAt, title: "x")
        meeting.status = status
        try await db.createMeeting(meeting)
        if withFiles {
            let folder = root.appending(path: meeting.id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appending(path: "me.caf"))
        }
        return meeting.id
    }

    private func exists(_ root: URL, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: id.uuidString).path)
    }

    @Test func noneDeletesAudioRightAfterProcessing() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await makeMeeting(db, root: root, createdAt: Date())
        let retention = MeetingRetention(database: db, policy: { .none }, folder: { root.appending(path: $0.uuidString) })
        await retention.process(meetingID: id)
        #expect(!exists(root, id))
        #expect(try await db.meeting(id: id)?.hasAudio == false)
    }

    @Test func sweepDeletesOnlyOlderThanTheCutoff() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-8 * 86_400))
        let fresh = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-2 * 86_400))
        let retention = MeetingRetention(database: db, policy: { .days7 }, folder: { root.appending(path: $0.uuidString) }, now: { now })
        await retention.sweep()
        #expect(try await db.meeting(id: old)?.hasAudio == false)
        #expect(!exists(root, old))
        #expect(try await db.meeting(id: fresh)?.hasAudio == true)
        #expect(exists(root, fresh))
    }

    @Test func foreverKeepsEverything() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try await makeMeeting(db, root: root, createdAt: Date(timeIntervalSince1970: 0))
        let retention = MeetingRetention(database: db, policy: { .forever }, folder: { root.appending(path: $0.uuidString) })
        await retention.process(meetingID: old)
        await retention.sweep()
        #expect(try await db.meeting(id: old)?.hasAudio == true)
        #expect(exists(root, old))
    }

    /// A menu bar app can run for weeks: the end of every meeting also trims older audio, like
    /// the dictation retention after each save.
    @Test func processingAMeetingKeepsItsAudioAndTrimsOlderOnes() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-31 * 86_400))
        let current = try await makeMeeting(db, root: root, createdAt: now, status: .processing)
        let retention = MeetingRetention(database: db, policy: { .days30 }, folder: { root.appending(path: $0.uuidString) }, now: { now })
        await retention.process(meetingID: current)
        #expect(try await db.meeting(id: current)?.hasAudio == true)
        #expect(exists(root, current))
        #expect(try await db.meeting(id: old)?.hasAudio == false)
        #expect(!exists(root, old))
    }

    /// "Nie zachowuj" picked after meetings were kept, or a meeting cut short by a crash: the
    /// sweep removes their audio, but never the audio of a meeting that still records.
    @Test func noneSweepClearsFinishedMeetingsButNotALiveOne() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let kept = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-3 * 86_400))
        let interrupted = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-3_600), status: .interrupted)
        let live = try await makeMeeting(db, root: root, createdAt: now.addingTimeInterval(-60), status: .recording)
        let retention = MeetingRetention(database: db, policy: { .none }, folder: { root.appending(path: $0.uuidString) }, now: { now })
        await retention.sweep()
        #expect(try await db.meeting(id: kept)?.hasAudio == false)
        #expect(try await db.meeting(id: interrupted)?.hasAudio == false)
        #expect(!exists(root, kept))
        #expect(!exists(root, interrupted))
        #expect(try await db.meeting(id: live)?.hasAudio == true)
        #expect(exists(root, live))
    }

    @Test func aMissingFolderStillCountsAsRemoved() async throws {
        let (db, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await makeMeeting(db, root: root, createdAt: Date(), withFiles: false)
        let retention = MeetingRetention(database: db, policy: { .none }, folder: { root.appending(path: $0.uuidString) })
        await retention.process(meetingID: id)
        #expect(try await db.meeting(id: id)?.hasAudio == false)
    }
}
