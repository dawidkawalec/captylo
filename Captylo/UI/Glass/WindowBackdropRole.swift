/// Which window `DuskBackground` fills: each role has its own scrim strength per
/// `WindowBackgroundStyle` (`GlassTokens.Scrim`).
enum WindowBackdropRole: Sendable {
    /// The main window.
    case window
    case onboarding
    /// Sheets and the component gallery.
    case sheet
}
