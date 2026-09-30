import SwiftUI

/// The frosted glass orb of the welcome screen (the recorder orb of mockup 01, scaled up): a clear
/// glass bubble with a bright rim and an inner highlight, a warm glow behind it and the white
/// Captylo symbol inside.
@MainActor
struct OnboardingOrb: View {
    var size: CGFloat = 132

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .glassSurface(.clear, in: Circle(), tint: Color.white.opacity(0.16))
            .overlay { highlight }
            .overlay { rim }
            .overlay {
                OnboardingBrandMark()
                    .frame(width: size * 0.56, height: size * 0.56)
                    .shadow(color: Color.black.opacity(0.25), radius: 6, y: 2)
            }
            .background { glow }
            .accessibilityHidden(true)
    }

    /// Soft light pooled in the upper left, like the bubble in the mockup.
    private var highlight: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(reduceTransparency ? 0.08 : 0.28), Color.white.opacity(0)],
                    center: UnitPoint(x: 0.34, y: 0.2),
                    startRadius: 0,
                    endRadius: size * 0.62
                )
            )
            .allowsHitTesting(false)
    }

    /// Second, brighter rim on top of the surface rim: the orb reads as a bubble, not a disc.
    private var rim: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.75), Color.white.opacity(0.15), Color.white.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.5
            )
            .allowsHitTesting(false)
    }

    /// Warm sunset glow bleeding out around the orb.
    private var glow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [VTColor.brandPink.opacity(0.45), VTColor.brandViolet.opacity(0.18), Color.clear],
                    center: .center,
                    startRadius: size * 0.3,
                    endRadius: size * 0.95
                )
            )
            .frame(width: size * 1.9, height: size * 1.9)
            .allowsHitTesting(false)
    }
}
