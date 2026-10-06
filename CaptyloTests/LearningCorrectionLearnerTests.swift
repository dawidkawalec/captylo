import Testing
@testable import Captylo

struct LearningCorrectionLearnerTests {
    /// Stand-in for the system spell checker.
    private static let words: Set<String> = [
        "wrzucam", "to", "na", "w", "piątek", "piątku", "daj", "znać", "czy", "pasuje", "spotkanie",
        "jutro", "o", "cześć", "hej", "dzień", "dobry", "jest", "ok", "super", "i", "ala", "ma", "kota",
    ]
    private static func isRealWord(_ word: String) -> Bool { words.contains(word.lowercased()) }

    private func analyze(_ delivered: String, _ corrected: String) -> CorrectionAnalysis {
        CorrectionLearner.analyze(delivered: delivered, corrected: corrected, isRealWord: Self.isRealWord)
    }

    @Test func misheardBrandBecomesATerm() {
        let result = analyze("Wrzucam to na supa bejs w piątek.", "Wrzucam to na Supabase w piątek.")
        #expect(result.terms == [TermCorrection(misheard: "supa bejs", correct: "Supabase")])
        #expect(!result.isStyle)
        #expect(!result.isNoise)
    }

    @Test func caseFixInsideASentenceIsATerm() {
        let result = analyze("wrzucam to na supabase dziś", "wrzucam to na Supabase dziś")
        #expect(result.terms == [TermCorrection(misheard: "supabase", correct: "Supabase")])
    }

    @Test func capitalAtSentenceStartIsStyleNotATerm() {
        let result = analyze("jutro spotkanie.", "Jutro spotkanie.")
        #expect(result.terms.isEmpty)
        #expect(result.isStyle)
    }

    @Test func grammarFixOfRealWordsIsStyle() {
        let result = analyze("Spotkanie w piątek o 10.", "Spotkanie w piątku o 10.")
        #expect(result.terms.isEmpty)
        #expect(result.isStyle)
    }

    @Test func misheardLowercaseNonWordCloseInSpellingIsATerm() {
        let result = analyze("ala ma kota i hanczo", "ala ma kota i honcho")
        #expect(result.terms == [TermCorrection(misheard: "hanczo", correct: "honcho")])
    }

    @Test func greetingChangeIsStyle() {
        let result = analyze("Hej, spotkanie jutro o 10. Daj znać, czy pasuje.", "Dzień dobry, spotkanie jutro o 10. Daj znać, czy pasuje.")
        #expect(result.isStyle)
    }

    @Test func rewriteIsNoise() {
        let result = analyze("Wrzucam to na supa bejs w piątek.", "Całkiem inny tekst o czymś zupełnie innym tutaj.")
        #expect(result.isNoise)
        #expect(result.terms.isEmpty)
    }

    @Test func deletedTextIsNoise() {
        #expect(analyze("Ala ma kota", "").isNoise)
    }

    @Test func textTypedAfterThePasteIsIgnored() {
        let result = analyze("Ala ma kota", "Ala ma kota i jeszcze dopisałem kilka słów od siebie tutaj")
        #expect(result == CorrectionAnalysis(deliveredWords: 3))
    }

    @Test func unchangedTextTeachesNothing() {
        #expect(analyze("Ala ma kota", "Ala ma kota") == CorrectionAnalysis(deliveredWords: 3))
    }

    @Test func changedWordsAreCounted() {
        let result = analyze("Wrzucam to na supa bejs w piątek.", "Wrzucam to na Supabase w piątek.")
        #expect(result.deliveredWords == 7)
        #expect(result.changedWords == 2)
    }

    @Test func skippedChangesSayWhy() {
        #expect(analyze("jutro spotkanie.", "Jutro spotkanie.").skipped.map(\.reason) == [.sentenceCase])
        #expect(analyze("Spotkanie w piątek o 10.", "Spotkanie w piątku o 10.").skipped
            == [SkippedChange(old: "piątek", new: "piątku", reason: .ordinaryWords)])
        #expect(analyze("Hej, spotkanie jutro o 10. Daj znać, czy pasuje.", "Dzień dobry, spotkanie jutro o 10. Daj znać, czy pasuje.")
            .skipped.map(\.reason) == [.ordinaryWords])
        #expect(analyze("Ala ma kota", "Ala ma kota!").skipped.map(\.reason) == [.punctuation])
        #expect(analyze("Wrzucam to na supa bejs w piątek.", "Wrzucam to na Supabase w piątek.").skipped.isEmpty)
    }

    // MARK: - "Popraw"

    private func manual(_ original: String, _ corrected: String) -> ManualVerdict {
        CorrectionLearner.manual(original: original, corrected: corrected, isRealWord: Self.isRealWord)
    }

    @Test func manualFixOfASelectedTermIsLearned() {
        #expect(manual("supa bejs", "Supabase") == .terms([TermCorrection(misheard: "supa bejs", correct: "Supabase")]))
        #expect(manual(" hanczo ", "honcho") == .terms([TermCorrection(misheard: "hanczo", correct: "honcho")]))
    }

    @Test func manualFixOfSoundAlikeOrdinaryWordsIsLearned() {
        // The watcher never guesses these; "Popraw" says outright the word was misheard.
        #expect(manual("ma", "na") == .terms([TermCorrection(misheard: "ma", correct: "na")]))
    }

    @Test func manualGrammarOrOtherWordsIsARewrite() {
        #expect(manual("piątek", "piątku") == .rewrite)
        #expect(manual("spotkanie", "jutro") == .rewrite)
        #expect(manual("Wrzucam to na supa bejs w piątek.", "Całkiem inny tekst o czymś zupełnie innym tutaj.") == .rewrite)
    }

    @Test func manualCaseFixNeedsAName() {
        #expect(manual("jutro", "Jutro") == .rewrite)
        #expect(manual("supabase", "Supabase") == .terms([TermCorrection(misheard: "supabase", correct: "Supabase")]))
        #expect(manual("ok", "OK") == .terms([TermCorrection(misheard: "ok", correct: "OK")]))
    }

    @Test func manualFixInsideALongerSelectionFindsTheTerm() {
        #expect(manual("Wrzucam to na supa bejs w piątek.", "Wrzucam to na Supabase w piątek.")
            == .terms([TermCorrection(misheard: "supa bejs", correct: "Supabase")]))
    }

    @Test func manualUnchangedTeachesNothing() {
        #expect(manual("Ala ma kota", "Ala ma kota ") == .unchanged)
    }

    @Test func inflectionNeedsAStemOfFiveLetters() {
        #expect(CorrectionLearner.isInflection("piątek", "piątku"))
        #expect(CorrectionLearner.isInflection("spotkanie", "spotkania"))
        #expect(!CorrectionLearner.isInflection("może", "morze"))
        #expect(!CorrectionLearner.isInflection("kot", "kod"))
    }

    @Test func sameWordHandlesInflectionAndCase() {
        #expect(CorrectionLearner.isSameWord("Figmę", "Figma"))
        #expect(CorrectionLearner.isSameWord("Brzęk", "BRZĘK"))
        #expect(!CorrectionLearner.isSameWord("Honho", "Honcho"))
        #expect(!CorrectionLearner.isSameWord("kot", "kod"))
    }
}
