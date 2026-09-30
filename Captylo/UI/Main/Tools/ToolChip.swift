import SwiftUI

/// Removable glass pill for vocabulary and filler words: translucent white capsule with a rim,
/// white label and a small x that brightens on hover.
@MainActor
struct ToolChip: View {
    let text: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .font(GlassFont.ui(13, .medium))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHovered ? GlassColor.textPrimary : GlassColor.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(isHovered ? 0.22 : 0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Usuń \(text)"))
            .accessibilityLabel(Text("Usuń \(text)"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
        .glassSurface(.control, in: Capsule(), shadow: false)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
    }
}
