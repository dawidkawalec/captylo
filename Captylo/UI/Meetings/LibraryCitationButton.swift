import SwiftUI

/// A `[S1 12:34]` citation of a "Zapytaj wszystkie spotkania" answer as a button ("S1 12:34"):
/// tertiary like a transcript stamp, Glacier with an arrow on hover. The click opens that
/// meeting's transcript at that moment.
@MainActor
struct LibraryCitationButton: View {
    let label: String
    /// The meeting's title, for the tooltip and VoiceOver.
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: label)
                    .font(GlassFont.ui(12, .medium).monospacedDigit())
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isHovered ? GlassColor.highlight : GlassColor.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(Text("Otwórz „\(title)” w tym miejscu"))
        .accessibilityLabel(Text("Otwórz „\(title)”, \(label)"))
    }
}
