import SwiftUI

/// "Nagraj spotkanie", the one accent action of Spotkania (header and empty state); while a
/// meeting records it turns into "Zakończ spotkanie" in Record red. A nil `action` shows it
/// disabled (a start or a stop is running).
@MainActor
struct MeetingRecordButton: View {
    var isRecording = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if isRecording {
                Button {
                    action?()
                } label: {
                    Label("Zakończ spotkanie", systemImage: "stop.fill")
                }
                .buttonStyle(.glass(.destructive, size: .small, shape: .capsule))
            } else {
                Button {
                    action?()
                } label: {
                    Label("Nagraj spotkanie", systemImage: "record.circle")
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            }
        }
        .disabled(action == nil)
    }
}
