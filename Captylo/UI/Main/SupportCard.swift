import SwiftUI

/// A paid sponsor slot for the Free plan's support card. Compiled in, never fetched: the app
/// makes no network call for it, so the "nothing leaves your Mac" promise holds. Selling a slot
/// means setting `current` in a release (and updating the privacy copy on captylo.com if the
/// slot ever becomes remote).
struct SponsorAd: Equatable, Sendable {
    var title: String
    var message: String
    var actionTitle: String
    var url: URL

    /// No sponsor for now: the card rotates between Pro and the coffee.
    static let current: SponsorAd? = nil
}

/// What the Pulpit support card shows: one message a day, rotating by the day number.
enum SupportPromo: Equatable, Sendable {
    case pro
    case coffee
    case sponsor(SponsorAd)

    /// "Ukryj" hides the card for this long.
    static let hideInterval: TimeInterval = 14 * 24 * 3600

    /// A page on our site that forwards to the Stripe Payment Link, so the payment link can
    /// change without a new app release.
    static let coffeeURL = URL(string: "https://captylo.com/kawa/")!

    /// The card of the given day: Pro and the coffee take turns, a sponsor joins the rotation.
    static func current(on day: Int, sponsor: SponsorAd?) -> SupportPromo {
        var options: [SupportPromo] = [.pro, .coffee]
        if let sponsor {
            options.append(.sponsor(sponsor))
        }
        let index = ((day % options.count) + options.count) % options.count
        return options[index]
    }

    /// Days since the reference date in the given calendar, so the card changes at midnight.
    static func dayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        return Int((start.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    static func isVisible(hiddenUntil: Date?, now: Date) -> Bool {
        guard let hiddenUntil else { return true }
        return now >= hiddenUntil
    }

    var title: String {
        switch self {
        case .pro: return String(localized: "Captylo Pro")
        case .coffee: return String(localized: "Postaw kawę twórcy")
        case .sponsor(let ad): return ad.title
        }
    }

    var message: String {
        switch self {
        case .pro: return String(localized: "Notatki AI ze spotkań, podpisy mówców i Zapytaj. Do tego chmura i AI bez kluczy.")
        case .coffee: return String(localized: "Captylo jest darmowe i takie zostanie. Jeśli oszczędza Ci czas, postaw kawę za 20 zł.")
        case .sponsor(let ad): return ad.message
        }
    }

    var actionTitle: String {
        switch self {
        case .pro: return String(localized: "Zobacz Pro")
        case .coffee: return String(localized: "Postaw kawę")
        case .sponsor(let ad): return ad.actionTitle
        }
    }

    /// The action for this user: Pro offers the 7-day trial to a signed-out user (`ProOffer`).
    func actionTitle(offer: ProOffer) -> String {
        if case .pro = self, offer == .trial {
            return String(localized: "7 dni Pro za darmo")
        }
        return actionTitle
    }

    /// The page the action opens; nil for Pro, which opens "Konto Captylo" in Ustawienia.
    var url: URL? {
        switch self {
        case .pro: return nil
        case .coffee: return Self.coffeeURL
        case .sponsor(let ad): return ad.url
        }
    }

    var symbol: String {
        switch self {
        case .pro: return "sparkles"
        case .coffee: return "cup.and.saucer"
        case .sponsor: return "megaphone"
        }
    }
}

/// Small card at the bottom of the main window's sidebar in the Free plan (and on the Pro trial),
/// visible on every section; a paying Pro account never sees it, so nobody who pays is asked for
/// a coffee: today's promo, its action and a close button that hides it for two weeks. Sits inside
/// the sidebar glass, so it is a raised fill, not glass. Never shown in the recorder widget.
@MainActor
struct SupportCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(MainRouter.self) private var router: MainRouter?
    let now: Date

    var body: some View {
        let settings = appState.settings
        let paysForPro = appState.account.isPro && !appState.account.isTrial
        if !paysForPro, SupportPromo.isVisible(hiddenUntil: settings.supportCardHiddenUntil, now: now) {
            let promo = SupportPromo.current(on: SupportPromo.dayNumber(now), sponsor: SponsorAd.current)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    GlassIconBadge(systemImage: promo.symbol, size: 26, tint: tint(for: promo))
                    Spacer(minLength: 8)
                    Button {
                        settings.supportCardHiddenUntil = now.addingTimeInterval(SupportPromo.hideInterval)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(GlassColor.textTertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Ukryj na dwa tygodnie"))
                    .accessibilityLabel(Text("Ukryj na dwa tygodnie"))
                }
                Text(verbatim: promo.title)
                    .font(GlassFont.rowValue.weight(.semibold))
                    .foregroundStyle(GlassColor.textPrimary)
                Text(verbatim: promo.message)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(promo.actionTitle(offer: appState.proAccess.offer)) {
                    if let url = promo.url {
                        openURL(url)
                    } else {
                        router?.openAccount()
                    }
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule, fillsWidth: true))
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card)
            .accessibilityElement(children: .contain)
        }
    }

    private func tint(for promo: SupportPromo) -> Color {
        switch promo {
        case .pro: return VTColor.brandViolet
        case .coffee: return VTColor.brandOrange
        case .sponsor: return VTColor.brandPink
        }
    }
}
