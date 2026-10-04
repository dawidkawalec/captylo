import Testing
@testable import Captylo

struct TextVocabularyHintsTests {
    @Test func keytermsFilterAndDedupe() {
        let words = [
            "Kawalec", " kawalec ", "CraftWeb", "", "a <b>", "za[dużo]", "back\\slash",
            "jeden dwa trzy cztery pięć sześć", String(repeating: "x", count: 51), "pięć słów to jest ok",
        ]
        #expect(VocabularyHints.elevenLabsKeyterms(words) == ["Kawalec", "CraftWeb", "pięć słów to jest ok"])
    }

    @Test func keytermsAreCappedAtOneThousand() {
        let words = (0..<1200).map { "term\($0)" }
        let terms = VocabularyHints.elevenLabsKeyterms(words)
        #expect(terms.count == 1000)
        #expect(terms.first == "term0")
        #expect(terms.last == "term999")
    }

    @Test func llmListRespectsTermAndCharLimits() {
        let words = (0..<200).map { "słowo\($0)" }
        let list = VocabularyHints.llmList(words)
        #expect(list.components(separatedBy: ", ").count == 150)
        #expect(VocabularyHints.llmList(words, maxTerms: 3) == "słowo0, słowo1, słowo2")
        #expect(VocabularyHints.llmList(["aaaa", "bbbb", "cccc"], maxChars: 10) == "aaaa, bbbb")
        #expect(VocabularyHints.llmList(["A", "a", " A "]) == "A")
        #expect(VocabularyHints.llmList([]) == "")
    }

    @Test func whisperPromptIsNilWhenEmptyAndFitsTheBudget() {
        #expect(VocabularyHints.whisperPrompt([]) == nil)
        #expect(VocabularyHints.whisperPrompt(["Kawalec", "CraftWeb"]) == "Glossary: Kawalec, CraftWeb.")
        let long = VocabularyHints.whisperPrompt((0..<500).map { "termin\($0)" })
        #expect(long != nil)
        #expect((long?.count ?? 0) <= 600)
        #expect(long?.hasSuffix(".") == true)
        #expect(VocabularyHints.whisperPrompt(["Kawalec"], maxChars: 5) == nil)
    }
}
