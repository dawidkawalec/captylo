import SwiftUI

/// Full-bleed background of every Dusk Glass window, in the style the user picked in Ustawienia
/// ("Tło okna", `WindowBackgroundStyle` from the environment):
/// - `.captylo` ("Ciemny", the default) and `.captyloLight` ("Jasny"): the brand's animated grain
///   gradient (`GrainientBackdrop`) in its dark and light palette,
/// - `.dusk` ("Zmierzch"): the blurred dusk lake as a living video loop over its photo, under a
///   night scrim (`DuskPhotoBackdrop`),
/// - `.aurora` ("Gradient"): a slow animated sky (`AuroraBackdrop`).
/// `role` picks the scrim strength (`GlassTokens.Scrim`), shifted by the user's "Przyciemnienie
/// tła" (`WindowTone`). Reduce Transparency: solid night.
@MainActor
struct DuskBackground: View {
    var role: WindowBackdropRole = .window
    var vignette: Bool = true

    @Environment(\.windowBackgroundStyle) private var style
    @Environment(\.windowTone) private var tone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                GlassColor.night
            } else {
                switch style ?? .defaultStyle {
                case .aurora:
                    AuroraBackdrop(scrim: tone.scrim(GlassTokens.Scrim.aurora(role)), vignette: vignette)
                case .dusk:
                    DuskPhotoBackdrop(scrim: tone.scrim(GlassTokens.Scrim.dusk(role)), vignette: vignette)
                case .captylo:
                    GrainientBackdrop(palette: GlassTokens.Grainient.dark, scrim: tone.scrim(GlassTokens.Scrim.grainient(role)))
                case .captyloLight:
                    GrainientBackdrop(palette: GlassTokens.Grainient.light, scrim: tone.scrim(GlassTokens.Scrim.grainientLight(role)))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
