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

    /// Oblique cases lose their ending, so "o budżecie" finds "budżet" and "budżetu", "o
    /// ofercie" finds "ofertę", "o cenach" finds "ceny".
    @Test func stemDropsPolishCaseEndings() {
        #expect(SearchQuery.stem("budzecie") == "budze")
        #expect(SearchQuery.stem("ofercie") == "ofer")
        #expect(SearchQuery.stem("kliencie") == "klien")
        #expect(SearchQuery.stem("cenie") == "cen")
        #expect(SearchQuery.stem("umowie") == "umow")
        #expect(SearchQuery.stem("planie") == "plan")
        #expect(SearchQuery.stem("terminie") == "termin")
        #expect(SearchQuery.stem("cenach") == "cen")
        #expect(SearchQuery.stem("kosztach") == "koszt")
        #expect(SearchQuery.stem("ofertach") == "ofert")
        #expect(SearchQuery.stem("cenami") == "cen")
        #expect(SearchQuery.stem("klientom") == "klient")
        #expect(SearchQuery.stem("klientow") == "klient")
        #expect(SearchQuery.stem("planem") == "plan")
        #expect(SearchQuery.stem("harmonogramie") == "harmon")
        // Never under 3 characters: a shorter ending is tried, then the plain cut.
        #expect(SearchQuery.stem("zycie") == "zyc")
        #expect(SearchQuery.stem("dach") == "dach")
        #expect(SearchQuery.stem("nie") == "nie")
    }

    /// A 4-letter word ending in a vowel drops it ("cena" finds "ceny", "Anna" finds "Anny");
    /// others stay whole ("lodz").
    @Test func fourLetterWordsDropAFinalVowel() {
        #expect(SearchQuery.stem("cena") == "cen")
        #expect(SearchQuery.stem("anna") == "ann")
        #expect(SearchQuery.stem("lodz") == "lodz")
        #expect(SearchQuery.stem("plan") == "plan")
        #expect(SearchQuery.stem("rok") == "rok")
    }

    @Test func matchQuotesEveryTerm() {
        #expect(SearchQuery.match(["ofert", "jutr"], all: true) == "\"ofert\" AND \"jutr\"")
        #expect(SearchQuery.match(["ofert", "jutr"], all: false) == "\"ofert\" OR \"jutr\"")
        #expect(SearchQuery.match(["a\"b"], all: true) == "\"a\"\"b\"")
    }
}
