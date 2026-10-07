import Foundation

/// One learned pair: what the speech engine wrote and what the user meant.
struct TermCorrection: Codable, Hashable, Sendable {
    var misheard: String
    var correct: String
}

/// Where a correction came from: an edit of pasted text, a word spelled out loud, or "Popraw"
/// on selected text (⌃⌥⌘P or the Services menu).
enum CorrectionSource: String, Codable, Sendable {
    case edit
    case voice
    case manual
}

/// Why a change did not become a lesson. Shown in Słownik "Ostatnio zauważone", so the user can
/// see what Captylo decided instead of guessing.
enum LearningSkipReason: String, Codable, Sendable {
    /// Most of the text changed: a rewrite, not a correction.
    case rewrite
    /// More than `CorrectionLearner.maxTermWords` words on a side: wording, kept for the style profile.
    case longChange
    /// Only the capital at the start of a sentence.
    case sentenceCase
    /// Ordinary words on both sides that do not sound alike: a change of meaning, not a mishearing.
    case ordinaryWords
    /// Only punctuation or symbols changed.
    case punctuation
    /// The user undid this pair before.
    case blocked
    /// Already learned.
    case alreadyKnown
    /// The app did not expose the field's text, so the edit could not be seen.
    case unreadable
}

/// One change of an edit that was not learned, with the reason.
struct SkippedChange: Equatable, Sendable {
    var old: String
    var new: String
    var reason: LearningSkipReason
}

/// What one correction teaches.
struct CorrectionAnalysis: Equatable, Sendable {
    /// Term fixes ("supa bejs" -> "Supabase"), in text order, deduped.
    var terms: [TermCorrection] = []
    /// Changes that are not terms, with the reason (for "Ostatnio zauważone").
    var skipped: [SkippedChange] = []
    /// Other edits (wording, punctuation, greetings): worth a style sample.
    var isStyle = false
    /// Not a correction at all (rewritten, deleted, unrelated text): learn nothing.
    var isNoise = false
    /// Words Captylo pasted, and how many of them the user changed (for "Poprawki na 100 słów").
    var deliveredWords = 0
    var changedWords = 0
}

/// What "Popraw" on selected text teaches.
enum ManualVerdict: Equatable, Sendable {
    /// The new text equals the selection.
    case unchanged
    /// Term fixes to learn.
    case terms([TermCorrection])
    /// A change of content (other words, a reworded sentence): replaced, never learned.
    case rewrite
}

/// A change judged as a possible term.
enum TermVerdict: Equatable, Sendable {
    case term(TermCorrection)
    case skip(LearningSkipReason)
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
            // A short paste fixed as a whole ("supa bejs" -> "Supabase") keeps no word, yet it is
            // the most common correction: judge it as one change instead of calling it a rewrite.
            if oldCount <= maxTermWords, newCount <= maxTermWords {
                return shortPaste(old: TokenDiff.words(deliveredTrimmed), new: TokenDiff.words(correctedTrimmed), isRealWord: isRealWord)
            }
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
                switch termVerdict(old: old, new: new, atSentenceStart: startsSentence(after: previousWord), isRealWord: isRealWord) {
                case .term(let term):
                    if !analysis.terms.contains(term) {
                        analysis.terms.append(term)
                    }
                case .skip(let reason):
                    analysis.isStyle = true
                    analysis.skipped.append(SkippedChange(old: old.joined(separator: " "), new: new.joined(separator: " "), reason: reason))
                }
                previousWord = new.last ?? previousWord
            }
        }
        analysis.changedWords = min(analysis.changedWords, oldCount)
        return analysis
    }

    /// A paste of at most `maxTermWords` words replaced as a whole. What came before it is unknown,
    /// so its first word counts as a sentence start (a capital alone teaches nothing).
    private static func shortPaste(old: [String], new: [String], isRealWord: (String) -> Bool) -> CorrectionAnalysis {
        var analysis = CorrectionAnalysis(deliveredWords: old.count, changedWords: old.count)
        switch termVerdict(old: old, new: new, atSentenceStart: true, isRealWord: isRealWord) {
        case .term(let term):
            analysis.terms = [term]
        case .skip(let reason):
            // Too short to say anything about style: only listed in "Ostatnio zauważone".
            analysis.skipped = [SkippedChange(old: old.joined(separator: " "), new: new.joined(separator: " "), reason: reason)]
        }
        return analysis
    }

    /// A 1...3 word change that fixes a name, brand or misheard word; nil for any other edit.
    static func termFix(old: [String], new: [String], atSentenceStart: Bool, isRealWord: (String) -> Bool) -> TermCorrection? {
        if case .term(let term) = termVerdict(old: old, new: new, atSentenceStart: atSentenceStart, isRealWord: isRealWord) {
            return term
        }
        return nil
    }

    /// `termFix` with the reason when the change is not a term.
    static func termVerdict(old: [String], new: [String], atSentenceStart: Bool, isRealWord: (String) -> Bool) -> TermVerdict {
        guard (1...maxTermWords).contains(old.count), (1...maxTermWords).contains(new.count) else { return .skip(.longChange) }
        let misheard = stripped(old.joined(separator: " "))
        let correct = stripped(new.joined(separator: " "))
        guard !misheard.isEmpty, !correct.isEmpty, correct.contains(where: \.isLetter) else { return .skip(.punctuation) }
        guard correct.count <= maxTermLength else { return .skip(.longChange) }

        if misheard.lowercased() == correct.lowercased() {
            // Only the case changed: a term when the capitals are not just a sentence start.
            guard misheard != correct else { return .skip(.punctuation) }
            let capitalsInside = correct.dropFirst().contains(where: \.isUppercase)
            let capitalizedName = correct.first?.isUppercase == true && !atSentenceStart
            return capitalsInside || capitalizedName ? .term(TermCorrection(misheard: misheard, correct: correct)) : .skip(.sentenceCase)
        }

        let correctWords = correct.split(separator: " ").map(String.init)
        let looksLikeTerm = correct.contains(where: { $0.isUppercase && $0 != correct.first })
            || (correct.first?.isUppercase == true && !atSentenceStart)
            || correct.contains(where: \.isNumber)
            || correctWords.contains { !isRealWord($0) }
        if looksLikeTerm {
            return .term(TermCorrection(misheard: misheard, correct: correct))
        }
        // Lowercase real words on both sides: a misheard non-word close in spelling still counts.
        let misheardIsWord = misheard.split(separator: " ").allSatisfy { isRealWord(String($0)) }
        if !misheardIsWord, normalizedDistance(misheard, correct) <= 0.5 {
            return .term(TermCorrection(misheard: misheard, correct: correct))
        }
        return .skip(.ordinaryWords)
    }

    // MARK: - "Popraw"

    /// Ordinary words that differ by at most this share of letters sound alike ("może" / "morze").
    static let soundAlikeDistance = 0.5

    /// "Popraw" on selected text: the user said outright that the selection was wrong, so ordinary
    /// words that sound alike count too ("może" -> "morze"), which the edit watcher never guesses.
    /// A short selection (up to `maxTermWords` words) is one pair; a longer one is diffed and each
    /// changed part judged alone. Other words or a reworded sentence is a rewrite: replaced, not learned.
    static func manual(original: String, corrected: String, isRealWord: (String) -> Bool) -> ManualVerdict {
        let old = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard old != new else { return .unchanged }
        guard !new.isEmpty else { return .rewrite }
        let oldWords = TokenDiff.words(old)
        let newWords = TokenDiff.words(new)
        if oldWords.count <= maxTermWords, newWords.count <= maxTermWords {
            if case .term(let term) = manualTerm(old: oldWords, new: newWords, isRealWord: isRealWord) {
                return .terms([term])
            }
            return .rewrite
        }
        guard let hunks = TokenDiff.hunks(from: old, to: new),
              TokenDiff.similarity(hunks, oldCount: oldWords.count, newCount: newWords.count) >= minSimilarity else {
            return .rewrite
        }
        var terms: [TermCorrection] = []
        for case .change(let oldPart, let newPart) in hunks {
            if case .term(let term) = manualTerm(old: oldPart, new: newPart, isRealWord: isRealWord), !terms.contains(term) {
                terms.append(term)
            }
        }
        return terms.isEmpty ? .rewrite : .terms(terms)
    }

    /// One changed part of a "Popraw": a name or brand, a case fix of a non-word, or ordinary
    /// words that sound alike.
    static func manualTerm(old: [String], new: [String], isRealWord: (String) -> Bool) -> TermVerdict {
        guard (1...maxTermWords).contains(old.count), (1...maxTermWords).contains(new.count) else { return .skip(.longChange) }
        let misheard = stripped(old.joined(separator: " "))
        let correct = stripped(new.joined(separator: " "))
        guard !misheard.isEmpty, !correct.isEmpty, correct.contains(where: \.isLetter) else { return .skip(.punctuation) }
        guard correct.count <= maxTermLength else { return .skip(.longChange) }
        let pair = TermCorrection(misheard: misheard, correct: correct)
        let misheardIsWord = misheard.split(separator: " ").allSatisfy { isRealWord(String($0)) }

        if misheard.lowercased() == correct.lowercased() {
            guard misheard != correct else { return .skip(.punctuation) }
            // "kod" -> "Kod" is a sentence start; "github" -> "GitHub" and "captylo" -> "Captylo" are names.
            let capitalsInside = correct.dropFirst().contains(where: \.isUppercase)
            return capitalsInside || !misheardIsWord ? .term(pair) : .skip(.sentenceCase)
        }

        let correctWords = correct.split(separator: " ").map(String.init)
        if correct.dropFirst().contains(where: \.isUppercase)
            || correct.contains(where: \.isNumber)
            || correctWords.contains(where: { !isRealWord($0) })
            || !misheardIsWord {
            return .term(pair)
        }
        // Ordinary words on both sides: "piątek" -> "piątku" is grammar, "może" -> "morze" a mishearing.
        if !isInflection(misheard, correct), normalizedDistance(misheard, correct) <= soundAlikeDistance {
            return .term(pair)
        }
        return .skip(.ordinaryWords)
    }

    /// Another form of the same word: a shared stem of all but the last two letters, 5+ letters.
    static func isInflection(_ a: String, _ b: String) -> Bool {
        let x = Array(fold(a))
        let y = Array(fold(b))
        let shorter = min(x.count, y.count)
        guard shorter >= 5 else { return false }
        return zip(x, y).prefix { $0 == $1 }.count >= shorter - 2
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
