import Foundation

/// Meeting search compares folded text: lowercased, without diacritics and with "ł" as "l",
/// so "zarzad" finds "Zarząd" and "lodz" finds "Łódź". The store keeps folded copies of the
/// title, notes and transcript (`Meeting.searchText`, `Meeting.titleNotesSearchText`), which lets
/// the query run in SQLite instead of loading every transcript into memory.
enum MeetingSearch {
    /// Folded form used for the stored search columns and for queries ("Zarząd" -> "zarzad").
    /// Locale independent on purpose: rows folded under one UI language must match queries typed
    /// under the other.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "ł", with: "l")
    }

    /// Folded title and notes, the second search column of a meeting row.
    static func titleNotes(title: String, notes: String) -> String {
        fold(title) + "\n" + fold(notes)
    }

    /// Folded transcript of a meeting: every segment that is not echo, in the given order.
    static func transcript(_ texts: [String]) -> String {
        texts.map { " " + fold($0) }.joined()
    }
}
