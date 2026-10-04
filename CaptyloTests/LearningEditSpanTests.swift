import Foundation
import Testing
@testable import Captylo

struct LearningEditSpanTests {
    private let delivered = "Wrzucam to na supa bejs w piątek."

    @Test func pasteIntoAnEmptyFieldIsFound() throws {
        let after = delivered + " "
        let range = try #require(EditSpan.locate(delivered: delivered, before: "", after: after))
        #expect((after as NSString).substring(with: range) == delivered)
    }

    @Test func pasteInTheMiddleKeepsItsNeighbours() throws {
        let before = "Cześć Ola,\n\nPozdrawiam"
        let after = "Cześć Ola,\n\(delivered)\nPozdrawiam"
        let range = try #require(EditSpan.locate(delivered: delivered, before: before, after: after))
        let anchor = EditSpan.anchor(in: after, paste: range)
        #expect(anchor.prefix == "Cześć Ola,\n")
        #expect(anchor.suffix == "\nPozdrawiam")

        let edited = "Cześć Ola,\nWrzucam to na Supabase w piątek.\nPozdrawiam"
        #expect(EditSpan.extract(from: edited, anchor: anchor) == "Wrzucam to na Supabase w piątek.")
    }

    @Test func textTypedAfterAPasteAtTheEndStaysInTheSpan() throws {
        let after = "Notatka: " + delivered
        let range = try #require(EditSpan.locate(delivered: delivered, before: "Notatka: ", after: after))
        let anchor = EditSpan.anchor(in: after, paste: range)
        let edited = "Notatka: Wrzucam to na Supabase w piątek. I jeszcze coś."
        // The learner drops the trailing continuation itself.
        #expect(EditSpan.extract(from: edited, anchor: anchor) == "Wrzucam to na Supabase w piątek. I jeszcze coś.")
    }

    @Test func editedNeighbourGivesUp() throws {
        let after = "Start " + delivered + " Koniec"
        let range = try #require(EditSpan.locate(delivered: delivered, before: "Start  Koniec", after: after))
        let anchor = EditSpan.anchor(in: after, paste: range)
        #expect(EditSpan.extract(from: "Zupełnie inny tekst", anchor: anchor) == nil)
    }

    @Test func pasteThatReplacedASelectionIsFound() throws {
        let before = "Ala ma ZAZNACZENIE kota"
        let after = "Ala ma \(delivered) kota"
        let range = try #require(EditSpan.locate(delivered: delivered, before: before, after: after))
        #expect((after as NSString).substring(with: range) == delivered)
    }

    @Test func textTheAppChangedOnPasteIsNotFound() {
        #expect(EditSpan.locate(delivered: delivered, before: "", after: "coś zupełnie innego") == nil)
    }

    @Test func emojiAndPolishLettersUseUTF16Offsets() throws {
        let before = "👋 Hej "
        let after = before + delivered
        let range = try #require(EditSpan.locate(delivered: delivered, before: before, after: after))
        #expect(range.location == (before as NSString).length)
        let anchor = EditSpan.anchor(in: after, paste: range)
        #expect(EditSpan.extract(from: "👋 Hej Wrzucam to na Supabase w piątek.", anchor: anchor) == "Wrzucam to na Supabase w piątek.")
    }
}
