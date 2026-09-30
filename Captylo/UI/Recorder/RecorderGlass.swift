import SwiftUI

/// Which glass surface of the widget this is. The compact orb and the expanded header share
/// the `shell` id, so on macOS 26 the orb bubble morphs into the header capsule and back.
enum RecorderGlassRole: String, Sendable {
    /// Compact orb (mockup 01): clear glass bubble.
    case orb
    /// Header capsule of the expanded widget (mockup 03).
    case header
    /// Lower panel of the expanded widget.
    case panel

    /// `glassEffectID` of the role.
    var morphID: String {
        switch self {
        case .orb, .header: return "shell"
        case .panel: return "panel"
        }
    }
}

/// Glass of the recorder widget. Same look as `glassSurface`, plus `glassEffectID` on macOS 26
/// so the surfaces morph inside the widget's `GlassEffectContainer` when it expands or collapses.
/// Below macOS 26, with `CAPTYLO_GLASS_FALLBACK=1` and with Reduce Transparency it is exactly
/// `glassSurface` (material + white fill + rim, or the solid dusk fill).
@MainActor
struct RecorderGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let role: RecorderGlassRole
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Milky white wash: the widget is lighter than what is behind it, the warm wallpaper shows
    /// through (mockups 03 / 04). White type keeps its own soft dark shadow for bright windows.
    static var tint: Color { Color.white.opacity(0.22) }
    /// White fill between the glass and the content of the header and the panel (macOS 26).
    /// Lifts the dark regular glass to the milky mid grey of mockup 04 over white windows (about
    /// 140 luminance instead of a 118 slab) and to a warm lift over the wallpaper (mockup 03).
    static var wash: Double { 0.20 }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !GlassTokens.forcesFallback, !reduceTransparency {
            // The glass wraps the content itself: inside a `GlassEffectContainer` the container
            // draws every glass shape in one pass above sibling layers, so glass on a background
            // `Color.clear` would cover the content. The content is clipped to the rounded shape
            // first, so no square-cornered layer can show at the corners.
            //
            // The glass stays the dark regular variant: the widget floats over any app, mostly
            // white documents, and light glass there turns white type unreadable. A plain white
            // wash inside it gives the milky grey of mockup 04 instead of a smoky slab.
            clippedContent(content)
                .background {
                    if role != .orb {
                        shape.fill(Color.white.opacity(Self.wash)).allowsHitTesting(false)
                    }
                }
                .glassEffect(glass, in: shape)
                .glassEffectID(role.morphID, in: namespace)
                .overlay {
                    // Luminous rim all around, brightest at the top (mockup 03).
                    shape
                        .strokeBorder(GlassColor.rim(top: role == .orb ? 0.85 : 0.6, bottom: role == .orb ? 0.25 : 0.2), lineWidth: GlassTokens.Size.rimWidth)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassSurface(role == .orb ? .clear : .panel, in: shape, tint: role == .orb ? nil : Self.tint)
        }
    }

    /// Header and panel content never paints past the rounded shape. The orb is not clipped:
    /// its record dot glows over the rim.
    @ViewBuilder
    private func clippedContent(_ content: Content) -> some View {
        if role == .orb {
            content
        } else {
            content.clipShape(shape)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        switch role {
        case .orb:
            return Glass.clear.tint(Color.white.opacity(0.08))
        case .header, .panel:
            return Glass.regular.tint(Self.tint)
        }
    }
}

extension View {
    func recorderGlass<S: InsettableShape>(_ role: RecorderGlassRole, in shape: S, namespace: Namespace.ID) -> some View {
        modifier(RecorderGlass(shape: shape, role: role, namespace: namespace))
    }
}
