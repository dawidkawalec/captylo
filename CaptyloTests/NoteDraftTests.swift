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
        let draft = NoteDraft(note: NoteRecord(body: "a"), save: { saved.records.append($0.record); return true }, debounce: .milliseconds(50))
        draft.edit(body: "ab")
        draft.edit(body: "abc")
        try await Task.sleep(for: .milliseconds(300))
        #expect(saved.records.map(\.body) == ["abc"])
    }

    @Test func flushSavesAtOnceAndOnlyWhenChanged() async {
        let saved = SavedNotes()
        let draft = NoteDraft(note: NoteRecord(title: "T", body: "a"), save: { saved.records.append($0.record); return true }, debounce: .seconds(10))
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
        let draft = NoteDraft(note: note, save: { _ in true })
        #expect(draft.isShowing(note))
        var changed = note
        changed.body = "wynik AI"
        #expect(!draft.isShowing(changed))
        #expect(!draft.isShowing(NoteRecord(title: "T", body: "b")))
    }

    /// A save that failed keeps the edit dirty, so the next flush tries again.
    @Test func aFailedSaveIsTriedAgain() async {
        let saved = SavedNotes()
        var fails = true
        let draft = NoteDraft(note: NoteRecord(body: "a"), save: { change in
            if fails { return false }
            saved.records.append(change.record)
            return true
        }, debounce: .seconds(10))
        draft.edit(body: "ab")
        await draft.flush()
        #expect(draft.hasUnsavedChanges)
        fails = false
        await draft.flush()
        #expect(!draft.hasUnsavedChanges)
        #expect(saved.records.map(\.body) == ["ab"])
    }

    /// A save writes only what was edited here: a title written elsewhere (the AI title) is
    /// never overwritten by the draft's stale empty one.
    @Test func aSaveCarriesOnlyTheEditedFields() async {
        var changes: [NoteDraft.Change] = []
        let draft = NoteDraft(note: NoteRecord(body: "a"), save: { changes.append($0); return true }, debounce: .seconds(10))
        draft.edit(body: "ab")
        await draft.flush()
        draft.edit(title: "T")
        await draft.flush()
        #expect(changes.map(\.body) == ["ab", nil])
        #expect(changes.map(\.title) == [nil, "T"])
        #expect(draft.wasEdited)
    }

    @Test func aDraftKnowsItsNote() {
        let note = NoteRecord(title: "T", body: "b")
        let draft = NoteDraft(note: note, save: { _ in true })
        #expect(draft.noteID == note.id)
        #expect(draft.title == "T" && draft.body == "b")
        #expect(!draft.hasUnsavedChanges)
        draft.edit(body: "c")
        #expect(draft.hasUnsavedChanges)
    }
}
