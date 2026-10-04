import Foundation
import Testing
@testable import Captylo

struct TextProcessorTests {
    private func processor(
        rules: [ReplacementRule] = [],
        fillers: [String] = DictionaryData.defaultFillerWords,
        paragraphs: Bool = true
    ) -> TextProcessor {
        TextProcessor(
            dictionary: DictionaryData(vocabulary: [], replacements: rules, fillerWords: fillers),
            paragraphs: paragraphs
        )
    }

    private func rule(_ triggers: String..., to replacement: String) -> ReplacementRule {
        ReplacementRule(triggers: triggers, replacement: replacement)
    }

    // MARK: Tags and brackets (gotcha 79)

    @Test func stripsTagsAndSquareAndCurlyBrackets() {
        let raw = "[music] Cześć <TAG attr=\"x\">ukryte</TAG> świecie {noise} <br/> koniec"
        #expect(processor().process(raw) == "Cześć świecie koniec")
    }

    @Test func stripsOnlyShortParentheticalsWithoutDigits() {
        #expect(TextProcessor.stripTags("(laughs) Cześć") == " Cześć")
        #expect(TextProcessor.stripTags("Tak (śmiech w tle) jest") == "Tak  jest")
        #expect(TextProcessor.stripTags("Tak (to jest bardzo długi nawias) jest") == "Tak (to jest bardzo długi nawias) jest")
        #expect(TextProcessor.stripTags("Spotkanie (rok 2024) odbyło się") == "Spotkanie (rok 2024) odbyło się")
        #expect(TextProcessor.stripTags("Cena (5) zł") == "Cena (5) zł")
    }

    @Test func tagStrippingKeepsTextOutsideTags() {
        #expect(TextProcessor.stripTags("<think>secret</think>Odpowiedź") == "Odpowiedź")
        #expect(TextProcessor.stripTags("a < b i c > d") == "a < b i c > d")
    }

    // MARK: Fillers (gotcha 77)

    @Test func fillerTableFromThePortNote() {
        let text = "So, um, I think I said um. Then Hmm we go."
        #expect(processor().process(text) == "So, I think I said. Then we go.")
        #expect(processor().process("Um, hello") == "Hello")
        #expect(processor().process("Hmm. Tak jest.") == "Tak jest.")
        #expect(processor().process("Tak, eee, jest dobrze") == "Tak, jest dobrze")
        #expect(processor().process("yyy to jest test") == "To jest test")
        #expect(processor().process("Czy tak um?") == "Czy tak?")
        #expect(processor().process("Idziemy. Hmm. Dobrze.") == "Idziemy. Dobrze.")
    }

    @Test func fillersNeverRemoveRealPolishWords() {
        let text = "No jakby wiesz, to jest ważne."
        #expect(processor().process(text) == text)
        #expect(!DictionaryData.defaultFillerWords.contains("no"))
        #expect(!DictionaryData.defaultFillerWords.contains("jakby"))
        #expect(!DictionaryData.defaultFillerWords.contains("wiesz"))
    }

    @Test func fillersRespectUnicodeWordBoundaries() {
        #expect(processor().process("meeeting z zespołem") == "meeeting z zespołem")
        #expect(processor().process("Łódź yyy Kraków") == "Łódź Kraków")
        #expect(processor().process("hummus jest dobry") == "hummus jest dobry")
    }

    @Test func emptyFillerListTurnsRemovalOff() {
        #expect(processor(fillers: []).process("yyy to jest") == "yyy to jest")
    }

    @Test func removeFillersHelperKeepsSentencePunctuation() {
        #expect(TextProcessor.removeFillers("Nie wiem uhm.", fillers: ["uhm"]) == "Nie wiem.")
        #expect(TextProcessor.removeFillers("Ala ma kota .", fillers: []) == "Ala ma kota.")
    }

    // MARK: Whitespace

    @Test func collapsesSpacesAndTrimsLines() {
        #expect(processor(paragraphs: false).process("  a  \t b \n   c  \r\n d ") == "a b\nc\nd")
        #expect(TextProcessor.collapseWhitespace("") == "")
    }

    // MARK: Paragraphs (port note 3.4)

    private func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    @Test func realPolishPhrasesAreNeverTreatedAsLayoutCues() {
        let tram = "Powstanie nowa linia tramwajowa."
        #expect(processor().process(tram) == tram)
        let history = "To nowy akapit w historii firmy."
        #expect(processor().process(history) == history)
        #expect(processor().process("First one new paragraph second one new line third") == "First one new paragraph second one new line third")
    }

    @Test func shortDictationStaysOneLine() {
        let text = "Cześć, co u ciebie?\nMam nadzieję, że dobrze."
        #expect(processor().process(text, language: "pl") == "Cześć, co u ciebie? Mam nadzieję, że dobrze.")
    }

    @Test func fourSignificantSentencesCloseAParagraph() {
        let sentence = "To jest zdanie numer jeden w tekście."
        let text = Array(repeating: sentence, count: 6).joined(separator: " ")
        let result = processor().process(text, language: "pl")
        let paragraphs = result.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0] == Array(repeating: sentence, count: 4).joined(separator: " "))
        #expect(paragraphs[1] == Array(repeating: sentence, count: 2).joined(separator: " "))
        #expect(words(result) == words(text))
    }

    @Test func fiftyWordsCloseAParagraph() {
        let long = (1...30).map { "słowo\($0)" }.joined(separator: " ") + "."
        let text = [long, long, "Koniec."].joined(separator: " ")
        let result = TextProcessor.formatParagraphs(text, language: "pl")
        #expect(result == "\(long) \(long)\n\nKoniec.")
        #expect(words(result) == words(text))
    }

    @Test func shortSentencesDoNotCountAsSignificant() {
        let text = "Tak. Nie. Może. Dobrze. Jasne. Okej."
        #expect(TextProcessor.formatParagraphs(text, language: "pl") == text)
    }

    @Test func paragraphsOffKeepsTheLayout() {
        let text = "Pierwsza linia\nDruga linia"
        #expect(processor(paragraphs: false).process(text) == text)
        #expect(TextProcessor.formatParagraphs("   ") == "")
    }

    // MARK: Replacements (gotcha 76)

    @Test func fixesParakeetSpellingOfBrandNames() {
        let rules = [rule("kap tylo", "kaptilo", to: "Captylo"), rule("kawalec", to: "Kawalec")]
        #expect(processor(rules: rules).process("Używam kap tylo codziennie") == "Używam Captylo codziennie")
        #expect(processor(rules: rules).process("Dawid kawalec i kawalecki") == "Dawid Kawalec i kawalecki")
    }

    @Test func polishDiacriticsInsideTriggersAndBoundaries() {
        let rules = [rule("żółw", to: "Turtle")]
        #expect(processor(rules: rules).process("żółw i żółwik") == "Turtle i żółwik")
        #expect(processor(rules: rules).process("Żółw, ŻÓŁW!") == "Turtle, Turtle!")
        #expect(processor(rules: [rule("łódź", to: "Łódź")]).process("jadę do łódź") == "jadę do Łódź")
    }

    @Test func multiWordTriggersMatchAcrossCase() {
        let rules = [rule("voice ink", to: "Captylo")]
        #expect(processor(rules: rules).process("Voice ink rocks, voice INK!") == "Captylo rocks, Captylo!")
    }

    @Test func longestTriggerWinsRegardlessOfRuleOrder() {
        let rules = [rule("craft", to: "X"), rule("craft web", to: "CraftWeb")]
        #expect(processor(rules: rules).process("craft web i craft") == "CraftWeb i X")
    }

    @Test func replacementTextIsInsertedVerbatim() {
        #expect(processor(rules: [rule("cost", to: "$5 fee")]).process("the price is cost") == "the price is $5 fee")
        #expect(processor(rules: [rule("back", to: "C:\\dir")]).process("go back") == "go C:\\dir")
        #expect(processor(rules: [rule("api", to: "API")]).process("Api and API and api") == "API and API and API")
        #expect(processor(rules: [rule("kot", to: "kOt")]).process("KOT") == "kOt")
    }

    @Test func multiLineReplacementSurvivesTheWhitespaceStep() {
        let rules = [rule("mój adres", to: "ul. Nowa 1\n00-001 Warszawa")]
        let output = processor(rules: rules).process("Wyślij na mój adres, dzięki")
        #expect(output == "Wyślij na ul. Nowa 1\n00-001 Warszawa, dzięki")
    }

    @Test func cjkTriggersUsePlainReplace() {
        #expect(processor(rules: [rule("東京", to: "Tokyo")]).process("行く東京へ") == "行くTokyoへ")
        #expect(TextProcessor.usesWordBoundaries("東京") == false)
        #expect(TextProcessor.usesWordBoundaries("żółw") == true)
    }

    @Test func latinTriggerFlushAgainstCjkStillMatches() {
        #expect(processor(rules: [rule("ink", to: "Ink")]).process("東京ink") == "東京Ink")
    }

    @Test func emptyTriggersAreIgnored() {
        let output = TextProcessor.applyReplacements("a b", rules: [rule("", " ", to: "X")])
        #expect(output == "a b")
    }

    // MARK: Full pipeline order (gotcha 78)

    @Test func fillersRunBeforeReplacementsAndReplacementsAfterParagraphs() {
        let rules = [rule("test", to: "Test\nline")]
        // Paragraphs run before replacements, so a multi-line replacement keeps its newline.
        let raw = "[music] yyy to test, dobrze. koniec"
        #expect(processor(rules: rules).process(raw, language: "pl") == "To Test\nline, dobrze. koniec")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(processor().process("") == "")
        #expect(processor().process("   \n ") == "")
    }
}
