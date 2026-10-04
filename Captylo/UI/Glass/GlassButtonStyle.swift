import SwiftUI

/// Buttons of the Dusk Glass language (mockup 03):
/// - `.neutral`: translucent white glass with a white label ("Pauza"),
/// - `.destructive`: red tinted glass with a soft red glow ("Zakończ"),
/// - `.accent`: brand violet glass for the primary action of a screen ("Dalej", "Pobierz").
/// Plain translucent fills on every macOS version (buttons sit on panels, and glass on glass
/// muddies); press = slight scale and brighter fill.
struct GlassButtonStyle: ButtonStyle {
    enum Kind: Sendable {
        case neutral
        case destructive
        case accent
    }

    enum Size: Sendable {
        /// 44 pt, the widget and onboarding footer buttons.
        case large
        /// 32 pt, inline actions in rows and panels.
        case small
    }

    enum Shape: Sendable {
        case roundedRectangle
        case capsule
    }

    var kind: Kind = .neutral
    var size: Size = .large
    var shape: Shape = .roundedRectangle
    /// Stretch to the available width (the "Pauza" / "Zakończ" pair).
    var fillsWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    /// Neutral large glass button.
    static var glass: GlassButtonStyle { GlassButtonStyle() }

    static func glass(
        _ kind: GlassButtonStyle.Kind,
        size: GlassButtonStyle.Size = .large,
        shape: GlassButtonStyle.Shape = .roundedRectangle,
        fillsWidth: Bool = false
    ) -> GlassButtonStyle {
        GlassButtonStyle(kind: kind, size: size, shape: shape, fillsWidth: fillsWidth)
    }
}

@MainActor
private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: GlassButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(style.size == .large ? GlassFont.button : GlassFont.button.weight(.medium))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.97 : 0.45))
            .labelStyle(GlassButtonLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, style.size == .large ? GlassTokens.Padding.controlHorizontal : 12)
            .frame(maxWidth: style.fillsWidth ? .infinity : nil)
            .frame(height: style.size == .large ? GlassTokens.Size.buttonHeight : GlassTokens.Size.buttonHeightSmall)
            .background { fill(pressed: pressed) }
            .overlay { rim }
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : GlassMotion.press, value: pressed)
            .onHover { isHovered = $0 }
    }

    private var shape: AnyShape {
        switch style.shape {
        case .roundedRectangle:
            let radius = style.size == .large ? GlassTokens.Radius.control : 10
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .capsule:
            return AnyShape(Capsule())
        }
    }

    @ViewBuilder
    private func fill(pressed: Bool) -> some View {
        let boost = (pressed ? 0.08 : 0) + (isHovered && isEnabled ? 0.04 : 0)
        switch style.kind {
        case .neutral:
            shape.fill(reduceTransparency ? GlassColor.solidPanel : Color.white.opacity(GlassTokens.Opacity.control + boost))
        case .destructive:
            tinted(top: GlassColor.destructive, bottom: GlassColor.destructiveDeep, boost: boost)
        case .accent:
            tinted(top: GlassColor.accent, bottom: GlassColor.accentDeep, boost: boost)
        }
    }

    private func tinted(top: Color, bottom: Color, boost: Double) -> some View {
        // "Zakończ" is a bright coral in mockup 03, nearly opaque; the violet accent stays glassier.
        let base = style.kind == .destructive ? 0.92 : 0.82
        let alpha = min((reduceTransparency ? 1 : base) + boost, 1)
        return shape
            .fill(LinearGradient(colors: [top.opacity(alpha), bottom.opacity(alpha)], startPoint: .top, endPoint: .bottom))
            .shadow(color: top.opacity(isEnabled ? 0.55 : 0), radius: GlassTokens.Shadow.glowRadius, y: 4)
            .saturation(isEnabled ? 1 : 0.3)
    }

    private var rim: some View {
        let top = style.kind == .neutral ? 0.32 : 0.45
        let bottom = style.kind == .neutral ? 0.06 : 0.1
        return shape
            .stroke(GlassColor.rim(top: top, bottom: bottom), lineWidth: GlassTokens.Size.rimWidth)
            .allowsHitTesting(false)
    }
}

/// Icon and title with the mockup spacing ("⏸  Pauza").
private struct GlassButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
            configuration.title
        }
    }
}
