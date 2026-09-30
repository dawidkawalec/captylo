import Foundation
import NaturalLanguage

/// Deterministic post-processing of the final transcript (brief 4.7, gotchas 76-79).
/// Order (gotcha 78): tags/brackets -> fillers -> whitespace -> paragraphs -> replacements.
/// A value snapshot holding precompiled regexes; `DictionaryStore` rebuilds it on every change
/// and the dictation pipeline runs `process` once on the final text (the live preview stays raw).
struct TextProcessor: @unchecked Sendable {
    /// One flattened (trigger, replacement) pair from the dictionary.
    struct Replacement: @unchecked Sendable {
        let trigger: String
        let replacement: String
        /// nil for CJK/Thai triggers, which use a plain case-insensitive substring replace.
        let pattern: ICUPattern?
        /// `NSRegularExpression.escapedTemplate(for: replacement)` so `$` and `\` survive (gotcha 76).
        let template: String
    }

    let paragraphs: Bool
    private let fillerPatterns: [ICUPattern]
    private let replacements: [Replacement]

    init(dictionary: DictionaryData, paragraphs: Bool) {
        self.paragraphs = paragraphs
        fillerPatterns = Self.compileFillers(dictionary.fillerWords)
        replacements = Self.compileReplacements(dictionary.replacements)
    }

    /// - Parameter language: the dictation language ("pl", "auto" or nil); only a fallback for the
    ///   paragraph formatter when the text itself is too short to detect.
    func process(_ raw: String, language: String? = nil) -> String {
        var text = Self.stripTags(raw)
        text = Self.removeFillers(text, patterns: fillerPatterns)
        text = Self.collapseWhitespace(text)
        if paragraphs {
            text = Self.formatParagraphs(text, language: language)
        }
        return Self.applyReplacements(text, compiled: replacements)
    }

    // MARK: - (a) Tags and brackets (gotcha 79)

    private static let tagBlock = ICUPattern.fixed(#"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#)
    private static let selfClosingTag = ICUPattern.fixed(#"<[A-Za-z][A-Za-z0-9:_-]*(?:\s[^<>]*)?/>"#)
    private static let squareBrackets = ICUPattern.fixed(#"\[[^\[\]\n]*\]"#)
    private static let curlyBrackets = ICUPattern.fixed(#"\{[^{}\n]*\}"#)
    private static let parentheses = ICUPattern.fixed(#"\(([^()\n]*)\)"#)
    private static let maxParentheticalWords = 3

    /// Always removes `[...]`, `{...}`, `<TAG>...</TAG>` and `<tag/>`. Removes `(...)` only when the
    /// content has at most 3 words and no digits, so dictated parentheses like "(rok 2024)" survive.
    static func stripTags(_ text: String) -> String {
        var result = tagBlock.removing(from: text)
        result = selfClosingTag.removing(from: result)
        result = squareBrackets.removing(from: result)
        result = curlyBrackets.removing(from: result)
        return parentheses.rewrite(result) { match, source in
            let content = source.substring(with: match.range(at: 1))
            return isHallucinationParenthetical(content) ? "" : source.substring(with: match.range)
        }
    }

    private static func isHallucinationParenthetical(_ content: String) -> Bool {
        let words = content.split(whereSeparator: \.isWhitespace)
        guard words.count <= maxParentheticalWords else { return false }
        return !content.contains(where: \.isNumber)
    }

    // MARK: - (b) Fillers (gotcha 77)

    /// Private-use marker left where a filler was removed, so the re-capitalization step only
    /// touches sentence starts that lost a filler and never rewrites untouched text.
    private static let marker = "\u{E000}"
    private static let letterOrDigit = #"[\p{L}\p{N}]"#
    private static let spaceBeforePunctuation = ICUPattern.fixed(#"[ \t]+(?=[,.?!;:])"#)
    private static let strayMarkers = ICUPattern.fixed("\u{E000}")
    /// A marker (with spaces) between a sentence boundary and a lowercase letter.
    private static let lowercaseAfterMarker = ICUPattern.fixed(
        #"(?:^|(?<=[.?!\n]))[ \t\#u{E000}]*\#u{E000}[ \t\#u{E000}]*(\p{Ll})"#
    )

    /// Compiles one case-insensitive pattern per filler. Two shapes are matched:
    /// - a filler that forms a whole sentence ("Hmm." after a terminator or at the start), removed
    ///   together with its own terminator;
    /// - a filler between Unicode word boundaries plus an optional following comma. Sentence
    ///   punctuation after it is kept (the space before it is removed afterwards).
    static func compileFillers(_ fillers: [String]) -> [ICUPattern] {
        fillers.compactMap { raw in
            let filler = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filler.isEmpty else { return nil }
            let escaped = escapedTrigger(filler)
            let sentence = #"(?:^|(?<=[.?!\n]))[ \t]*"# + escaped + #"[ \t]*[.?!]+"#
            let inline = "(?<!\(letterOrDigit))" + escaped + "(?!\(letterOrDigit))(?:[ \\t]*,)?"
            return try? ICUPattern("(?:\(sentence)|\(inline))", options: .caseInsensitive)
        }
    }

    /// Convenience for tests: compiles `fillers` and runs the filler step alone.
    static func removeFillers(_ text: String, fillers: [String]) -> String {
        removeFillers(text, patterns: compileFillers(fillers))
    }

    static func removeFillers(_ text: String, patterns: [ICUPattern]) -> String {
        var result = strayMarkers.removing(from: text)
        guard !patterns.isEmpty else { return spaceBeforePunctuation.removing(from: result) }
        for pattern in patterns {
            result = pattern.replacing(in: result, withTemplate: marker)
        }
        result = lowercaseAfterMarker.rewrite(result) { match, source in
            let whole = source.substring(with: match.range)
            let letter = source.substring(with: match.range(at: 1))
            return String(whole.dropLast(letter.count)) + letter.uppercased()
        }
        result = strayMarkers.removing(from: result)
        return spaceBeforePunctuation.removing(from: result)
    }

    // MARK: - (c) Whitespace

    private static let spaceRuns = ICUPattern.fixed(#"[ \t]+"#)
    private static let lineBreaks = ICUPattern.fixed(#"\r\n|\r"#)

    /// Runs of spaces/tabs become one space, every line is trimmed, the whole text is trimmed.
    /// Newlines survive (the paragraph step and multi-line replacements come later).
    static func collapseWhitespace(_ text: String) -> String {
        let unified = lineBreaks.replacing(in: text, withTemplate: "\n")
        return spaceRuns.replacing(in: unified, withTemplate: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - (d) Paragraphs (port note text-processing-dictionary 3.4)

    /// A paragraph closes once it holds this many words...
    static let paragraphWordTarget = 50
    /// ...or this many significant sentences...
    static let paragraphMaxSentences = 4
    /// ...where a sentence is significant from this many words.
    static let significantSentenceWords = 4

    /// Splits long text into paragraphs (`\n\n`) by sentence and word count. Pure layout: it never
    /// adds or removes a word (spoken cues such as "nowa linia" are ordinary words here; layout
    /// commands belong to the AI cleanup prompt). Sentences come from `NLTokenizer(unit: .sentence)`
    /// in the detected language (fallback: `language`, then Polish), are trimmed and joined with one
    /// space, so a short dictation stays one line.
    static func formatParagraphs(_ text: String, language: String? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let nlLanguage = detectLanguage(trimmed, hint: language)

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.setLanguage(nlLanguage)
        sentenceTokenizer.string = trimmed
        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = trimmed[range]
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }

        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.setLanguage(nlLanguage)
        var paragraphs: [String] = []
        var current: [String] = []
        var words = 0
        var significant = 0
        for sentence in sentences {
            wordTokenizer.string = sentence
            let count = wordTokenizer.tokens(for: sentence.startIndex..<sentence.endIndex).count
            current.append(sentence)
            words += count
            if count >= significantSentenceWords {
                significant += 1
            }
            if words >= paragraphWordTarget || significant >= paragraphMaxSentences {
                paragraphs.append(current.joined(separator: " "))
                current = []
                words = 0
                significant = 0
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: " "))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func detectLanguage(_ text: String, hint: String?) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            return dominant
        }
        if let hint, !hint.isEmpty, hint != TranscriptionLanguages.auto {
            return NLLanguage(rawValue: hint)
        }
        return .polish
    }

    // MARK: - (e) Replacements (gotcha 76)

    /// Unicode letters/marks/digits minus the non-spaced scripts, so Latin triggers flush against
    /// CJK/Thai text still match (ICU class subtraction, needs NSRegularExpression).
    private static let wordCharacter =
        #"[[\p{L}\p{M}\p{N}]-[\p{scx=Han}\p{scx=Hiragana}\p{scx=Katakana}\p{scx=Hangul}\p{scx=Thai}]]"#

    /// Flattens every (trigger, replacement) pair and sorts by trigger length, longest first,
    /// so "craft web" wins over "craft". Ties keep the dictionary order.
    static func compileReplacements(_ rules: [ReplacementRule]) -> [Replacement] {
        var pairs: [(trigger: String, replacement: String)] = []
        for rule in rules {
            for raw in rule.triggers {
                let trigger = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trigger.isEmpty else { continue }
                pairs.append((trigger, rule.replacement))
            }
        }
        let ordered = pairs.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.trigger.count != rhs.element.trigger.count {
                    return lhs.element.trigger.count > rhs.element.trigger.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        return ordered.map { pair in
            var pattern: ICUPattern?
            if usesWordBoundaries(pair.trigger) {
                let body = "(?<!\(wordCharacter))\(escapedTrigger(pair.trigger))(?!\(wordCharacter))"
                pattern = try? ICUPattern(body, options: .caseInsensitive)
            }
            return Replacement(
                trigger: pair.trigger,
                replacement: pair.replacement,
                pattern: pattern,
                template: NSRegularExpression.escapedTemplate(for: pair.replacement)
            )
        }
    }

    /// Convenience for tests: compiles `rules` and runs the replacement step alone.
    static func applyReplacements(_ text: String, rules: [ReplacementRule]) -> String {
        applyReplacements(text, compiled: compileReplacements(rules))
    }

    /// Sequential, so the output of one rule can be matched by a later one (same as the old app).
    static func applyReplacements(_ text: String, compiled: [Replacement]) -> String {
        var result = text
        for item in compiled {
            if let pattern = item.pattern {
                result = pattern.replacing(in: result, withTemplate: item.template)
            } else {
                result = result.replacingOccurrences(of: item.trigger, with: item.replacement, options: .caseInsensitive)
            }
        }
        return result
    }

    /// Escapes a trigger for ICU; runs of whitespace inside it match any whitespace run.
    private static func escapedTrigger(_ trigger: String) -> String {
        trigger.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }

    /// False when the trigger contains Hiragana, Katakana, CJK, Hangul or Thai scalars
    /// (no word boundaries in those scripts, plain substring replace is used instead).
    static func usesWordBoundaries(_ trigger: String) -> Bool {
        !trigger.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x0E00...0x0E7F:
                return true
            default:
                return false
            }
        }
    }
}
