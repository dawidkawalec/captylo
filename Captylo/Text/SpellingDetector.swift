import Foundation

/// Words spelled out loud ("Honcho, pisane H O N C H O"). Seen in the self-learning spike
/// (docs/reference/spelling-spike.md): the cloud engine writes "H-O-N-C-H-O" (also for letter
/// names: "ef i gie em a" -> "F-i-g-m-a"), the earlier local engine (Parakeet) merged them into "HONCHO" after the cue and
/// may drop a Polish letter ("BRZK"). The spelling is removed, the word before it takes the
/// spelled form, and the pair goes to self-learning.
enum SpellingDetector {
    struct Spelled: Equatable, Sendable {
        /// The word the engine wrote before the spelling, without punctuation.
        var heard: String
        /// The spelled word, cased after `heard`.
        var spelled: String
    }

    struct Result: Equatable, Sendable {
        var text: String
        var spelled: [Spelled]
    }

    /// Cue words that may stand between the word and its spelling. Merged capitals ("HONCHO")
    /// only count after one of them; hyphenated letters count with or without.
    static let cues = [
        "pisane", "pisany", "pisana", "pisze się", "piszę", "literuję", "literuje", "literując",
        "spelled", "spelt", "spelling",
    ]
    /// "przez" is an everyday preposition ("Zapłaciłem przez BLIK"), so it only leads into
    /// hyphenated letters ("przez S-U-P-A-B-A-S-E"), never into merged capitals.
    static let hyphenOnlyCues = ["przez"]
    /// A spelling far from the word before it is not a correction of that word: the text is
    /// left alone ("Wysyłam przez SMS", "Zapłaciłem BLIK-iem").
    static let maxDistance = 0.5

    private static let regex: NSRegularExpression = {
        let strict = cues.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let loose = (cues + hyphenOnlyCues).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Whole tokens only: "CAPTY-o" (a garbled spelling) is neither form.
        let hyphenated = #"(?<![\p{L}-])\p{L}(?:-\p{L}){2,}(?![\p{L}-])"#
        let capitals = #"(?<![\p{L}-])\p{Lu}{3,}(?![\p{L}-])"#
        // Only the cue is case-insensitive: "\p{Lu}" must stay strictly capitals. Merged capitals
        // need a strict cue ("API" alone is just an acronym), hyphenated letters take any cue or none.
        let pattern = #"(?<word>[\p{L}\p{N}][\p{L}\p{N}'’]*)(?<c1>\s*,)?\s+"#
            + #"(?:(?i:"# + strict + #")\s*:?\s+(?<sp>"# + capitals + #")"#
            + #"|(?:(?i:"# + loose + #")\s*:?\s+)?(?<sp2>"# + hyphenated + #"))"#
            + #"(?<c2>\s*,)?"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func apply(_ text: String) -> Result {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Result(text: text, spelled: []) }

        var output = ""
        var spelled: [Spelled] = []
        var cursor = 0
        for match in matches {
            let withCue = match.range(withName: "sp")
            let rawSpelling = ns.substring(with: withCue.location != NSNotFound ? withCue : match.range(withName: "sp2"))
            let heard = ns.substring(with: match.range(withName: "word"))
            let letters = rawSpelling.replacingOccurrences(of: "-", with: "")
            let word = cased(letters, like: heard)
            let keepHeard = CorrectionLearner.isSameWord(heard, word)
            // Not a spelling of the word before it: leave this match as it was.
            guard keepHeard || CorrectionLearner.normalizedDistance(heard, word) <= maxDistance else { continue }

            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += keepHeard ? heard : word
            let hadLeadingComma = match.range(withName: "c1").location != NSNotFound
            let hadTrailingComma = match.range(withName: "c2").location != NSNotFound
            if hadTrailingComma, !hadLeadingComma {
                output += ","
            }
            cursor = match.range.location + match.range.length
            spelled.append(Spelled(heard: heard, spelled: word))
        }
        output += ns.substring(from: cursor)
        return Result(text: output, spelled: spelled)
    }

    /// A take that is only a spelling ("Pisane J-E-V.", "literuję HONCHO"): the spelled letters,
    /// or nil. It corrects the previous dictation instead of being pasted.
    static func standaloneSpelling(_ text: String) -> String? {
        let cue = (cues + hyphenOnlyCues).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"^\s*(?:(?i:"# + cue + #")\s*:?\s+)?(\p{L}(?:-\p{L}){2,}|\p{Lu}{3,})\s*[.!?]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        // Merged capitals alone could be an acronym answer ("OK", "API"): only with a cue.
        let hasCue = !text.trimmingCharacters(in: .whitespaces).hasPrefix(raw)
        guard raw.contains("-") || hasCue else { return nil }
        return raw.replacingOccurrences(of: "-", with: "")
    }

    /// The word of `text` that `letters` most likely spells (same word or at most half the
    /// letters different), or nil. Ties go to a word that is not a real word, then to a
    /// capitalized word inside a sentence: a misheard name ("Jeff") over "jest".
    static func closestWord(in text: String, to letters: String, isRealWord: (String) -> Bool = { _ in false }) -> String? {
        let raw = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var candidates: [(word: String, distance: Double, real: Bool, name: Bool)] = []
        for (index, token) in raw.enumerated() {
            let word = CorrectionLearner.stripped(token)
            guard word.count >= 2 else { continue }
            let sentenceStart = index == 0 || raw[index - 1].last.map { ".!?".contains($0) } == true
            candidates.append((
                word,
                CorrectionLearner.isSameWord(word, letters) ? 0 : CorrectionLearner.normalizedDistance(word, letters),
                isRealWord(word),
                word.first?.isUppercase == true && !sentenceStart
            ))
        }
        let best = candidates.min { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.real != b.real { return !a.real }
            return a.name && !b.name
        }
        guard let best, best.distance <= maxDistance else { return nil }
        return best.word
    }

    /// Capitals follow the heard word: "Honho" + "HONCHO" -> "Honcho", "api" + "A-P-I" -> "api",
    /// "NASA" + "N-A-S-A" -> "NASA". Mixed-case spellings ("F-i-g-m-a") stay as spelled.
    static func cased(_ letters: String, like heard: String) -> String {
        let isAllUpper = letters == letters.uppercased()
        let isAllLower = letters == letters.lowercased()
        guard isAllUpper || isAllLower else { return letters }
        if heard.count > 1, heard == heard.uppercased(), heard != heard.lowercased() {
            return letters.uppercased()
        }
        if heard.first?.isUppercase == true {
            return letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
        }
        return letters.lowercased()
    }
}
