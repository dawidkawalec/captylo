import Foundation
import Testing
@testable import Captylo

struct NoteListSelectionTests {
    @Test func aSelectedNoteOutsideTheListJoinsItInDateOrder() {
        let new = NoteRecord(createdAt: Date(timeIntervalSince1970: 3_000), body: "c")
        let middle = NoteRecord(createdAt: Date(timeIntervalSince1970: 2_000), body: "b")
        let old = NoteRecord(createdAt: Date(timeIntervalSince1970: 1_000), body: "a")
        #expect(NoteListSelection.rows(fetched: [new, old], adding: middle).map(\.id) == [new.id, middle.id, old.id])
        #expect(NoteListSelection.rows(fetched: [new, old], adding: nil).map(\.id) == [new.id, old.id])
        // Already listed: no second row.
        #expect(NoteListSelection.rows(fetched: [new, old], adding: new).map(\.id) == [new.id, old.id])
    }

    @Test func theSelectionStaysOnAListedNoteElseTheNewest() {
        let first = NoteRecord(body: "a")
        let second = NoteRecord(body: "b")
        #expect(NoteListSelection.selection(current: second.id, rows: [first, second]) == second.id)
        #expect(NoteListSelection.selection(current: UUID(), rows: [first, second]) == first.id)
        #expect(NoteListSelection.selection(current: nil, rows: []) == nil)
    }

    @Test func onlyASelectedNoteMissingFromAnUnfilteredListIsFetched() {
        let listed = NoteRecord(body: "a")
        let missing = UUID()
        #expect(NoteListSelection.missing(selected: missing, query: "", fetched: [listed]) == missing)
        #expect(NoteListSelection.missing(selected: listed.id, query: "", fetched: [listed]) == nil)
        #expect(NoteListSelection.missing(selected: missing, query: "kod", fetched: [listed]) == nil)
        #expect(NoteListSelection.missing(selected: nil, query: "", fetched: [listed]) == nil)
    }
}
