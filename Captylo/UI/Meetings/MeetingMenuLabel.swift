import SwiftUI

/// Neutral glass capsule that opens a menu ("Eksportuj", the AI notes template), like
/// "Przetwórz przez AI" in Historia.
@MainActor
struct MeetingMenuLabel: View {
    let title: Text
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            title
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .font(GlassFont.button.weight(.medium))
        .foregroundStyle(Color.white.opacity(isEnabled ? 0.97 : 0.55))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: GlassTokens.Size.buttonHeightSmall)
        .background {
            Capsule().fill(Color.white.opacity(GlassTokens.Opacity.control + (isHovered && isEnabled ? 0.04 : 0)))
        }
        .overlay {
            Capsule().stroke(GlassColor.rim(top: 0.32, bottom: 0.06), lineWidth: GlassTokens.Size.rimWidth)
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
    }
}
