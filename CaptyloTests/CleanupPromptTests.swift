import Testing
@testable import Captylo

struct CleanupPromptTests {
    @Test func emptyVocabularyRemovesTheDictionaryLine() {
        let prompt = CleanupPrompt.system(template: CleanupPrompt.defaultTemplate, vocabulary: [])
        #expect(!prompt.contains(CleanupPrompt.dictionaryPlaceholder))
        #expect(!prompt.contains("Spell these terms"))
        #expect(prompt.hasPrefix("You clean up dictated speech."))
        #expect(prompt.hasSuffix("Output only the cleaned text."))
        #expect(prompt.contains("Never translate."))
    }

    @Test func vocabularyIsInsertedAsACommaList() {
        let prompt = CleanupPrompt.system(template: CleanupPrompt.defaultTemplate, vocabulary: ["Captylo", " Kawalec ", "captylo", ""])
        #expect(prompt.contains("Spell these terms exactly when they are meant: Captylo, Kawalec"))
        #expect(!prompt.contains(CleanupPrompt.dictionaryPlaceholder))
    }

    @Test func percentSignSurvives() {
        let prompt = CleanupPrompt.system(template: "Terms: {DICTIONARY}", vocabulary: ["100%", "C++"])
        #expect(prompt == "Terms: 100%, C++")
    }

    @Test func emptyTemplateFallsBackToDefault() {
        let prompt = CleanupPrompt.system(template: "   \n", vocabulary: ["Foo"])
        #expect(prompt.contains("Spell these terms exactly when they are meant: Foo"))
        #expect(prompt.hasPrefix("You clean up dictated speech."))
    }

    @Test func customTemplateWithoutPlaceholderGetsTheDictionaryAppended() {
        let prompt = CleanupPrompt.system(template: "Popraw tekst.", vocabulary: ["Foo"])
        #expect(prompt == "Popraw tekst.\nSpell these terms exactly when they are meant: Foo")
        #expect(CleanupPrompt.system(template: "Popraw tekst.", vocabulary: []) == "Popraw tekst.")
    }

    @Test func termCountIsCapped() {
        let terms = (0..<300).map { "t\($0)" }
        let list = CleanupPrompt.dictionaryList(terms)
        #expect(list.components(separatedBy: ", ").count == CleanupPrompt.maxTerms)
    }

    @Test func characterCountIsCapped() {
        let terms = (0..<100).map { _ in String(repeating: "x", count: 100) + "\(Int.random(in: 0...9))" }
        let unique = terms.enumerated().map { "\($0.element)\($0.offset)" }
        let list = CleanupPrompt.dictionaryList(unique)
        #expect(list.count <= CleanupPrompt.maxChars)
        #expect(list.components(separatedBy: ", ").count == 14)
    }

    @Test func dedupeIsCaseInsensitive() {
        #expect(CleanupPrompt.dictionaryList(["Slack", "slack", "SLACK", "Jira"]) == "Slack, Jira")
    }

    @Test func learnedHintsAreAppendedToAnyTemplate() {
        let hints = [TermCorrection(misheard: "kot", correct: "Kod"), TermCorrection(misheard: "KOT", correct: "Kot")]
        let prompt = CleanupPrompt.system(template: "Custom prompt.", vocabulary: [], learned: LearningPromptContext(misheard: hints))
        #expect(prompt.hasPrefix("Custom prompt."))
        #expect(prompt.hasSuffix("(heard -> meant), fix them when they appear: kot -> Kod"))
    }

    @Test func noHintsLeaveThePromptUnchanged() {
        let plain = CleanupPrompt.system(template: CleanupPrompt.defaultTemplate, vocabulary: ["Captylo"])
        #expect(CleanupPrompt.system(template: CleanupPrompt.defaultTemplate, vocabulary: ["Captylo"], learned: .none) == plain)
        #expect(!plain.contains("heard -> meant"))
        #expect(!plain.contains("writing style"))
    }

    @Test func styleAndTargetAppAreAppended() {
        let learned = LearningPromptContext(style: "- Mail: zaczynaj od „Dzień dobry”.", targetApp: "Mail")
        let prompt = CleanupPrompt.system(template: "Custom prompt.", vocabulary: [], learned: learned)
        #expect(prompt.contains("writing style"))
        #expect(prompt.contains("- Mail: zaczynaj od „Dzień dobry”."))
        #expect(prompt.hasSuffix("The text will be pasted into Mail."))
    }

    @Test func targetAppAloneAddsNothing() {
        let prompt = CleanupPrompt.system(template: "Custom prompt.", vocabulary: [], learned: LearningPromptContext(targetApp: "Mail"))
        #expect(prompt == "Custom prompt.")
    }

    @Test func hintListIsCapped() {
        let pairs = (0..<100).map { TermCorrection(misheard: "slowo\($0)", correct: "Słowo\($0)") }
        let list = CleanupPrompt.hintList(pairs)
        #expect(list.count <= CleanupPrompt.maxHintChars)
        #expect(list.components(separatedBy: ", ").count <= CleanupPrompt.maxHints)
    }
}
