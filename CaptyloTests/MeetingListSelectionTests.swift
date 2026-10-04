import Foundation
import Testing
@testable import Captylo

/// The Spotkania list keeps the selected meeting across reloads, also one older than the list's
/// newest `MeetingsView.listLimit` (a "Zapytaj wszystkie" citation can open any meeting).
struct MeetingListSelectionTests {
    private static func meeting(_ id: UUID = UUID(), daysAgo: Double) -> MeetingRecord {
        MeetingRecord(id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400), title: "M")
    }

    @Test func aSelectionOutsideTheFetchedRowsIsFetchedOnItsOwnWithoutASearch() {
        let old = UUID()
        let fetched = [Self.meeting(daysAgo: 1), Self.meeting(daysAgo: 2)]
        #expect(MeetingListSelection.missing(selected: old, query: "", fetched: fetched) == old)
        #expect(MeetingListSelection.missing(selected: old, query: "   ", fetched: fetched) == old)
    }

    @Test func nothingExtraIsFetchedWhenTheSelectionIsListedMissingOrASearchRuns() {
        let listed = Self.meeting(daysAgo: 1)
        #expect(MeetingListSelection.missing(selected: listed.id, query: "", fetched: [listed]) == nil)
        #expect(MeetingListSelection.missing(selected: nil, query: "", fetched: [listed]) == nil)
        // A search shows its own results: the selection moves to the best match.
        #expect(MeetingListSelection.missing(selected: UUID(), query: "oferta", fetched: [listed]) == nil)
    }

    @Test func theOldSelectedMeetingJoinsTheRowsInDateOrder() {
        let newest = Self.meeting(daysAgo: 1)
        let newer = Self.meeting(daysAgo: 2)
        let old = Self.meeting(daysAgo: 400)
        let rows = MeetingListSelection.rows(fetched: [newest, newer], adding: old)
        #expect(rows.map(\.id) == [newest.id, newer.id, old.id])
        #expect(MeetingListSelection.selection(current: old.id, rows: rows) == old.id)
    }

    @Test func aMeetingAlreadyListedIsNotAddedTwice() {
        let newest = Self.meeting(daysAgo: 1)
        let rows = MeetingListSelection.rows(fetched: [newest], adding: newest)
        #expect(rows.map(\.id) == [newest.id])
        #expect(MeetingListSelection.rows(fetched: [newest], adding: nil).map(\.id) == [newest.id])
    }

    @Test func aSelectionNoLongerListedFallsBackToTheNewest() {
        let newest = Self.meeting(daysAgo: 1)
        let rows = [newest, Self.meeting(daysAgo: 2)]
        // Deleted meanwhile (the store did not return it) or not matching the search.
        #expect(MeetingListSelection.selection(current: UUID(), rows: rows) == newest.id)
        #expect(MeetingListSelection.selection(current: nil, rows: rows) == newest.id)
        #expect(MeetingListSelection.selection(current: rows[1].id, rows: rows) == rows[1].id)
        #expect(MeetingListSelection.selection(current: UUID(), rows: []) == nil)
    }
}
