import Testing
@testable import Captylo

/// Inputs are real Parakeet outputs from the self-learning spike (Polish TTS, spelled words).
struct TextSpellingDetectorTests {
    @Test func mergedCapitalsAfterACueFixTheMisheardWord() {
        let result = SpellingDetector.apply("Wdrażamy Honho, pisane HONCHO, w piątek.")
        #expect(result.text == "Wdrażamy Honcho w piątek.")
        #expect(result.spelled == [SpellingDetector.Spelled(heard: "Honho", spelled: "Honcho")])
    }

    @Test func hyphenatedLettersOfAWordHeardRightKeepTheWord() {
        let result = SpellingDetector.apply("Nazywam się Brzęk, pisane B-R-Z-Ę-K")
        #expect(result.text == "Nazywam się Brzęk")
        #expect(result.spelled == [SpellingDetector.Spelled(heard: "Brzęk", spelled: "Brzęk")])
    }

    @Test func hyphenatedLettersWorkWithoutACue() {
        let result = SpellingDetector.apply("Jego nazwisko to Kawalec, K-A-W-A-L-E-C.")
        #expect(result.text == "Jego nazwisko to Kawalec.")
    }

    @Test func przezCueWithoutComma() {
        let result = SpellingDetector.apply("Wrzucam to na Supabase przez S-U-P-A-B-A-S-E.")
        #expect(result.text == "Wrzucam to na Supabase.")
    }

    @Test func inflectedWordStaysAndMixedCaseSpellingIsKept() {
        let result = SpellingDetector.apply("Dodaj Figmę pisane F-i-g-m-a")
        #expect(result.text == "Dodaj Figmę")
        #expect(result.spelled == [SpellingDetector.Spelled(heard: "Figmę", spelled: "Figma")])
    }

    // "przez" is an everyday preposition: an acronym after it is not a spelling.
    @Test func everydayPrzezWithAcronymIsLeftAlone() {
        for text in ["Zapłaciłem przez BLIK.", "Wysyłam przez SMS, potem dzwonię.", "Loguję się przez SSO i PDF."] {
            #expect(SpellingDetector.apply(text) == SpellingDetector.Result(text: text, spelled: []))
        }
    }

    @Test func spellingUnlikeTheWordBeforeIsLeftAlone() {
        let text = "Wyślij raport, pisane NASA, jutro."
        #expect(SpellingDetector.apply(text) == SpellingDetector.Result(text: text, spelled: []))
    }

    @Test func acronymWithoutCueIsLeftAlone() {
        let text = "Podłącz API do bazy, potem NASA."
        #expect(SpellingDetector.apply(text) == SpellingDetector.Result(text: text, spelled: []))
    }

    @Test func trailingCommaThatBelongsToTheSentenceStays() {
        let result = SpellingDetector.apply("Dodaj Honho pisane HONCHO, a potem wyślij")
        #expect(result.text == "Dodaj Honcho, a potem wyślij")
    }

    // Parakeet merges the letters into capitals after the cue and can drop a Polish letter.
    @Test func parakeetMergedCapitals() {
        // After "przez" merged capitals are ambiguous ("przez BLIK"), so they stay as heard.
        #expect(SpellingDetector.apply("Wrzucam to na supabasę, przez SUPABASE.").text == "Wrzucam to na supabasę, przez SUPABASE.")
        #expect(SpellingDetector.apply("Dodaj figmę, pisane FIGMA.").text == "Dodaj figmę.")
        let dropped = SpellingDetector.apply("Nazywam się brzęk, pisane BRZK.")
        #expect(dropped.text == "Nazywam się brzęk.")
        #expect(CorrectionLearner.preferredForm(heard: "brzęk", spelled: dropped.spelled[0].spelled) == "brzęk")
        #expect(CorrectionLearner.preferredForm(heard: "figmę", spelled: "figma") == "figma")
    }

    @Test func garbledSpellingIsLeftAlone() {
        let text = "Spotkanie z firmą Ctylą literuje CAPTY-o."
        #expect(SpellingDetector.apply(text).text == text)
    }

    // "Pisane J-E-V" as its own take right after "... tylko Jeff podpowiada ..." (the owner's case).
    @Test func standaloneSpellingFindsTheWordInThePreviousDictation() throws {
        let letters = try #require(SpellingDetector.standaloneSpelling("Pisane J-E-V"))
        #expect(letters == "JEV")
        #expect(SpellingDetector.standaloneSpelling("literuję HONCHO.") == "HONCHO")
        #expect(SpellingDetector.standaloneSpelling("B-R-Z-Ę-K") == "BRZĘK")
        let previous = "Mi się wydaje, że to nawet nie jest AI, tylko Jeff podpowiada albo coś"
        let heard = try #require(SpellingDetector.closestWord(in: previous, to: letters))
        #expect(heard == "Jeff")
        #expect(SpellingDetector.cased(letters, like: heard) == "Jev")
    }

    @Test func ordinaryShortTakesAreNotSpellings() {
        for text in ["OK", "API", "Tak.", "Wyślij to przez SMS", "pisane dobrze"] {
            #expect(SpellingDetector.standaloneSpelling(text) == nil)
        }
        #expect(SpellingDetector.closestWord(in: "Spotkanie jutro rano", to: "HONCHO") == nil)
    }

    @Test func casingFollowsTheHeardWord() {
        #expect(SpellingDetector.cased("HONCHO", like: "Honho") == "Honcho")
        #expect(SpellingDetector.cased("API", like: "api") == "api")
        #expect(SpellingDetector.cased("NASA", like: "NASA") == "NASA")
        #expect(SpellingDetector.cased("Figma", like: "figmę") == "Figma")
    }
}
