import Testing
@testable import Captylo

struct LearningTokenDiffTests {
    @Test func identicalTextsAreOneEqualHunk() throws {
        let hunks = try #require(TokenDiff.hunks(from: "Ala ma kota", to: "Ala ma kota"))
        #expect(hunks == [.equal(["Ala", "ma", "kota"])])
    }

    @Test func replacedPhraseIsOneChange() throws {
        let hunks = try #require(TokenDiff.hunks(
            from: "Wrzucam to na supa bejs w piątek.",
            to: "Wrzucam to na Supabase w piątek."
        ))
        #expect(hunks == [
            .equal(["Wrzucam", "to", "na"]),
            .change(old: ["supa", "bejs"], new: ["Supabase"]),
            .equal(["w", "piątek."]),
        ])
    }

    @Test func caseOrPunctuationChangeOfOneWordIsAChange() throws {
        let hunks = try #require(TokenDiff.hunks(from: "wdrażamy honcho dziś", to: "wdrażamy Honcho dziś"))
        #expect(hunks == [.equal(["wdrażamy"]), .change(old: ["honcho"], new: ["Honcho"]), .equal(["dziś"])])
    }

    @Test func similarityCountsCaseFixesAsKept() throws {
        let hunks = try #require(TokenDiff.hunks(from: "a b c d", to: "a B c x"))
        #expect(TokenDiff.similarity(hunks, oldCount: 4, newCount: 4) == 0.75)
    }

    @Test func keyStripsPunctuationAndQuotes() {
        #expect(TokenDiff.key("„Supabase,”") == "supabase")
    }

    @Test func tooLongTextsAreNotAligned() {
        let long = Array(repeating: "słowo", count: TokenDiff.maxWords + 1).joined(separator: " ")
        #expect(TokenDiff.hunks(from: long, to: "krótko") == nil)
    }
}
