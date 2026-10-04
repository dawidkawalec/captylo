import SwiftUI

/// What fills every window behind the panels ("Tło okna" in Ustawienia,
/// `AppSettings.windowBackground`). `DuskBackground` draws it; panels (`glassSurface`) look the
/// same over every style. The see-through "Szkło" style was removed (the owner's call); a stored
/// "glass" no longer parses, so it falls back to the default.
enum WindowBackgroundStyle: String, CaseIterable, Sendable {
    /// Slow animated brand gradient (mesh gradient on macOS 15+, drifting glows on macOS 14).
    case aurora
    /// "Zmierzch": the blurred dusk lake as a calm living video loop over its photo, under a night
    /// scrim. Raw value kept from when it was the still photo ("Zdjęcie").
    case dusk
    /// "Ciemny": the animated grain gradient in Deep Tide's Abyss, Petrol and Glacier
    /// (`GrainientBackdrop`, `GlassTokens.Grainient.dark`). Raw value kept from Brand Direction 01.
    case captylo
    /// "Jasny": the same gradient in Fog, Petrol and Glacier (`GlassTokens.Grainient.light`).
    case captyloLight

    /// The owner's pick (Brand Direction 01). Only an explicit choice is stored, so everyone who
    /// never picked a style follows this default.
    static let defaultStyle: WindowBackgroundStyle = .captylo

    /// Order in the "Tło okna" picker: the brand gradients first.
    static let pickerOrder: [WindowBackgroundStyle] = [.captylo, .captyloLight, .dusk, .aurora]

    /// `CAPTYLO_WINDOW_BG=aurora|dusk|captylo|captyloLight`, honoured by `--design-preview` only.
    static var previewOverride: WindowBackgroundStyle? {
        ProcessInfo.processInfo.environment["CAPTYLO_WINDOW_BG"].flatMap(WindowBackgroundStyle.init(rawValue:))
    }

    var title: LocalizedStringKey {
        switch self {
        case .aurora: return "Gradient"
        case .dusk: return "Zmierzch"
        case .captylo: return "Ciemny"
        case .captyloLight: return "Jasny"
        }
    }

    var systemImage: String {
        switch self {
        case .aurora: return "sparkles"
        case .dusk: return "sun.horizon"
        case .captylo: return "moon.stars"
        case .captyloLight: return "sun.max"
        }
    }
}

/// How dark the window background and the panels are, in percent ("Przyciemnienie tła" and
/// "Przydymienie paneli" in Ustawienia, `AppSettings.windowTone`). The defaults are the owner's
/// picks from the Grainient lab.
struct WindowTone: Equatable, Sendable {
    /// Black wash over the window background. The per-style scrims (`GlassTokens.Scrim`) are
    /// tuned for the default; other values shift every style by the difference.
    var backgroundDim: Int
    /// Abyss wash inside every frosted panel.
    var panelSmoke: Int

    static let standard = WindowTone(backgroundDim: 10, panelSmoke: 20)
    static let backgroundDimRange = 0...40
    static let panelSmokeRange = 0...50

    /// Added to a style's scrim (0 at the default).
    var scrimOffset: Double { Double(backgroundDim - Self.standard.backgroundDim) / 100 }

    var smokeOpacity: Double { Double(panelSmoke) / 100 }

    /// A style's scrim shifted by the user's dim, kept in a range where the gradient still shows.
    func scrim(_ base: Double) -> Double {
        min(max(base + scrimOffset, 0), 0.9)
    }
}

extension EnvironmentValues {
    /// Set at the root of every window from `AppSettings.windowBackground`; sheets inherit it.
    /// nil outside those windows (the recorder widget): `DuskBackground` then draws the default
    /// style and `glassSurface` keeps its normal fill.
    @Entry var windowBackgroundStyle: WindowBackgroundStyle?

    /// Set next to `windowBackgroundStyle` from `AppSettings.windowTone`; the recorder widget
    /// keeps the defaults.
    @Entry var windowTone: WindowTone = .standard
}
