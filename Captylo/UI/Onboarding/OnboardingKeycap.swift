import SwiftUI

/// The recording shortcut drawn as a flat key label: a faint fill, a hairline rim and small
/// rounded corners, so it reads as a key to press on the keyboard and never as a button to click
/// (a glass capsule here looked exactly like one). Not interactive.
@MainActor
struct OnboardingKeycap: View {
    var keyName: String
    var height: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.26, style: .continuous)
        Text(verbatim: keyName)
            .font(GlassFont.ui(height * 0.5, .semibold))
            .foregroundStyle(GlassColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, height * 0.34)
            .frame(minWidth: height * 1.4)
            .frame(height: height)
            .background { shape.fill(Color.white.opacity(0.06)) }
            .overlay {
                // Bottom edge a touch brighter: a key cap, not a raised glass button.
                shape.strokeBorder(GlassColor.rim(top: 0.22, bottom: 0.2), lineWidth: 1)
            }
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Skrót nagrywania"))
            .accessibilityValue(Text(verbatim: keyName))
    }
}
