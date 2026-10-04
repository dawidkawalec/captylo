import SwiftUI

/// "3 osoby" at the end of the meta line in the meeting details, with the names from the
/// calendar in a tooltip. The count forms follow the Polish rules in code (1 osoba, 2-4 osoby,
/// 5+ and 12-14 osób), one catalog key per form, so the label reads the same under every UI
/// language and in the tests.
@MainActor
struct MeetingParticipantsLabel: View {
    let participants: [String]

    var body: some View {
        Text(verbatim: Self.text(count: participants.count))
            .help(Text(verbatim: Self.tooltip(participants)))
            .accessibilityLabel(Text(verbatim: Self.tooltip(participants)))
    }

    nonisolated static func text(count: Int) -> String {
        if count == 1 {
            return String(localized: "1 osoba")
        }
        let last = count % 10
        let lastTwo = count % 100
        if (2...4).contains(last), !(12...14).contains(lastTwo) {
            return String(localized: "\(count) osoby")
        }
        return String(localized: "\(count) osób")
    }

    /// "Uczestnicy: Anna Kowalska, Piotr Nowak" (the export's line, reused).
    nonisolated static func tooltip(_ names: [String]) -> String {
        String(localized: "Uczestnicy: \(names.joined(separator: ", "))")
    }
}
