import SwiftUI

/// Free: what a Pro feature looks like, as a blurred sample, under a card that leads to the
/// "Konto Captylo" panel ("Wypróbuj Pro 7 dni za darmo" signed out, "Przejdź na Pro" signed in),
/// styled like the sidebar's `SupportCard`. "Notatki AI" and "Zapytaj".
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
    @Environment(AppState.self) private var appState: AppState?

    /// The trial for a signed-out user, Pro for a signed-in Free account (`ProOffer`).
    private var offer: ProOffer {
        appState?.proAccess.offer ?? .upgrade
    }

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
            Button {
                if let onSeePro {
                    onSeePro()
                } else {
                    router?.openAccount()
                }
            } label: {
                Text(verbatim: offer.buttonTitle)
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            .padding(.top, 4)
            if let note = offer.note {
                Text(verbatim: note)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
