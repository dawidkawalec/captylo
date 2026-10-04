import SwiftUI

/// "Konto Captylo", the first panel in Ustawienia: the sign-in form (e-mail, then the code)
/// while signed out, the plan card once signed in. Everything it shows comes from
/// `AccountStore`; the design preview pins that state, so it never reaches the network.
@MainActor
struct AccountSettingsPanel: View {
    let account: AccountStore

    var body: some View {
        GlassPanel(spacing: 4) {
            GlassSectionHeader("Konto Captylo", systemImage: "person.crop.circle")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.top, 2)
                .padding(.bottom, 4)
            switch account.state {
            case .signedOut, .codeSent:
                AccountSignInForm(account: account)
            case .signedIn(let info):
                AccountPlanCard(account: account, info: info)
            }
        }
        .task {
            await account.refreshIfStale()
        }
    }
}
