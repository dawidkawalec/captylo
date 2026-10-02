import Foundation

/// Which meeting the Spotkania list keeps selected across reloads. The list holds only the
/// newest `MeetingsView.listLimit` meetings, but a "Zapytaj wszystkie" citation (or a search
/// result kept after the search is cleared) can select an older one: without a search, a reload
/// fetches that meeting on its own and lists it in date order, so the selection and its
/// transcript jump survive. A search shows its own results and selects the best match when the
/// selection is not among them.
enum MeetingListSelection {
    /// The selected meeting a reload must fetch by id: no search typed and the selection is not
    /// among the fetched rows. nil otherwise.
    static func missing(selected: UUID?, query: String, fetched: [MeetingRecord]) -> UUID? {
        guard let selected,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fetched.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    /// The fetched rows (newest first) with `extra` placed by its date, unless already there.
    static func rows(fetched: [MeetingRecord], adding extra: MeetingRecord?) -> [MeetingRecord] {
        guard let extra, !fetched.contains(where: { $0.id == extra.id }) else { return fetched }
        var rows = fetched
        let index = rows.firstIndex(where: { $0.createdAt < extra.createdAt }) ?? rows.endIndex
        rows.insert(extra, at: index)
        return rows
    }

    /// The selection after a reload: kept while it is on the rows, else the newest row.
    static func selection(current: UUID?, rows: [MeetingRecord]) -> UUID? {
        if let current, rows.contains(where: { $0.id == current }) {
            return current
        }
        return rows.first?.id
    }
}
