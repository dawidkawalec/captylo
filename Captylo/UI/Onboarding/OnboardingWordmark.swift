import SwiftUI

/// The glass orb with the symbol over the white "captylo" wordmark (Brand Direction 01, both
/// vector assets). The tagline and the rest of the welcome copy live in `WelcomeStep`.
@MainActor
struct OnboardingWordmark: View {
    var orbSize: CGFloat = 132

    var body: some View {
        VStack(spacing: 22) {
            OnboardingOrb(size: orbSize)
            BrandWordmark(height: 50)
                .shadow(color: Color.black.opacity(0.25), radius: 10, y: 2)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
