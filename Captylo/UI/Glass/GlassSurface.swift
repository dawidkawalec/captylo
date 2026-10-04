import SwiftUI

/// What a glass surface is, which decides how it is drawn.
enum GlassSurfaceKind: Sendable {
    /// Real frosted glass over the wallpaper: Liquid Glass on macOS 26, material + white fill +
    /// gradient rim below. Panels, the sidebar, stat tiles, the widget header.
    case panel
    /// Clearer glass (macOS 26 `Glass.clear`) for small elements floating on the wallpaper.
    case clear
    /// Inset card inside a panel: a slightly lighter block with a faint rim, no material
    /// (glass does not sample glass well, so nested surfaces are plain translucent fills).
    case card
    /// Lighter raised card inside a panel (tiles or grouped rows that should pop, not recess).
    case raised
    /// Neutral control fill ("Pauza", unselected chips).
    case control
    /// Recessed track behind segmented pickers and text fields.
    case track
}

/// Draws a Dusk Glass surface behind the content, clipped to `shape`.
/// Reduce Transparency swaps every kind for a solid dusk fill with the same rim.
@MainActor
struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// "Przydymienie paneli": the Abyss wash over every frosted panel.
    @Environment(\.windowTone) private var tone

    var shape: S
    var kind: GlassSurfaceKind
    var tint: Color?
    var shadow: Bool

    func body(content: Content) -> some View {
        // The shadow belongs to the surface only, never to the text on it.
        content
            .background {
                background
                    .shadow(color: .black.opacity(shadow ? shadowOpacity : 0), radius: shadowRadius, y: shadowY)
            }
            .overlay { rim.allowsHitTesting(false) }
    }

    // MARK: Fill

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            shape.fill(solidFill)
                .overlay { tint.map { shape.fill($0.opacity(0.35)) } }
        } else {
            switch kind {
            case .panel, .clear:
                frosted
            case .card:
                // A faint lift, not a recess: the transcript card of mockup 03 is a touch
                // lighter than its panel.
                shape.fill(Color.white.opacity(GlassTokens.Opacity.cardFill))
                    .overlay { tint.map { shape.fill($0.opacity(0.18)) } }
            case .raised:
                shape.fill(Color.white.opacity(GlassTokens.Opacity.fill))
                    .overlay { tint.map { shape.fill($0.opacity(0.18)) } }
            case .control:
                shape.fill(Color.white.opacity(GlassTokens.Opacity.control))
                    .overlay { tint.map { shape.fill($0) } }
            case .track:
                shape.fill(Color.black.opacity(GlassTokens.Opacity.track))
                    .overlay { shape.fill(Color.white.opacity(GlassTokens.Opacity.trackLift)) }
            }
        }
    }

    /// Every window background gets the same clear frosted glass (Brand Direction 01, "Czyste").
    @ViewBuilder
    private var frosted: some View {
        if #available(macOS 26.0, *), !GlassTokens.forcesFallback {
            let wash = kind == .clear ? GlassTokens.Opacity.glassTintClear : GlassTokens.Opacity.glassTint
            // Mockup 03 is a milky lift above the wallpaper. Dark `Glass.regular` (the windows
            // force a dark scheme) darkens it into a smoky brown and ignores a white tint, and
            // light-scheme glass overshoots until white type loses its contrast. So the base is
            // the clear variant (blur and edge light, no darkening) with a plain white wash on it.
            Color.clear
                .glassEffect(tint.map { Glass.clear.tint($0) } ?? .clear, in: shape)
                .overlay { shape.fill(Color.white.opacity(wash)).allowsHitTesting(false) }
                .overlay { shape.fill(VTColor.abyss.opacity(tone.smokeOpacity)).allowsHitTesting(false) }
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(Color.white.opacity(kind == .clear ? GlassTokens.Opacity.glassTintClear : GlassTokens.Opacity.fallbackFill)) }
                .overlay { shape.fill(VTColor.abyss.opacity(tone.smokeOpacity)) }
                .overlay { tint.map { shape.fill($0.opacity(0.25)) } }
        }
    }

    // MARK: Rim and shadow

    private var rim: some View {
        let colors: LinearGradient
        switch kind {
        case .panel, .clear, .raised:
            colors = GlassColor.rim()
        case .card:
            colors = GlassColor.rim(top: GlassTokens.Opacity.cardRimTop, bottom: GlassTokens.Opacity.cardRimBottom)
        case .control:
            colors = GlassColor.rim(top: 0.32, bottom: 0.06)
        case .track:
            colors = GlassColor.rim(top: 0.06, bottom: 0.16)
        }
        return shape.strokeBorder(colors, lineWidth: GlassTokens.Size.rimWidth)
    }

    private var solidFill: Color {
        switch kind {
        case .panel, .clear, .raised, .control: return GlassColor.solidPanel
        case .card, .track: return GlassColor.solidCard
        }
    }

    private var shadowOpacity: Double {
        switch kind {
        case .panel, .clear: return GlassTokens.Opacity.shadow
        case .raised: return GlassTokens.Opacity.shadow * 0.6
        case .card, .control, .track: return 0
        }
    }

    private var shadowRadius: CGFloat {
        kind == .raised ? GlassTokens.Shadow.tileRadius : GlassTokens.Shadow.panelRadius
    }

    private var shadowY: CGFloat {
        kind == .raised ? GlassTokens.Shadow.tileY : GlassTokens.Shadow.panelY
    }
}

extension View {
    /// Dusk Glass surface behind the view (see `GlassSurfaceKind`). `shadow` applies to panels.
    func glassSurface<S: InsettableShape>(
        _ kind: GlassSurfaceKind = .panel,
        in shape: S,
        tint: Color? = nil,
        shadow: Bool = true
    ) -> some View {
        modifier(GlassSurface(shape: shape, kind: kind, tint: tint, shadow: shadow))
    }

    /// Same, in a continuous rounded rectangle of `cornerRadius`.
    func glassSurface(
        _ kind: GlassSurfaceKind = .panel,
        cornerRadius: CGFloat,
        tint: Color? = nil,
        shadow: Bool = true
    ) -> some View {
        glassSurface(kind, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, shadow: shadow)
    }
}
