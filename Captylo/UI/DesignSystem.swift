import SwiftUI

// Design tokens from the mockups (brief 3.2). No ad-hoc hex colors in views.

// MARK: - Colors

enum VTColor {
    // Deep Tide (the owner's pick over Brand Direction 01's Iris, branding/direction-01):
    // Abyss and Petrol as the depth, Glacier as the light, Fog as haze, Salt as white,
    // Record only for recording.
    static let abyss = Color(hex: 0x10272C)
    static let petrol = Color(hex: 0x214A52)
    static let glacier = Color(hex: 0x9FE6DC)
    static let fog = Color(hex: 0xB7CCCB)
    static let salt = Color(hex: 0xF2F7F4)
    static let record = Color(hex: 0xF27878)
    /// Glacier is too light to carry white type, so accent fills (buttons, switches) use this
    /// deeper teal between Petrol and Glacier.
    static let tide = Color(hex: 0x2F8F88)

    // Older role names, now mapped onto Deep Tide so every view follows it.
    static let brandViolet = tide
    static let brandPink = fog
    static let brandOrange = glacier
    static let recordRed = record
    static let brandNight = abyss
    static let brandIndigo = petrol

    /// 0.5 pt stroke around glass surfaces.
    static let glassStroke = Color.white.opacity(0.35)
    static let textOnGlass = Color.white.opacity(0.95)
    static let textOnGlassSecondary = Color.white.opacity(0.7)
    /// Extra tint when white text fails contrast over bright wallpapers.
    static let glassContrastTint = Color.black.opacity(0.12)
    /// Opaque surface used when Reduce Transparency is on.
    static let glassSolidFallback = Color(red: 0.11, green: 0.11, blue: 0.13)

    /// Brand gradient: Abyss (top) -> Petrol -> Tide -> Glacier (bottom).
    static var brandGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: abyss, location: 0),
                .init(color: petrol, location: 0.4),
                .init(color: tide, location: 0.75),
                .init(color: glacier, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Waveform bar gradient: white on top, Fog at the bottom.
    static var waveformGradient: LinearGradient {
        LinearGradient(colors: [.white, brandPink], startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Spacing, radii, sizes

enum VTSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Same values as `GlassTokens.Radius` (docs/design/dusk-glass.md), kept for the widget code.
enum VTRadius {
    /// Compact bar, continuous corners.
    static let compactBar: CGFloat = GlassTokens.Radius.panel
    /// Live transcript card.
    static let card: CGFloat = GlassTokens.Radius.card
    /// Drawer buttons ("Pauza", "Zakończ") and toasts.
    static let button: CGFloat = GlassTokens.Radius.control
}

enum VTSize {
    static let compactBar = CGSize(width: 340, height: 72)
    static let orb: CGFloat = 56
    static let micGlyph: CGFloat = 22
    static let recordDot: CGFloat = 9
    static let liveCardWidth: CGFloat = 340
    static let liveCardTextHeight: CGFloat = 58
    /// Largest widget state + 24 pt shadow margin; content is bottom-anchored inside it.
    static let panelCanvas = CGSize(width: 388, height: 480)
    static let shadowMargin: CGFloat = 24
    static let drawerRowHeight: CGFloat = 32
    static let drawerButtonHeight: CGFloat = 40
    static let waveformBars = 21
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarGap: CGFloat = 4
    static let waveformBarMinHeight: CGFloat = 3
    static let waveformBarMaxHeight: CGFloat = 34
    static let mainWindowMin = CGSize(width: 920, height: 640)
}

// MARK: - Typography

/// Widget type, on the Brand Direction 01 faces (`GlassFont`).
enum VTFont {
    static var timer: Font { GlassFont.face(.manropeSemiBold, 20).monospacedDigit() }
    static var status: Font { GlassFont.face(.interRegular, 12) }
    static var cardHeader: Font { GlassFont.face(.interSemiBold, 12) }
    static var cardText: Font { GlassFont.face(.interRegular, 13) }
    static var drawerRow: Font { GlassFont.face(.interRegular, 13) }
    static var wordmark: Font { GlassFont.face(.manropeExtraBold, 34) }
}

// MARK: - Motion

enum VTMotion {
    /// Widget in: opacity 0 -> 1 + scale 0.96 -> 1.
    static var widgetIn: Animation { .spring(response: 0.35, dampingFraction: 0.85) }
    /// Width / height changes inside the panel.
    static var resize: Animation { .spring(response: 0.4, dampingFraction: 0.85) }
    static var drawer: Animation { .spring(response: 0.25, dampingFraction: 0.85) }
    static let widgetOutDuration: TimeInterval = 0.15
    static let toastFadeIn: TimeInterval = 0.3
    static let toastFadeOut: TimeInterval = 0.2
    static let recordDotPulsePeriod: TimeInterval = 1.2
    static let onboardingStepDuration: TimeInterval = 0.22
}

// MARK: - Glass

/// Liquid Glass on macOS 26, `.ultraThinMaterial` + 0.5 pt white stroke below, solid fill
/// when Reduce Transparency is on (gotcha 56). Legacy widget surface: new UI uses the Dusk
/// Glass components in `UI/Glass/` (`glassSurface`, `GlassPanel`, ...), see docs/design/dusk-glass.md.
@MainActor
struct VTGlassBackground<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(VTColor.glassSolidFallback, in: shape)
                .overlay(shape.fill(tint ?? .clear))
                .overlay(shape.stroke(VTColor.glassStroke, lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint ?? .clear))
                .overlay(shape.stroke(VTColor.glassStroke, lineWidth: 0.5))
        }
    }
}

extension View {
    /// Glass surface with the platform fallbacks. `interactive` enables the press response on macOS 26.
    func vtGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(VTGlassBackground(shape: shape, tint: tint, interactive: interactive))
    }
}
