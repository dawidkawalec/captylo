import SwiftUI

/// Rounded glass square holding an SF Symbol: section and tile icons, onboarding step icons.
/// `tint` colors the square (brand violet, peach...) while the glyph stays white.
@MainActor
struct GlassIconBadge: View {
    var systemImage: String
    var size: CGFloat
    var tint: Color?

    init(systemImage: String, size: CGFloat = 32, tint: Color? = nil) {
        self.systemImage = systemImage
        self.size = size
        self.tint = tint
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * GlassTokens.Radius.iconBadgeFraction, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: size, height: size)
            .background {
                if let tint {
                    // Muted: nothing in the mockups is saturated besides the red dot and "Zakończ".
                    shape.fill(
                        LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    )
                } else {
                    shape.fill(Color.white.opacity(GlassTokens.Opacity.control))
                }
            }
            .overlay {
                shape.strokeBorder(GlassColor.rim(top: 0.45, bottom: 0.08), lineWidth: GlassTokens.Size.rimWidth)
            }
            .accessibilityHidden(true)
    }
}
