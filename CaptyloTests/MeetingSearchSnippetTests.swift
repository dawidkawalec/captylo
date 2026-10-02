import Foundation
import Testing
@testable import Captylo

/// The text under a search hit: about 80 characters around the first match, the matched words
/// bold, an ellipsis where the text was cut.
struct MeetingSearchSnippetTests {
    private static func bold(_ snippet: MeetingSearchSnippet) -> [String] {
        let characters = Array(snippet.text)
        return snippet.matches.map { String(characters[$0]) }
    }

    private static let filler = "Na początku omawialiśmy sprawy organizacyjne zespołu i plan na kolejny tydzień pracy"

    @Test func aMatchInTheMiddleIsCutOnBothSides() throws {
        let text = Self.filler + ", potem ustaliliśmy, że wyślę ofertę jutro rano do klienta, a na końcu " + Self.filler
        let snippet = MeetingSearchSnippet.make(text, terms: ["ofert"])
        #expect(snippet.text.hasPrefix(MeetingSearchSnippet.ellipsis))
        #expect(snippet.text.hasSuffix(MeetingSearchSnippet.ellipsis))
        #expect(Self.bold(snippet) == ["ofertę"])
        #expect(snippet.text.contains("wyślę ofertę jutro"))
        #expect(snippet.text.count <= MeetingSearchSnippet.defaultLength + 2)
    }

    @Test func aMatchAtTheStartKeepsTheStart() {
        let text = "Oferta jest gotowa. " + Self.filler + " " + Self.filler
        let snippet = MeetingSearchSnippet.make(text, terms: ["ofert"])
        #expect(snippet.text.hasPrefix("Oferta jest gotowa."))
        #expect(snippet.text.hasSuffix(MeetingSearchSnippet.ellipsis))
        #expect(snippet.matches == [0..<6])
    }

    @Test func aMatchAtTheEndKeepsTheEnd() {
        let text = Self.filler + " " + Self.filler + ", a na koniec wyślę ofertę."
        let snippet = MeetingSearchSnippet.make(text, terms: ["ofert"])
        #expect(snippet.text.hasPrefix(MeetingSearchSnippet.ellipsis))
        #expect(snippet.text.hasSuffix("wyślę ofertę."))
        #expect(Self.bold(snippet) == ["ofertę"])
    }

    @Test func shortTextStaysWholeWithoutEllipses() {
        let snippet = MeetingSearchSnippet.make("Wyślę ofertę jutro", terms: ["ofert"])
        #expect(snippet.text == "Wyślę ofertę jutro")
        #expect(Self.bold(snippet) == ["ofertę"])
    }

    @Test func polishLettersMatchTheirFoldedTerms() {
        #expect(Self.bold(MeetingSearchSnippet.make("Zarząd zdecyduje w piątek", terms: ["zarzad"])) == ["Zarząd"])
        #expect(Self.bold(MeetingSearchSnippet.make("Jutro jadę do Łodzi i do Łódź Fabryczna", terms: ["lodz"])) == ["Łodzi", "Łódź"])
        #expect(Self.bold(MeetingSearchSnippet.make("BUDŻETU nie ruszamy", terms: ["budzet"])) == ["BUDŻETU"])
    }

    @Test func everyWordOfTheQueryIsBold() {
        let snippet = MeetingSearchSnippet.make("Wyślę ofertę jutro rano, a jutro po południu zadzwonię.", terms: ["ofert", "jutro"])
        #expect(Self.bold(snippet) == ["ofertę", "jutro", "jutro"])
    }

    @Test func theLengthIsCapped() {
        let long = String(repeating: "słowo ", count: 200) + "budżet " + String(repeating: "inne ", count: 200)
        let snippet = MeetingSearchSnippet.make(long, terms: ["budzet"], length: 80)
        #expect(snippet.text.count <= 82)
        #expect(Self.bold(snippet) == ["budżet"])
        // Cut at word ends: no word is broken at either side.
        let inner = snippet.text.trimmingCharacters(in: CharacterSet(charactersIn: MeetingSearchSnippet.ellipsis))
        #expect(inner.split(separator: " ").allSatisfy { ["słowo", "budżet", "inne"].contains(String($0)) })
    }

    @Test func lineBreaksBecomeSpaces() {
        let snippet = MeetingSearchSnippet.make("kreacje:\n3 warianty\n\ndo środy", terms: ["warian"])
        #expect(snippet.text == "kreacje: 3 warianty do środy")
        #expect(Self.bold(snippet) == ["warianty"])
    }

    @Test func noMatchShowsTheStart() {
        let snippet = MeetingSearchSnippet.make(Self.filler + " " + Self.filler, terms: ["ofert"])
        #expect(snippet.matches.isEmpty)
        #expect(snippet.text.hasPrefix("Na początku"))
        #expect(snippet.text.hasSuffix(MeetingSearchSnippet.ellipsis))
    }

    @Test func theAttributedTextMarksOnlyTheMatches() {
        let snippet = MeetingSearchSnippet.make("Wyślę ofertę jutro", terms: ["ofert"])
        let strong = snippet.attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(snippet.attributed[$0.range].characters) }
        #expect(strong == ["ofertę"])
        #expect(String(snippet.attributed.characters) == "Wyślę ofertę jutro")
    }
}
