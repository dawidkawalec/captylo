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

    /// Folded Polish case endings that change the end of the noun itself, longest first: the
    /// locative "-cie" ("budzecie" -> "budze", "ofercie" -> "ofer"), "-ie" ("cenie" -> "cen",
    /// "umowie" -> "umow"), the plural "-ach", "-ami", "-om", "-ow" ("cenach" -> "cen",
    /// "kosztach" -> "koszt") and the instrumental "-em" ("planem" -> "plan").
    static let caseEndings = ["cie", "ach", "ami", "ie", "om", "ow", "em"]

    /// A word with a case ending (`caseEndings`, the first that leaves 3+ characters) loses it
    /// and keeps at most its first 6 characters ("harmonogramie" -> "harmon"). Otherwise: words
    /// of 4 characters ending in a vowel lose it ("cena" -> "cen" finds "ceny", "cenę"; "anna"
    /// -> "ann"), other words of up to 4 stay ("lodz"); 5 to 7 lose their last character,
    /// usually the case ending ("oferta" -> "ofert" finds "ofertę", "ofert", "ofertą"; "budzetu"
    /// -> "budzet"); longer words keep their first 6 ("spotkania" -> "spotka"). Never under 3
    /// characters, the trigram minimum. Crude, and it over-matches ("budze" also finds
    /// "budzetowy", "cen" also finds "cenny"), which is fine for search and retrieval.
    static func stem(_ word: String) -> String {
        for ending in caseEndings where word.hasSuffix(ending) && word.count - ending.count >= minimumTermLength {
            return String(word.dropLast(ending.count).prefix(6))
        }
        switch word.count {
        case ...3: return word
        case 4: return "aeiouy".contains(word.last ?? "x") ? String(word.dropLast()) : word
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
