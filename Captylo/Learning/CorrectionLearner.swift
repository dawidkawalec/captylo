import Foundation

/// One learned pair: what the speech engine wrote and what the user meant.
struct TermCorrection: Codable, Hashable, Sendable {
    var misheard: String
    var correct: String
}

/// Where a correction came from: an edit of pasted text or a word spelled out loud.
enum CorrectionSource: String, Codable, Sendable {
    case edit
    case voice
}

/// What one correction teaches.
struct CorrectionAnalysis: Equatable, Sendable {
    /// Term fixes ("supa bejs" -> "Supabase"), in text order, deduped.
    var terms: [TermCorrection] = []
    /// Other edits (wording, punctuation, greetings): worth a style sample.
    var isStyle = false
    /// Not a correction at all (rewritten, deleted, unrelated text): learn nothing.
    var isNoise = false
    /// Words Captylo pasted, and how many of them the user changed (for "Poprawki na 100 słów").
    var deliveredWords = 0
    var changedWords = 0
}

/// Pure rules that turn an edit into lessons (self-learning stage 1). No state, no I/O:
/// the caller passes a real-word check (`WordChecker` in the app, a set in tests).
enum CorrectionLearner {
    /// Below this share of surviving words the edit is a rewrite, not a correction.
    static let minSimilarity = 0.5
    /// A term fix changes at most this many words on either side.
    static let maxTermWords = 3
    static let maxTermLength = 60

    static func analyze(delivered: String, corrected: String, isRealWord: (String) -> Bool) -> CorrectionAnalysis {
        let deliveredTrimmed = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard deliveredTrimmed != correctedTrimmed else {
            return CorrectionAnalysis(deliveredWords: TokenDiff.words(deliveredTrimmed).count)
        }
        guard !correctedTrimmed.isEmpty,
              let hunks = TokenDiff.hunks(from: deliveredTrimmed, to: correctedTrimmed) else {
            return CorrectionAnalysis(isNoise: true)
        }
        let oldCount = TokenDiff.words(deliveredTrimmed).count
        let newCount = TokenDiff.words(correctedTrimmed).count
        // Text typed after our paste is a continuation, not a correction: judge without it.
        let judged = dropTrailingInsert(hunks)
        let judgedNewCount = newCount - (hunks.count - judged.count == 1 ? trailingInsertCount(hunks) : 0)
        guard TokenDiff.similarity(judged, oldCount: oldCount, newCount: judgedNewCount) >= minSimilarity else {
            return CorrectionAnalysis(isNoise: true)
        }

        var analysis = CorrectionAnalysis(deliveredWords: oldCount)
        var previousWord: String?
        for hunk in judged {
            switch hunk {
            case .equal(let words):
                previousWord = words.last ?? previousWord
            case .change(let old, let new):
                analysis.changedWords += max(old.count, new.count)
                if let term = termFix(old: old, new: new, atSentenceStart: startsSentence(after: previousWord), isRealWord: isRealWord) {
                    if !analysis.terms.contains(term) {
                        analysis.terms.append(term)
                    }
                } else {
                    analysis.isStyle = true
                }
                previousWord = new.last ?? previousWord
            }
        }
        analysis.changedWords = min(analysis.changedWords, oldCount)
        return analysis
    }

    /// A 1...3 word change that fixes a name, brand or misheard word; nil for any other edit.
    static func termFix(old: [String], new: [String], atSentenceStart: Bool, isRealWord: (String) -> Bool) -> TermCorrection? {
        guard (1...maxTermWords).contains(old.count), (1...maxTermWords).contains(new.count) else { return nil }
        let misheard = stripped(old.joined(separator: " "))
        let correct = stripped(new.joined(separator: " "))
        guard !misheard.isEmpty, !correct.isEmpty, correct.count <= maxTermLength,
              correct.contains(where: \.isLetter) else { return nil }

        if misheard.lowercased() == correct.lowercased() {
            // Only the case changed: a term when the capitals are not just a sentence start.
            guard misheard != correct else { return nil }
            let capitalsInside = correct.dropFirst().contains(where: \.isUppercase)
            let capitalizedName = correct.first?.isUppercase == true && !atSentenceStart
            return capitalsInside || capitalizedName ? TermCorrection(misheard: misheard, correct: correct) : nil
        }

        let correctWords = correct.split(separator: " ").map(String.init)
        let looksLikeTerm = correct.contains(where: { $0.isUppercase && $0 != correct.first })
            || (correct.first?.isUppercase == true && !atSentenceStart)
            || correct.contains(where: \.isNumber)
            || correctWords.contains { !isRealWord($0) }
        if looksLikeTerm {
            return TermCorrection(misheard: misheard, correct: correct)
        }
        // Lowercase real words on both sides: a misheard non-word close in spelling still counts.
        let misheardIsWord = misheard.split(separator: " ").allSatisfy { isRealWord(String($0)) }
        if !misheardIsWord, normalizedDistance(misheard, correct) <= 0.5 {
            return TermCorrection(misheard: misheard, correct: correct)
        }
        return nil
    }

    /// True when `a` and `b` are the same word, maybe inflected ("Figmę" / "Figma"): diacritic-
    /// and case-insensitive equal, or a shared stem of all but the last letter (4+ letters).
    static func isSameWord(_ a: String, _ b: String) -> Bool {
        let x = Array(fold(a))
        let y = Array(fold(b))
        if x == y { return true }
        let shorter = min(x.count, y.count)
        guard shorter >= 4, abs(x.count - y.count) <= 2 else { return false }
        let prefix = zip(x, y).prefix { $0 == $1 }.count
        return prefix >= shorter - 1
    }

    /// The form to keep when a spelled word turns out to be the heard one: a local engine can drop
    /// letters from a spelling ("brzęk, pisane BRZK"), so a shorter spelling whose letters all
    /// appear in the heard word, in order, loses to the heard word.
    static func preferredForm(heard: String, spelled: String) -> String {
        let h = Array(fold(heard))
        let s = Array(fold(spelled))
        guard s.count < h.count else { return spelled }
        var index = 0
        for character in h where index < s.count && character == s[index] {
            index += 1
        }
        return index == s.count ? heard : spelled
    }

    // MARK: - Helpers

    /// Levenshtein distance over the folded strings, divided by the longer length.
    static func normalizedDistance(_ a: String, _ b: String) -> Double {
        let x = Array(fold(a))
        let y = Array(fold(b))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let current = row[j]
                row[j] = x[i - 1] == y[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return Double(x.isEmpty ? y.count : row[y.count]) / Double(longest)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Without the punctuation and quotes around the phrase ("„Supabase,”" -> "Supabase").
    static func stripped(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    private static func startsSentence(after previousWord: String?) -> Bool {
        guard let last = previousWord?.last else { return true }
        return ".!?\n".contains(last)
    }

    private static func dropTrailingInsert(_ hunks: [TokenDiff.Hunk]) -> [TokenDiff.Hunk] {
        guard case .change(let old, _)? = hunks.last, old.isEmpty, hunks.count > 1 else { return hunks }
        return Array(hunks.dropLast())
    }

    private static func trailingInsertCount(_ hunks: [TokenDiff.Hunk]) -> Int {
        guard case .change(let old, let new)? = hunks.last, old.isEmpty else { return 0 }
        return new.count
    }
}
