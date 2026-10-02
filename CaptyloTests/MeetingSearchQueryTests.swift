import Foundation
import Testing
@testable import Captylo

struct MeetingSearchQueryTests {
    @Test func termsAreFoldedAndStemmed() {
        #expect(SearchQuery.terms("Oferta") == ["ofert"])
        #expect(SearchQuery.terms("ZARZĄD") == ["zarza"])
        #expect(SearchQuery.terms("Łódź") == ["lodz"])
        #expect(SearchQuery.terms("budżetu") == ["budzet"])
        #expect(SearchQuery.terms("spotkania") == ["spotka"])
        #expect(SearchQuery.terms("umowa") == ["umow"])
        #expect(SearchQuery.terms("rok") == ["rok"])
    }

    @Test func shortWordsAreDroppedAndAllShortGivesNil() {
        #expect(SearchQuery.terms("ab") == nil)
        #expect(SearchQuery.terms("a b c") == nil)
        #expect(SearchQuery.terms("  ") == nil)
        #expect(SearchQuery.terms("") == nil)
        #expect(SearchQuery.terms("Q4 oferta") == ["ofert"])
    }

    @Test func repeatsAreDroppedAndOrderKept() {
        #expect(SearchQuery.terms("oferta jutro oferty") == ["ofert", "jutr"])
    }

    @Test func punctuationAndOperatorsSplitWords() {
        #expect(SearchQuery.terms("\"a\" OR b*") == nil)
        #expect(SearchQuery.terms("NEAR(oferta*, \"jutro\")") == ["near", "ofert", "jutr"])
        #expect(SearchQuery.terms("e-mail") == ["mail"])
        #expect(SearchQuery.terms("2026-10-02") == ["2026"])
    }

    @Test func stemKeepsShortWordsAndCutsLongOnes() {
        #expect(SearchQuery.stem("lodz") == "lodz")
        #expect(SearchQuery.stem("oferta") == "ofert")
        #expect(SearchQuery.stem("faktura") == "faktur")
        #expect(SearchQuery.stem("prezentacja") == "prezen")
    }

    @Test func matchQuotesEveryTerm() {
        #expect(SearchQuery.match(["ofert", "jutr"], all: true) == "\"ofert\" AND \"jutr\"")
        #expect(SearchQuery.match(["ofert", "jutr"], all: false) == "\"ofert\" OR \"jutr\"")
        #expect(SearchQuery.match(["a\"b"], all: true) == "\"a\"\"b\"")
    }
}
