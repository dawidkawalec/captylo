import Foundation
import SwiftData
import Testing
@testable import Captylo

@MainActor
struct UIMainHistorySearchTests {
    private static func makeContext() throws -> ModelContext {
        ModelContext(try Store.makeInMemoryContainer())
    }

    private static func insert(_ context: ModelContext, text: String, enhanced: String? = nil, minutesAgo: Double) -> UUID {
        let row = Dictation(
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            text: text,
            enhancedText: enhanced,
            status: "completed"
        )
        context.insert(row)
        return row.id
    }

    @Test func emptyQueryReturnsEverythingNewestFirst() throws {
        let context = try Self.makeContext()
        let older = Self.insert(context, text: "stary wpis", minutesAgo: 30)
        let newer = Self.insert(context, text: "nowy wpis", minutesAgo: 1)
        try context.save()

        let rows = try context.fetch(HistorySearch.descriptor(query: "", limit: 50))
        #expect(rows.map(\.id) == [newer, older])
        #expect(HistorySearch.predicate(query: "   ") == nil)
    }

    @Test func queryMatchesTextAndEnhancedTextCaseInsensitively() throws {
        let context = try Self.makeContext()
        let cat = Self.insert(context, text: "Ala ma kota", minutesAgo: 3)
        let dog = Self.insert(context, text: "pies szczeka", enhanced: "Pies szczeka na KOTA.", minutesAgo: 2)
        _ = Self.insert(context, text: "zupełnie inne zdanie", minutesAgo: 1)
        try context.save()

        let rows = try context.fetch(HistorySearch.descriptor(query: "kota", limit: 50))
        #expect(Set(rows.map(\.id)) == [cat, dog])
        #expect(rows.map(\.id) == [dog, cat], "newest first")

        let upper = try context.fetch(HistorySearch.descriptor(query: "  KOTA ", limit: 50))
        #expect(upper.count == 2, "trimmed and case-insensitive")

        let none = try context.fetch(HistorySearch.descriptor(query: "żyrafa", limit: 50))
        #expect(none.isEmpty)
    }

    @Test func fetchLimitNeverDropsBelowOnePage() {
        #expect(HistorySearch.descriptor(query: "", limit: 1).fetchLimit == HistorySearch.pageSize)
        #expect(HistorySearch.descriptor(query: "", limit: 150).fetchLimit == 150)
        #expect(HistorySearch.pageSize == 50)
    }

    @Test func valueMatcherMirrorsThePredicate() {
        let record = DictationRecord(text: "Ala ma kota", enhancedText: "Ala ma Kota i psa.")
        #expect(HistorySearch.matches(record, query: ""))
        #expect(HistorySearch.matches(record, query: "KOTA"))
        #expect(HistorySearch.matches(record, query: "psa"))
        #expect(!HistorySearch.matches(record, query: "żyrafa"))
        #expect(!HistorySearch.matches(DictationRecord(text: "bez ai"), query: "psa"))
    }
}
