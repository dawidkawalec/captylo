import Foundation

/// Word-level alignment of two texts (LCS), the base of every learned correction.
/// Words are compared without the punctuation around them and case-insensitively, so
/// "Supabase," and "supabase" line up; the hunks keep the words exactly as written.
enum TokenDiff {
    /// Texts longer than this (in words) are not aligned: too costly and never a single correction.
    static let maxWords = 600

    enum Hunk: Equatable, Sendable {
        case equal([String])
        /// `old` was changed into `new`; either side may be empty (pure insert or delete).
        case change(old: [String], new: [String])
    }

    /// Whitespace-separated words, as written.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lowercased word without the punctuation around it ("„Supabase,”" -> "supabase").
    static func key(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }

    /// Hunks that turn `old` into `new`; nil when either side is over `maxWords`.
    static func hunks(from old: String, to new: String) -> [Hunk]? {
        let a = words(old)
        let b = words(new)
        guard a.count <= maxWords, b.count <= maxWords else { return nil }
        let ka = a.map(key)
        let kb = b.map(key)

        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty, !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var hunks: [Hunk] = []
        var equal: [String] = []
        var removed: [String] = []
        var added: [String] = []
        func flushChange() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            hunks.append(.change(old: removed, new: added))
            removed = []
            added = []
        }
        func flushEqual() {
            guard !equal.isEmpty else { return }
            hunks.append(.equal(equal))
            equal = []
        }

        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j] {
                flushChange()
                // Same word, but case or punctuation changed: a change, not an equal word.
                if a[i] == b[j] {
                    equal.append(b[j])
                } else {
                    flushEqual()
                    hunks.append(.change(old: [a[i]], new: [b[j]]))
                }
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                flushEqual()
                added.append(b[j])
                j += 1
            } else {
                flushEqual()
                removed.append(a[i])
                i += 1
            }
        }
        flushChange()
        flushEqual()
        return hunks
    }

    /// Share of `old`'s words that survived into `new` (0...1); 1 for two empty texts.
    static func similarity(_ hunks: [Hunk], oldCount: Int, newCount: Int) -> Double {
        let longest = max(oldCount, newCount)
        guard longest > 0 else { return 1 }
        let kept = hunks.reduce(0) { sum, hunk in
            switch hunk {
            case .equal(let words): return sum + words.count
            case .change(let old, let new):
                // A case or punctuation fix of one word still counts as the same word.
                return sum + (old.count == 1 && new.count == 1 && key(old[0]) == key(new[0]) ? 1 : 0)
            }
        }
        return Double(kept) / Double(longest)
    }
}
