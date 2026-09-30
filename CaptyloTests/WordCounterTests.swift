import Testing
@testable import Captylo

struct WordCounterTests {
    @Test func countsPolishWords() {
        #expect(WordCounter.count("Zażółć gęślą jaźń") == 3)
        #expect(WordCounter.count("Łódź, Kraków i Gdańsk.") == 4)
    }

    @Test func countsNumbers() {
        #expect(WordCounter.count("Mam 3 koty i 12 psów") == 6)
        #expect(WordCounter.count("2024") == 1)
    }

    @Test func ignoresPunctuationOnlyTokens() {
        #expect(WordCounter.count("- ... !!! ?") == 0)
        #expect(WordCounter.count("Tak - nie") == 2)
        #expect(WordCounter.count("„Cytat”") == 1)
    }

    @Test func handlesWhitespaceVariants() {
        #expect(WordCounter.count("") == 0)
        #expect(WordCounter.count("   \n\t ") == 0)
        #expect(WordCounter.count("jeden\ndwa\ttrzy   cztery") == 4)
    }

    @Test func keepsHyphenatedAndSymbolTokens() {
        #expect(WordCounter.count("e-mail C++ 100%") == 3)
    }

    @Test func legacyCountSplitsOnSpacesOnly() {
        #expect(WordCounter.legacyCount("a - b") == 3)
        #expect(WordCounter.legacyCount("jeden\ndwa") == 1)
    }
}
