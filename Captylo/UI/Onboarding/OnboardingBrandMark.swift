import SwiftUI

/// The white Captylo symbol (Brand Direction 01: the heavy round C with the diagonal cut),
/// drawn from the vector asset `BrandSymbol` (branding/direction-01/symbol-white.svg).
@MainActor
struct OnboardingBrandMark: View {
    var body: some View {
        Image("BrandSymbol")
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// The white "captylo" wordmark from the vector asset `BrandWordmark`
/// (branding/direction-01/wordmark-white.svg), sized by its height.
@MainActor
struct BrandWordmark: View {
    var height: CGFloat

    /// Width / height of the wordmark's view box (3317 x 867 design units).
    static let aspectRatio: CGFloat = 3317 / 867

    var body: some View {
        Image("BrandWordmark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .frame(height: height)
            .accessibilityLabel(Text(verbatim: "Captylo"))
    }
}
