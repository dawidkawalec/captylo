import SwiftUI

/// Free: what a Pro feature looks like, as a blurred sample, under a card that leads to the
/// "Konto Captylo" panel ("Zobacz Pro"), styled like the sidebar's `SupportCard`. "Notatki AI"
/// and "Zapytaj".
@MainActor
struct MeetingProCard<Sample: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    /// "Zobacz Pro" when the card sits in a sheet (the caller closes it first); nil opens the
    /// account panel through the main window's router.
    var onSeePro: (() -> Void)? = nil
    /// Invented content behind the blur (never readable, only its shape shows).
    @ViewBuilder let sample: () -> Sample

    @Environment(MainRouter.self) private var router: MainRouter?

    var body: some View {
        ZStack(alignment: .top) {
            sample()
                .blur(radius: 6)
                .opacity(0.55)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            card
                .frame(maxWidth: 400)
                .padding(.top, 48)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassIconBadge(systemImage: systemImage, size: 30, tint: VTColor.brandViolet)
                .accessibilityHidden(true)
            Text(title)
                .font(GlassFont.sectionTitle)
                .foregroundStyle(GlassColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Zobacz Pro") {
                if let onSeePro {
                    onSeePro()
                } else {
                    router?.openAccount()
                }
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            .padding(.top, 4)
            #if DEBUG
            Text("Włącz Tryb Pro (dev) w Ustawieniach")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textTertiary)
                .padding(.top, 2)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card)
        .accessibilityElement(children: .contain)
    }
}
