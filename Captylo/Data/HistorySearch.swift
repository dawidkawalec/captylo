import Foundation
import SwiftData

/// Fetch descriptor of the history list (brief 4.9, gotcha 83): newest first with the id as a
/// tie-breaker, `fetchLimit` grown by the "Pokaż więcej" button, search on `text` OR `enhancedText`
/// (`localizedStandardContains` is case- and diacritic-insensitive).
enum HistorySearch {
    static let pageSize = 50

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil for an empty query (no filter).
    static func predicate(query: String) -> Predicate<Dictation>? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }
        return #Predicate<Dictation> { row in
            row.text.localizedStandardContains(needle)
                || (row.enhancedText?.localizedStandardContains(needle) ?? false)
        }
    }

    static func descriptor(query: String, limit: Int) -> FetchDescriptor<Dictation> {
        var descriptor = FetchDescriptor<Dictation>(
            predicate: predicate(query: query),
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = max(limit, pageSize)
        return descriptor
    }

    /// Same rule as `predicate`, on a value record (previews and tests).
    static func matches(_ record: DictationRecord, query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        if record.text.localizedStandardContains(needle) { return true }
        return record.enhancedText?.localizedStandardContains(needle) ?? false
    }
}
