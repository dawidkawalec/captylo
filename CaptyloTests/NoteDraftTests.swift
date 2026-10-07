import Foundation
import Testing
@testable import Captylo

@MainActor
private final class SavedNotes {
    var records: [NoteRecord] = []
}

@MainActor
struct NoteDraftTests {
    @Test func editsSaveOnceAfterThePause() async throws {
        let saved = SavedNotes()
        let draft = NoteDraft(note: NoteRecord(body: "a"), save: { saved.records.append($0) }, debounce: .milliseconds(50))
        draft.edit(body: "ab")
        draft.edit(body: "abc")
        try await Task.sleep(for: .milliseconds(300))
        #expect(saved.records.map(\.body) == ["abc"])
    }

    @Test func flushSavesAtOnceAndOnlyWhenChanged() async {
        let saved = SavedNotes()
        let draft = NoteDraft(note: NoteRecord(title: "T", body: "a"), save: { saved.records.append($0) }, debounce: .seconds(10))
        await draft.flush()
        #expect(saved.records.isEmpty)
        draft.edit(title: "Nowy")
        await draft.flush()
        #expect(saved.records.map(\.title) == ["Nowy"])
        await draft.flush()
        #expect(saved.records.count == 1)
    }

    /// A reload keeps the draft (and the keystrokes typed meanwhile) unless the stored note says
    /// something else.
    @Test func aDraftKnowsWhetherItStillShowsTheStoredNote() {
        let note = NoteRecord(title: "T", body: "b")
        let draft = NoteDraft(note: note, save: { _ in })
        #expect(draft.isShowing(note))
        var changed = note
        changed.body = "wynik AI"
        #expect(!draft.isShowing(changed))
        #expect(!draft.isShowing(NoteRecord(title: "T", body: "b")))
    }

    @Test func aDraftKnowsItsNote() {
        let note = NoteRecord(title: "T", body: "b")
        let draft = NoteDraft(note: note, save: { _ in })
        #expect(draft.noteID == note.id)
        #expect(draft.title == "T" && draft.body == "b")
        #expect(!draft.hasUnsavedChanges)
        draft.edit(body: "c")
        #expect(draft.hasUnsavedChanges)
    }
}
