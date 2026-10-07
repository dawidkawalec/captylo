import SwiftUI

/// Under the Spotkania search: the notes the same search finds, as small glass capsules ("Także w
/// notatkach"); a click opens the note in Notatki.
@MainActor
struct NoteMatchesStrip: View {
    let notes: [NoteRecord]
    let onOpen: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Także w notatkach:")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(notes) { note in
                        Button {
                            onOpen(note.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: note.hasAudio ? "waveform" : MainSection.notatki.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(verbatim: note.displayTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: 220)
                            }
                        }
                        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                        .fixedSize()
                        .help(Text("Otwórz notatkę"))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Także w notatkach"))
    }
}
