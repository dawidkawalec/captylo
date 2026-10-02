import Foundation

/// Turns what the user typed into FTS5 terms for the trigram index (`MeetingSearchIndex`).
enum SearchQuery {
    /// The trigram tokenizer cannot match anything shorter.
    static let minimumTermLength = 3

    /// Folded words of 3+ characters (`MeetingSearch.fold`), each cut to a cheap Polish stem
    /// (`stem`), without repeats, in the typed order. Anything that is not a letter or a digit
    /// splits words, so quotes and FTS5 operators never reach the index. Nil when no word has
    /// 3+ characters: the caller keeps the old `contains` search.
    static func terms(_ query: String) -> [String]? {
        let words = MeetingSearch.fold(query).split { !$0.isLetter && !$0.isNumber }
        var seen: Set<String> = []
        var terms: [String] = []
        for word in words where word.count >= minimumTermLength {
            let term = stem(String(word))
            if seen.insert(term).inserted {
                terms.append(term)
            }
        }
        return terms.isEmpty ? nil : terms
    }

    /// Words of up to 4 characters stay as they are ("lodz"); 5 to 7 lose their last character,
    /// usually the case ending ("oferta" -> "ofert" finds "ofertę", "ofert", "ofertą"; "budzetu" ->
    /// "budzet"); longer words keep their first 6 ("spotkania" -> "spotka"). Crude, and it can
    /// over-match ("budzet" also finds "budzetowy"), which is fine for search and retrieval.
    static func stem(_ word: String) -> String {
        switch word.count {
        case ...4: return word
        case 5...7: return String(word.dropLast())
        default: return String(word.prefix(6))
        }
    }

    /// FTS5 MATCH text: every term quoted as a string (inner quotes doubled), joined with AND
    /// (all terms in one entry, the list search) or OR (any term, the library ask).
    static func match(_ terms: [String], all: Bool) -> String {
        terms
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: all ? " AND " : " OR ")
    }
}
