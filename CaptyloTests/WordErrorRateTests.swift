import Foundation
import Testing
@testable import Captylo

struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        let result = WordErrorRate.compute(reference: "ala ma kota", hypothesis: "ala ma kota")
        #expect(result == WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, words: 3))
        #expect(result.wer == 0)
        #expect(result.errors == 0)
    }

    @Test func countsASubstitution() {
        let result = WordErrorRate.compute(reference: "ala ma kota", hypothesis: "ala ma psa")
        #expect(result == WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, words: 3))
        #expect(abs(result.wer - 1.0 / 3.0) < 0.0001)
    }

    @Test func countsADeletion() {
        let result = WordErrorRate.compute(reference: "ala ma kota", hypothesis: "ala kota")
        #expect(result == WordErrorRate(substitutions: 0, deletions: 1, insertions: 0, words: 3))
    }

    @Test func countsAnInsertion() {
        let result = WordErrorRate.compute(reference: "ala ma kota", hypothesis: "ala ma dużego kota")
        #expect(result == WordErrorRate(substitutions: 0, deletions: 0, insertions: 1, words: 3))
    }

    @Test func mixesEditKinds() {
        // "the" dropped at the start, "jumps" added at the end: 2 errors over 4 words.
        let result = WordErrorRate.compute(reference: "the quick brown fox", hypothesis: "quick brown fox jumps")
        #expect(result == WordErrorRate(substitutions: 0, deletions: 1, insertions: 1, words: 4))
        #expect(result.wer == 0.5)
    }

    @Test func ignoresCaseDiacriticsAndPunctuation() {
        let result = WordErrorRate.compute(reference: "Zarząd w Łodzi, dziś!", hypothesis: "zarzad w lodzi dzis")
        #expect(result.errors == 0)
        #expect(result.words == 4)
    }

    @Test func keepsApostrophesInsideWords() {
        #expect(WordErrorRate.tokens("don't stop") == ["don't", "stop"])
        #expect(WordErrorRate.tokens("'quoted' word...") == ["quoted", "word"])
        #expect(WordErrorRate.tokens("  dwa   słowa\n") == ["dwa", "slowa"])
        #expect(WordErrorRate.tokens("12:30 o'clock") == ["12", "30", "o'clock"])
    }

    @Test func emptyHypothesisDeletesEverything() {
        let result = WordErrorRate.compute(reference: "jeden dwa trzy", hypothesis: "")
        #expect(result == WordErrorRate(substitutions: 0, deletions: 3, insertions: 0, words: 3))
        #expect(result.wer == 1)
    }

    @Test func emptyReferenceCountsInsertions() {
        let empty = WordErrorRate.compute(reference: "", hypothesis: "")
        #expect(empty == WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, words: 0))
        #expect(empty.wer == 0)

        let extra = WordErrorRate.compute(reference: "", hypothesis: "jeden dwa")
        #expect(extra == WordErrorRate(substitutions: 0, deletions: 0, insertions: 2, words: 0))
        #expect(extra.wer == 1)
    }

    @Test func percentIsRoundedToOneDecimal() {
        let result = WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, words: 3)
        #expect(result.percent == 33.3)
        #expect(WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, words: 0).percent == 0)
    }
}
