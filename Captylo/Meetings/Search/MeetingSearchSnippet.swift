import Foundation

/// The text under a search hit in the Spotkania list: about `defaultLength` characters around
/// the first match, cut at word ends with an ellipsis on each cut side, and the matched words
/// marked (whole words, so "ofert" marks "ofertę"). Built from the store's text, never kept.
struct MeetingSearchSnippet: Sendable, Equatable {
    static let defaultLength = 80
    static let ellipsis = "…"
    /// How far a cut may move to land between words instead of inside one.
    private static let wordSnap = 16

    /// What the row shows, ellipses included, line breaks turned into spaces.
    var text: String
    /// Character offsets of the matched words in `text`, in order, never overlapping.
    var matches: [Range<Int>]

    /// `text` with the matches strongly emphasized (the view draws them bold).
    var attributed: AttributedString {
        var result = AttributedString(text)
        let characters = result.characters
        for match in matches {
            let lower = characters.index(characters.startIndex, offsetBy: match.lowerBound)
            let upper = characters.index(characters.startIndex, offsetBy: match.upperBound)
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    /// `terms` are folded (`SearchQuery.terms`); a part of `source` matches when its folded form
    /// contains a term. No match: the start of the text, nothing marked.
    static func make(_ source: String, terms: [String], length: Int = defaultLength) -> MeetingSearchSnippet {
        let characters = Array(source.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        let found = matches(in: characters, terms: terms)
        let limit = max(length, 1)
        guard characters.count > limit else {
            return MeetingSearchSnippet(text: String(characters), matches: found)
        }

        let anchor = found.first ?? 0..<0
        let lead = max(0, limit - min(anchor.count, limit)) / 3
        var start = max(0, anchor.lowerBound - lead)
        var end = min(characters.count, start + limit)
        if end == characters.count {
            start = max(0, end - limit)
        }
        // Cut between words: the start moves right to the next space, the end left to the last
        // one, as long as that keeps the first match and stays close.
        if start > 0, characters[start - 1] != " " {
            let reach = min(anchor.isEmpty ? end : anchor.lowerBound, start + wordSnap)
            if let space = (start..<max(start, reach)).first(where: { characters[$0] == " " }) {
                start = space + 1
            }
        }
        if end < characters.count, characters[end] != " " {
            let floor = min(end, max(anchor.upperBound, end - wordSnap, start))
            if let space = (floor..<end).last(where: { characters[$0] == " " }) {
                end = space
            }
        }
        while start < end, characters[start] == " " { start += 1 }
        while end > start, characters[end - 1] == " " { end -= 1 }

        let opening = start > 0 ? ellipsis : ""
        let shift = opening.count - start
        let shown = found.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, start)
            let upper = min(range.upperBound, end)
            guard lower < upper else { return nil }
            return (lower + shift)..<(upper + shift)
        }
        let text = opening + String(characters[start..<end]) + (end < characters.count ? ellipsis : "")
        return MeetingSearchSnippet(text: text, matches: shown)
    }

    /// Every word that contains a term (folded), as character ranges of `characters`, merged.
    private static func matches(in characters: [Character], terms: [String]) -> [Range<Int>] {
        let (folded, owner) = fold(characters)
        var ranges: [Range<Int>] = []
        for term in terms {
            let needle = Array(term)
            guard !needle.isEmpty, needle.count <= folded.count else { continue }
            var position = 0
            while position + needle.count <= folded.count {
                if folded[position..<(position + needle.count)].elementsEqual(needle) {
                    var lower = owner?[position] ?? position
                    var upper = (owner?[position + needle.count - 1] ?? (position + needle.count - 1)) + 1
                    while lower > 0, isWordCharacter(characters[lower - 1]) { lower -= 1 }
                    while upper < characters.count, isWordCharacter(characters[upper]) { upper += 1 }
                    ranges.append(lower..<upper)
                    position += needle.count
                } else {
                    position += 1
                }
            }
        }
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The folded text, and for each folded character the offset of the original one it came
    /// from. The whole text is folded in one go; when that keeps the length (Polish letters, plain
    /// text) folded and original line up one to one and `owner` is nil. A letter that folds into
    /// more ("ß" -> "ss") makes the length differ: then each character is folded on its own.
    private static func fold(_ characters: [Character]) -> (folded: [Character], owner: [Int]?) {
        let whole = Array(MeetingSearch.fold(String(characters)))
        if whole.count == characters.count {
            return (whole, nil)
        }
        var folded: [Character] = []
        var owner: [Int] = []
        folded.reserveCapacity(whole.count)
        owner.reserveCapacity(whole.count)
        for (offset, character) in characters.enumerated() {
            for piece in MeetingSearch.fold(String(character)) {
                folded.append(piece)
                owner.append(offset)
            }
        }
        return (folded, owner)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
