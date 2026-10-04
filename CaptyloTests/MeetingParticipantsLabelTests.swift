import Foundation
import Testing
@testable import Captylo

/// "· 3 osoby" in the meeting details: the Polish count forms are picked in code, so they hold
/// whatever language the test host runs in.
struct MeetingParticipantsLabelTests {
    @Test func countTakesThePolishPluralForm() {
        #expect(MeetingParticipantsLabel.text(count: 1) == String(localized: "1 osoba"))
        for count in [2, 3, 4, 22, 23, 24, 102] {
            #expect(MeetingParticipantsLabel.text(count: count) == String(localized: "\(count) osoby"), "\(count)")
        }
        for count in [0, 5, 9, 10, 11, 12, 13, 14, 15, 20, 21, 25, 100, 112] {
            #expect(MeetingParticipantsLabel.text(count: count) == String(localized: "\(count) osób"), "\(count)")
        }
    }

    @Test func tooltipListsTheNamesInOrder() {
        let names = ["Anna Kowalska", "Piotr Nowak", "Ola"]
        #expect(MeetingParticipantsLabel.tooltip(names) == String(localized: "Uczestnicy: \(names.joined(separator: ", "))"))
    }
}
