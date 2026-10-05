import SwiftUI

/// The short Pro card at the top of Modele: whether the cloud and AI work without keys (Pro), or
/// the way there ("Przejdź na Pro" for a Free account, "Zaloguj" when signed out), both opening
/// the "Konto Captylo" panel. Reads only `AccountStore`, so the design preview shows its pinned state.
@MainActor
struct ProStatusCard: View {
    let account: AccountStore

    @Environment(MainRouter.self) private var router: MainRouter?

    /// What the card says, from the account (pure, tested).
    enum Kind: Equatable, Sendable {
        /// Pro confirmed in the last 7 days: the relay is used when there is no own key.
        case pro
        /// Pro from the 7-day trial of a new account, until `ends`.
        case trial(ends: Date)
        /// A cached Pro plan the app could not confirm for over 7 days (offline).
        case stale
        case free
        /// Free after the trial ran out.
        case trialEnded
        case signedOut
    }

    nonisolated static func kind(state: AccountStore.State, isPro: Bool, isStale: Bool, now: Date = Date()) -> Kind {
        guard case .signedIn(let info) = state else { return .signedOut }
        if isPro {
            if info.isTrial, let ends = info.trialEndsAt { return .trial(ends: ends) }
            return .pro
        }
        if isStale { return .stale }
        return info.trialEnded(at: now) ? .trialEnded : .free
    }

    var body: some View {
        GlassPanel {
            GlassRow(title: Text("Captylo Pro"), subtitle: subtitle, systemImage: "sparkles") {
                trailing
            }
        }
    }

    private var kind: Kind {
        Self.kind(state: account.state, isPro: account.isPro, isStale: account.isStale)
    }

    private var subtitle: Text {
        switch kind {
        case .pro:
            return Text("Captylo Pro: chmura i Captylo AI działają bez kluczy.")
        case .trial(let ends):
            return Text("Pro na próbę do \(AccountPlanCard.dateText(ends)): chmura i Captylo AI działają bez kluczy.")
        case .stale:
            return Text("Nie mogę sprawdzić subskrypcji. Pro wróci po połączeniu z internetem.")
        case .free:
            return Text("Masz plan Free. Pro daje chmurę i AI bez kluczy.")
        case .trialEnded:
            return Text("Okres próbny Pro się skończył. Pro daje chmurę i AI bez kluczy.")
        case .signedOut:
            return Text("Zaloguj się, a nowe konto dostanie 7 dni Pro za darmo, bez karty.")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .pro:
            GlassBadge("Aktywne", systemImage: "checkmark", tone: .success)
        case .trial:
            Button("Kup Pro") {
                router?.openAccount()
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        case .stale:
            GlassBadge("Offline", systemImage: "exclamationmark", tone: .warning)
        case .free, .trialEnded:
            Button("Przejdź na Pro") {
                router?.openAccount()
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        case .signedOut:
            Button("Zaloguj") {
                router?.openAccount()
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }
}
