import Foundation
import SwiftData
import Testing
@testable import Captylo

/// `DeviceIdentity.current` is global: every test that sets it lives in this serialized suite.
@Suite(.serialized)
struct DataDeviceIdentityTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "captylo-device-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func loadCreatesOneIdAndKeepsIt() throws {
        let folder = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            DeviceIdentity.set("")
        }
        let first = DeviceIdentity.load(from: folder)
        #expect(UUID(uuidString: first) != nil)
        #expect(DeviceIdentity.load(from: folder) == first)
        #expect(DeviceIdentity.current == first)
    }

    @Test func aBrokenFileGetsANewId() throws {
        let folder = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            DeviceIdentity.set("")
        }
        try Data("nie json".utf8).write(to: folder.appending(path: DeviceIdentity.fileName))
        let id = DeviceIdentity.load(from: folder)
        #expect(UUID(uuidString: id) != nil)
        #expect(DeviceIdentity.load(from: folder) == id)
    }

    @Test func writesStampTheRowsWithTimeAndDevice() async throws {
        DeviceIdentity.set("device-a")
        defer { DeviceIdentity.set("") }
        let container = try Store.makeInMemoryContainer()
        let db = Database(modelContainer: container)
        let before = Date()
        let dictation = DictationRecord(text: "raz", status: .completed, audioDuration: 1, wordCount: 1)
        try await db.save(dictation)
        let meeting = MeetingRecord(title: "Spotkanie")
        try await db.createMeeting(meeting)
        let context = ModelContext(container)
        let dictationID = dictation.id
        let meetingID = meeting.id
        let row = try #require(try context.fetch(FetchDescriptor<Dictation>(predicate: #Predicate { $0.id == dictationID })).first)
        let meetingRow = try #require(try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })).first)
        #expect(row.deviceID == "device-a")
        #expect(row.updatedAt >= before)
        #expect(meetingRow.deviceID == "device-a")
        #expect(meetingRow.updatedAt >= before)
    }
}
