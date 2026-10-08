import Foundation

/// The Notatki list around its selection (like `MeetingListSelection`): a note selected from
/// elsewhere ("Otwórz", a citation) that is older than the newest `NotesView.listLimit` is fetched
/// on its own and listed in date order, so it stays selected.
enum NoteListSelection {
    /// The selected note to fetch on its own: only without a search (a search shows what matches).
    static func missing(selected: UUID?, query: String, fetched: [NoteRecord]) -> UUID? {
        guard let selected, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fetched.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    /// `fetched` with `extra` added in date order (newest first), never twice.
    static func rows(fetched: [NoteRecord], adding extra: NoteRecord?) -> [NoteRecord] {
        guard let extra, !fetched.contains(where: { $0.id == extra.id }) else { return fetched }
        var rows = fetched
        let index = rows.firstIndex { $0.createdAt < extra.createdAt } ?? rows.endIndex
        rows.insert(extra, at: index)
        return rows
    }

    /// The selection after a reload: the current note when it is listed, else the newest.
    static func selection(current: UUID?, rows: [NoteRecord]) -> UUID? {
        if let current, rows.contains(where: { $0.id == current }) { return current }
        return rows.first?.id
    }
}
