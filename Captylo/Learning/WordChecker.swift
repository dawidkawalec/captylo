import AppKit

/// "Is this a real word?" through the system spell checker (Polish and English). A learned
/// replacement rule never has a real word as its trigger (AGENTS.md: never remove real Polish
/// words deterministically); such pairs only become AI hints.
@MainActor
enum WordChecker {
    private static let languages: [String] = {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        return ["pl", "en"].filter(available.contains)
    }()

    static func isRealWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
        // One letter, digits, or no dictionary to ask: treat as real, so nothing is replaced.
        guard trimmed.count >= 2, trimmed.contains(where: \.isLetter), !languages.isEmpty else { return true }
        let checker = NSSpellChecker.shared
        return languages.contains { language in
            checker.checkSpelling(of: trimmed, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                .location == NSNotFound
        }
    }
}
