import Foundation

/// Turns the vocabulary list into the shape each consumer accepts. Parakeet ignores vocabulary
/// (gotcha 22); only the cloud STT and the AI prompt use these.
enum VocabularyHints {
    static let elevenLabsMaxTerms = 1000
    static let elevenLabsMaxLength = 50
    static let elevenLabsMaxWords = 5
    private static let elevenLabsForbidden = CharacterSet(charactersIn: "<>{}[]\\")

    /// ElevenLabs `keyterms`: each term <= 50 characters and <= 5 words, without `<>{}[]\`,
    /// deduped case-insensitively, at most 1000 entries.
    static func elevenLabsKeyterms(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in words {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty,
                  term.count <= elevenLabsMaxLength,
                  term.split(whereSeparator: \.isWhitespace).count <= elevenLabsMaxWords,
                  term.rangeOfCharacter(from: elevenLabsForbidden) == nil,
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == elevenLabsMaxTerms { break }
        }
        return result
    }

    /// Comma-separated list for the cleanup prompt, capped at `maxTerms` / `maxChars` (gotcha 69).
    static func llmList(_ words: [String], maxTerms: Int = 150, maxChars: Int = 1500) -> String {
        limited(words, maxTerms: maxTerms, maxChars: maxChars).joined(separator: ", ")
    }

    /// Whisper-style `prompt` ("Glossary: A, B, C.") for a future cloud engine; nil when empty.
    static func whisperPrompt(_ words: [String], maxChars: Int = 600) -> String? {
        let prefix = "Glossary: "
        let suffix = "."
        let budget = maxChars - prefix.count - suffix.count
        guard budget > 0 else { return nil }
        let terms = limited(words, maxTerms: Int.max, maxChars: budget)
        guard !terms.isEmpty else { return nil }
        return prefix + terms.joined(separator: ", ") + suffix
    }

    /// Trimmed, case-insensitively deduped prefix of `words` that fits both limits when joined by ", ".
    private static func limited(_ words: [String], maxTerms: Int, maxChars: Int) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        var length = 0
        for raw in words {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let added = terms.isEmpty ? term.count : term.count + 2
            guard terms.count < maxTerms, length + added <= maxChars else { break }
            terms.append(term)
            length += added
        }
        return terms
    }
}
