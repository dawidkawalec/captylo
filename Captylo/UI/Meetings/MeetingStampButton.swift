import SwiftUI

/// `[12:34]` as a button (the transcript lines, the AI notes citations): tertiary like a plain
/// stamp, Glacier with a play glyph on hover.
@MainActor
struct MeetingStampButton: View {
    let stamp: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: stamp)
                    .font(GlassFont.ui(12, .medium).monospacedDigit())
                Image(systemName: "play.fill")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isHovered ? GlassColor.highlight : GlassColor.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(Text("Odtwórz od tej chwili"))
        .accessibilityLabel(Text("Odtwórz od \(stamp)"))
    }
}
