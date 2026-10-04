import Foundation
import Testing
@testable import Captylo

@MainActor
struct MeetingNotesDraftTests {
    private static let delay: Duration = .milliseconds(20)

    private func database(with meetings: MeetingRecord...) async throws -> Database {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        for meeting in meetings {
            try await db.createMeeting(meeting)
        }
        return db
    }

    /// Saves land a moment after the last edit.
    private func waitUntil(_ condition: () async throws -> Bool) async rethrows {
        for _ in 0..<300 {
            if try await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func editsAreSavedAfterTheDelayWithTheTimeOfEachLine() async throws {
        let meeting = MeetingRecord(title: "Budżet")
        let db = try await database(with: meeting)
        let draft = MeetingNotesDraft(database: db, saveDelay: Self.delay)
        draft.show(meeting)
        draft.edit("budżet", at: 12)
        draft.edit("budżet\nterminy", at: 40)
        #expect(draft.hasUnsavedEdits)
        #expect(draft.lines.map(\.at) == [12, 40])
        try await waitUntil { try await db.meeting(id: meeting.id)?.notes == "budżet\nterminy" }
        let saved = try #require(try await db.meeting(id: meeting.id))
        #expect(saved.notes == "budżet\nterminy")
        #expect(saved.noteLines.map(\.text) == ["budżet", "terminy"])
        #expect(saved.noteLines.map(\.at) == [12, 40])
        await waitUntil { !draft.hasUnsavedEdits }
        #expect(!draft.hasUnsavedEdits)
    }

    /// The save changes only the notes: AI notes and speaker names written meanwhile survive.
    @Test func aSaveKeepsWhatOtherWritersChanged() async throws {
        let meeting = MeetingRecord(title: "Budżet")
        let db = try await database(with: meeting)
        let draft = MeetingNotesDraft(database: db, saveDelay: Self.delay)
        draft.show(meeting)
        draft.edit("notatka", at: 3)
        try await db.modifyMeeting(id: meeting.id) {
            $0.summary = "## Podsumowanie"
            $0.speakerNames = ["1": "Anna"]
            $0.status = .completed
        }
        try await waitUntil { try await db.meeting(id: meeting.id)?.notes == "notatka" }
        let saved = try #require(try await db.meeting(id: meeting.id))
        #expect(saved.notes == "notatka")
        #expect(saved.summary == "## Podsumowanie")
        #expect(saved.speakerNames == ["1": "Anna"])
        #expect(saved.status == .completed)
    }

    /// A reload of the same meeting while the user types never puts the old text back.
    @Test func showingTheSameMeetingKeepsUnsavedEdits() async throws {
        let meeting = MeetingRecord(title: "Budżet")
        let db = try await database(with: meeting)
        let draft = MeetingNotesDraft(database: db, saveDelay: .seconds(60))
        draft.show(meeting)
        draft.edit("piszę", at: 5)
        draft.show(meeting)
        #expect(draft.text == "piszę")
        #expect(draft.meetingID == meeting.id)
    }

    /// Another meeting selected before the delay: the first meeting's notes are saved right away
    /// and the draft shows the second one's.
    @Test func switchingMeetingsSavesThePendingEditsRightAway() async throws {
        let first = MeetingRecord(title: "Pierwsze")
        var second = MeetingRecord(title: "Drugie")
        second.notes = "stare notatki"
        second.noteLines = [MeetingNoteLine(text: "stare notatki", at: 7)]
        let db = try await database(with: first, second)
        let draft = MeetingNotesDraft(database: db, saveDelay: .seconds(60))
        draft.show(first)
        draft.edit("do zapisania", at: 9)
        draft.show(second)
        #expect(draft.meetingID == second.id)
        #expect(draft.text == "stare notatki")
        #expect(draft.lines.map(\.at) == [7])
        #expect(!draft.hasUnsavedEdits)
        try await waitUntil { try await db.meeting(id: first.id)?.notes == "do zapisania" }
        #expect(try await db.meeting(id: first.id)?.notes == "do zapisania")
        #expect(try await db.meeting(id: second.id)?.notes == "stare notatki")
    }

    @Test func flushSavesWithoutWaitingAndIgnoresADeletedMeeting() async throws {
        let meeting = MeetingRecord(title: "Budżet")
        let db = try await database(with: meeting)
        let draft = MeetingNotesDraft(database: db, saveDelay: .seconds(60))
        draft.show(meeting)
        draft.edit("szybko", at: 1)
        draft.flush()
        try await waitUntil { try await db.meeting(id: meeting.id)?.notes == "szybko" }
        #expect(try await db.meeting(id: meeting.id)?.notes == "szybko")

        try await db.deleteMeeting(id: meeting.id)
        draft.edit("po usunięciu", at: 2)
        draft.flush()
        await waitUntil { !draft.hasUnsavedEdits }
        #expect(try await db.meeting(id: meeting.id) == nil)
    }

    @Test func nothingIsEditableBeforeAMeetingIsShown() async throws {
        let db = try await database()
        let draft = MeetingNotesDraft(database: db, saveDelay: Self.delay)
        draft.edit("bez spotkania", at: 1)
        #expect(draft.text.isEmpty)
        #expect(!draft.hasUnsavedEdits)
    }
}
