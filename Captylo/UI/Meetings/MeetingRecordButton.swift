import SwiftUI

/// "Nagraj spotkanie", the one accent action of Spotkania (header and empty state). A nil
/// `action` shows it disabled.
@MainActor
struct MeetingRecordButton: View {
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Label("Nagraj spotkanie", systemImage: "record.circle")
        }
        .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        .disabled(action == nil)
    }
}
