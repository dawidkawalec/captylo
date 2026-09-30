import AppKit
import SwiftUI

// "Dusk Glass" tokens (docs/design/dusk-glass.md). Every Glass component reads these; views
// never hard-code radii, opacities or fonts for glass surfaces.

enum GlassTokens {
    enum Radius {
        /// Big frosted panels (the expanded widget, content panels, the sidebar).
        static let panel: CGFloat = 28
        /// Inset cards inside a panel ("Transkrypcja na żywo").
        static let card: CGFloat = 18
        /// Stat tiles and other small free-standing glass blocks.
        static let tile: CGFloat = 22
        /// Buttons ("Pauza", "Zakończ"), text fields.
        static let control: CGFloat = 14
        /// Icon badges (fraction of the badge size).
        static let iconBadgeFraction: CGFloat = 0.32
    }

    enum Padding {
        static let panel: CGFloat = 22
        static let card: CGFloat = 16
        static let tile: CGFloat = 16
        static let rowHorizontal: CGFloat = 4
        static let controlHorizontal: CGFloat = 18
        static let controlVertical: CGFloat = 11
    }

    enum Size {
        static let rowMinHeight: CGFloat = 46
        static let rowIcon: CGFloat = 18
        static let rowIconColumn: CGFloat = 28
        /// Icon badge of item rows (`GlassRow(iconBadge: true)`).
        static let rowBadge: CGFloat = 32
        static let buttonHeight: CGFloat = 44
        static let buttonHeightSmall: CGFloat = 32
        /// Text and secure fields: the height of the small buttons that sit next to them.
        static let fieldHeight: CGFloat = 32
        static let segmentHeight: CGFloat = 32
        static let rimWidth: CGFloat = 1
    }

    enum Opacity {
        /// White fill of a raised card inside a panel.
        static let fill: Double = 0.12
        /// White fill over the material on the macOS 14/15 path, so the glass lifts above the
        /// wallpaper like mockup 03 instead of darkening it.
        static let fallbackFill: Double = 0.12
        /// White wash over Liquid Glass panels (macOS 26) and over the clearer `.clear` kind.
        /// Brand Direction 01 wants clear glass (the owner's pick "Czyste" in the lab): a light
        /// lift over the gradient that keeps its colours, not a milky block.
        static let glassTint: Double = 0.10
        static let glassTintClear: Double = 0.06
        /// White fill of an inset card on top of a panel (a slight lift, like the transcript card).
        static let cardFill: Double = 0.08
        /// Rim gradient: bright top edge, faint bottom edge.
        static let rimTop: Double = 0.62
        static let rimBottom: Double = 0.14
        static let cardRimTop: Double = 0.22
        static let cardRimBottom: Double = 0.05
        /// Hairline separators between row groups.
        static let separator: Double = 0.12
        /// Neutral control fill ("Pauza") and the selected segment pill.
        static let control: Double = 0.14
        static let controlPressed: Double = 0.22
        static let selection: Double = 0.24
        /// Recessed track of segmented pickers and text fields.
        static let track: Double = 0.06
        /// White lift over the track's dark wash, so fields never read as black holes.
        static let trackLift: Double = 0.06
        /// Soft drop shadow under panels.
        static let shadow: Double = 0.28
    }

    enum Shadow {
        static let panelRadius: CGFloat = 30
        static let panelY: CGFloat = 14
        static let tileRadius: CGFloat = 18
        static let tileY: CGFloat = 8
        static let glowRadius: CGFloat = 16
    }

    /// Wash over the window background (`DuskBackground`) so white type outside the panels (page
    /// titles, onboarding step labels) stays legible (0 = none, 1 = opaque). Per style and window.
    enum Scrim {
        /// Night wash over the dusk photo (the values the photo always had).
        static func dusk(_ role: WindowBackdropRole) -> Double {
            switch role {
            case .window: return 0.34
            case .onboarding: return 0.25
            case .sheet: return 0.4
            }
        }

        /// Black wash over the aurora gradient, which is already dark: it only settles the
        /// brightest glows under the titles.
        static func aurora(_ role: WindowBackdropRole) -> Double {
            switch role {
            case .window: return 0.16
            case .onboarding: return 0.12
            case .sheet: return 0.2
            }
        }

        /// Black wash over the dark Grainient: the owner's 10 % "Przyciemnienie tła" from the lab,
        /// a little more under sheets so they separate.
        static func grainient(_ role: WindowBackdropRole) -> Double {
            switch role {
            case .window, .onboarding: return 0.10
            case .sheet: return 0.2
            }
        }

        /// Black wash over the light Grainient: its Fog and Glacier fields are bright, so white
        /// type needs a little help everywhere.
        static func grainientLight(_ role: WindowBackdropRole) -> Double {
            switch role {
            case .window, .onboarding: return 0.16
            case .sheet: return 0.24
            }
        }
    }

    /// The "Ciemny" and "Jasny" styles (`GrainientBackdrop`): React Bits "Grainient" with the
    /// owner's parameters from Brand Direction 01 (approved in docs/design/lab/brand). The motion
    /// is shared; each palette sets its three colours and the tone.
    enum Grainient {
        struct Palette: Equatable, Sendable {
            var color1: UInt32
            var color2: UInt32
            var color3: UInt32
            var contrast: Double
            var gamma: Double
            var colorBalance: Double
        }

        /// Deep Tide with the owner's parameters: Abyss, Petrol, Glacier (the lab's "Ciemny").
        static let dark = Palette(color1: 0x10272C, color2: 0x214A52, color3: 0x9FE6DC, contrast: 1.5, gamma: 1.0, colorBalance: 0)
        /// Lighter: Fog, Petrol, Glacier (the lab's "Jasny").
        static let light = Palette(color1: 0xB7CCCB, color2: 0x214A52, color3: 0x9FE6DC, contrast: 1.15, gamma: 1.05, colorBalance: 0)

        static let timeSpeed = 1.05
        static let warpStrength = 1.0
        static let warpFrequency = 5.4
        static let warpSpeed = 1.5
        static let warpAmplitude = 50.0
        static let blendAngle = -2.0
        static let blendSoftness = 0.08
        static let rotationAmount = 500.0
        static let noiseScale = 1.65
        static let grainAmount = 0.09
        static let grainScale = 2.0
        static let grainAnimated = false
        static let saturation = 1.0
        static let centerX = 0.0
        static let centerY = 0.0
        static let zoom = 0.95
        /// Shader seconds of the first frame: 0 is a flat, barely mixed field.
        static let startTime = 12.0
        static let framesPerSecond = 60
        /// Render resolution relative to points (backing scale capped at this): the field is soft,
        /// so full Retina only costs power. The grain stays fine at 1.5.
        static let renderScale: CGFloat = 1.5
    }

    /// The "Gradient" style (`AuroraBackdrop`).
    enum Aurora {
        /// One full cross-fade cycle of the sky, in seconds (the drifts run on longer cycles).
        static let period: Double = 30
    }

    /// `CAPTYLO_GLASS_FALLBACK=1` forces the macOS 14/15 material path on macOS 26 (to check it).
    static let forcesFallback: Bool = ProcessInfo.processInfo.environment["CAPTYLO_GLASS_FALLBACK"] == "1"
}

// MARK: - Colors

enum GlassColor {
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.70)
    static let textTertiary = Color.white.opacity(0.50)
    static let icon = Color.white.opacity(0.88)
    static let separator = Color.white.opacity(GlassTokens.Opacity.separator)

    /// Switches in the brand accent (Tide).
    static let toggle = VTColor.tide
    /// "Zakończ" and everything that means "recording": Record red, the only place it is used.
    static let destructive = VTColor.record
    static let destructiveDeep = Color(hex: 0xE05E62)
    /// Accent actions: Tide glass over Petrol.
    static let accent = VTColor.tide
    static let accentDeep = VTColor.petrol
    static let success = Color(hex: 0x4CD68A)
    /// Warnings stay warm (Deep Tide has no warm tone), distinct from Record red.
    static let warning = Color(hex: 0xF2C48D)
    /// Brand light on the gradient: activity highlights, the latest trend bar.
    static let highlight = VTColor.glacier

    /// Solid Abyss surfaces when Reduce Transparency is on (no gradient bleeding through).
    static let solidPanel = Color(hex: 0x1C3A40)
    static let solidCard = Color(hex: 0x163136)
    /// Window background behind the backdrop (seen only while it loads / on resize): Abyss.
    static let night = VTColor.abyss

    /// Rim stroke: luminous top edge fading toward the bottom.
    static func rim(top: Double = GlassTokens.Opacity.rimTop, bottom: Double = GlassTokens.Opacity.rimBottom) -> LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(top), Color.white.opacity(bottom), Color.white.opacity(bottom * 1.6)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Typography

/// Brand Direction 01 type: Manrope for titles, numbers and the wordmark, Inter for UI and body
/// (both bundled in Resources/Fonts, SIL OFL, registered through `ATSApplicationFontsPath`).
/// If a face is missing, `Font.custom` falls back to the system font at the same size.
enum GlassFont {
    enum Face: String {
        case manropeSemiBold = "Manrope-SemiBold"
        case manropeBold = "Manrope-Bold"
        case manropeExtraBold = "Manrope-ExtraBold"
        case interRegular = "Inter-Regular"
        case interMedium = "Inter-Medium"
        case interSemiBold = "Inter-SemiBold"
    }

    static func face(_ face: Face, _ size: CGFloat) -> Font {
        .custom(face.rawValue, fixedSize: size)
    }

    /// Inter at a system-style weight (the bundled faces: regular, medium, semibold; heavier
    /// weights use semibold). For UI text that used `.system(size:weight:)`.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium: return face(.interMedium, size)
        case .semibold, .bold, .heavy, .black: return face(.interSemiBold, size)
        default: return face(.interRegular, size)
        }
    }

    /// Manrope for titles and headlines (semibold below bold, bold, extrabold above).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        switch weight {
        case .bold: return face(.manropeBold, size)
        case .heavy, .black: return face(.manropeExtraBold, size)
        default: return face(.manropeSemiBold, size)
        }
    }

    /// Screen title ("Pulpit").
    static var pageTitle: Font { face(.manropeSemiBold, 26) }
    /// Section title next to a line icon ("Aktywność").
    static var sectionTitle: Font { face(.manropeSemiBold, 15) }
    static var rowTitle: Font { face(.interRegular, 14) }
    static var rowSubtitle: Font { face(.interRegular, 12) }
    static var rowValue: Font { face(.interRegular, 13) }
    static var body: Font { face(.interRegular, 14) }
    static var bodyMedium: Font { face(.interMedium, 14) }
    static var caption: Font { face(.interRegular, 12) }
    static var button: Font { face(.interSemiBold, 14) }
    static var badge: Font { face(.interSemiBold, 11) }
    static var segment: Font { face(.interMedium, 13) }

    /// Stat values: Manrope Bold with tabular digits.
    static func number(_ size: CGFloat = 34) -> Font {
        face(.manropeBold, size).monospacedDigit()
    }

    /// The Pulpit hero number ("166").
    static func hero(_ size: CGFloat) -> Font {
        face(.manropeExtraBold, size).monospacedDigit()
    }
}

extension View {
    /// Soft dark halo under white type that sits on light glass or straight on the wallpaper,
    /// so it keeps its contrast over bright content (not a box, just a shadow).
    func glassTextShadow(_ strength: Double = 0.25) -> some View {
        shadow(color: Color.black.opacity(strength), radius: 4, y: 1)
    }

    /// Stronger halo for white marks floating with no surface behind them over any app (the
    /// compact widget's timer, status line, waveform and mic glyph): a tight dark edge plus a
    /// short soft falloff, so the strokes stay crisp over white documents. The wide cloud is the
    /// widget's single `RecorderBackdropHalo`, not a third shadow here (stacked shadows compound
    /// into dark smudges around every mark). Still a shadow, never a box.
    func glassFloatingHalo() -> some View {
        shadow(color: Color.black.opacity(0.5), radius: 1.2, y: 0.5)
            .shadow(color: Color.black.opacity(0.22), radius: 4, y: 1)
    }
}

// MARK: - Motion

enum GlassMotion {
    /// Default spring for glass state changes.
    static var spring: Animation { .spring(response: 0.38, dampingFraction: 0.85) }
    /// Selection pill sliding between segments / sidebar items.
    static var selection: Animation { .spring(response: 0.3, dampingFraction: 0.82) }
    /// Button press feedback.
    static var press: Animation { .spring(response: 0.22, dampingFraction: 0.7) }
}
