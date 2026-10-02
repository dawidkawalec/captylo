import Foundation

/// Word error rate of a transcript against a reference text (`--compare-models`): the Levenshtein
/// distance on words, split into substitutions, deletions and insertions. Words are compared
/// folded (`MeetingSearch.fold`: lowercased, no diacritics, "ł" as "l") with punctuation stripped,
/// so "Zarząd, Łódź!" and "zarzad lodz" count as equal.
struct WordErrorRate: Equatable, Sendable {
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    /// Reference word count (the denominator).
    let words: Int

    var errors: Int { substitutions + deletions + insertions }

    /// `errors / words`. An empty reference reads 0 without errors and 1 with any inserted word.
    var wer: Double {
        guard words > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(words)
    }

    /// `wer` as a percentage with one decimal (33.3), for the JSON report.
    var percent: Double {
        (wer * 1000).rounded() / 10
    }

    /// Levenshtein alignment on the folded words of both texts.
    static func compute(reference: String, hypothesis: String) -> WordErrorRate {
        let ref = tokens(reference)
        let hyp = tokens(hypothesis)
        guard !ref.isEmpty else {
            return WordErrorRate(substitutions: 0, deletions: 0, insertions: hyp.count, words: 0)
        }
        guard !hyp.isEmpty else {
            return WordErrorRate(substitutions: 0, deletions: ref.count, insertions: 0, words: ref.count)
        }

        // cost[i][j] = edits between the first i reference words and the first j hypothesis words.
        var cost = [[Int]](repeating: [Int](repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { cost[i][0] = i }
        for j in 0...hyp.count { cost[0][j] = j }
        for i in 1...ref.count {
            for j in 1...hyp.count {
                let same = ref[i - 1] == hyp[j - 1]
                cost[i][j] = min(
                    cost[i - 1][j - 1] + (same ? 0 : 1),
                    cost[i - 1][j] + 1,
                    cost[i][j - 1] + 1
                )
            }
        }

        // Walk back from the corner: matches and substitutions first, then deletions, then insertions.
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var i = ref.count
        var j = hyp.count
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let same = ref[i - 1] == hyp[j - 1]
                if cost[i][j] == cost[i - 1][j - 1] + (same ? 0 : 1) {
                    if !same { substitutions += 1 }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1
                i -= 1
            } else {
                insertions += 1
                j -= 1
            }
        }
        return WordErrorRate(substitutions: substitutions, deletions: deletions, insertions: insertions, words: ref.count)
    }

    /// Folded words without punctuation. Apostrophes survive inside a word ("don't"), never at its ends.
    static func tokens(_ text: String) -> [String] {
        let folded = MeetingSearch.fold(text)
        var words: [String] = []
        var current = ""
        func flush() {
            let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !word.isEmpty { words.append(word) }
            current = ""
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}
