import SwiftUI

/// Slim glass capsule with a luminous brand-gradient fill: the step progress of the onboarding and
/// the model download progress. `fraction` is clamped to 0...1.
@MainActor
struct OnboardingProgressTrack: View {
    var fraction: Double
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            let width = max(height, proxy.size.width * clamped)
            ZStack(alignment: .leading) {
                Color.clear
                    .glassSurface(.track, in: Capsule(), shadow: false)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [VTColor.brandViolet, VTColor.brandPink, VTColor.brandOrange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        // Glossy top edge.
                        Capsule()
                            .fill(LinearGradient(colors: [Color.white.opacity(0.45), Color.clear], startPoint: .top, endPoint: .center))
                    }
                    .frame(width: width)
                    .shadow(color: VTColor.brandPink.opacity(0.7), radius: 6)
                    .opacity(clamped > 0 ? 1 : 0)
                    .animation(reduceMotion ? nil : GlassMotion.spring, value: clamped)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
