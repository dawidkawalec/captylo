import SwiftUI

/// The one soft dark cloud behind the free-floating marks of the compact widget (mockup 01 has
/// no container, and over a white app the white bars and the light timer nearly vanish). A
/// single wide shape under the waveform, the timer and the status line together, blurred until
/// it has no edge: over a dark desktop it only deepens what is already there, over white it
/// gives the marks a soft grey bed. Never two clouds (they read as smudges), never a box.
/// Works together with `glassFloatingHalo()`, which outlines each mark.
@MainActor
struct RecorderBackdropHalo: View {
    /// The shape in the compact row's coordinates, `RecorderMetrics.compactHaloRect`.
    let rect: CGRect

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Capsule(style: .continuous)
            // Reduce Transparency: a touch denser, so the marks keep their contrast without
            // relying on the soft falloff.
            .fill(Color.black.opacity(min(1, RecorderMetrics.backdropOpacity * (reduceTransparency ? 1.4 : 1))))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .blur(radius: RecorderMetrics.backdropBlur)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
