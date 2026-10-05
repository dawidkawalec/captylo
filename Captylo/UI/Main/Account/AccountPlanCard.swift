import SwiftUI

/// The signed-in account: the address and the plan. Free offers Pro (yearly and monthly open
/// Checkout in the browser); Pro shows the renewal (or expiry) date, this month's cloud and AI
/// usage against the fair-use caps and "Zarządzaj subskrypcją" (the Portal). A Pro plan the app
/// could not confirm for over 7 days says so. A failed payment Stripe still retries (`past_due`,
/// `unpaid`) says so and offers only the Portal to update the card, never a second purchase.
/// "Wyloguj" in all of them.
@MainActor
struct AccountPlanCard: View {
    let account: AccountStore
    let info: AccountInfo

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if info.isPro {
                proDetails
            } else if info.needsPaymentUpdate {
                paymentIssue
            } else {
                freeOffer
            }
            if let error = account.lastError {
                ToolStatusLine(text: error, tone: .error)
            }
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: info.isPro ? "sparkles" : "person")
                .font(.system(size: GlassTokens.Size.rowIcon))
                .foregroundStyle(GlassColor.icon)
                .frame(width: GlassTokens.Size.rowIconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: info.email)
                    .font(GlassFont.rowTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.isPro ? "Plan Pro" : "Plan Free")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
            }
            Spacer(minLength: 8)
            GlassBadge(title: Text(verbatim: info.isPro ? "Pro" : "Free"), tone: info.isPro ? .accent : .neutral)
        }
    }

    // MARK: Pro

    private var proDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let periodEnd = info.periodEnd {
                let date = Self.dateText(periodEnd)
                ToolCaption(text: info.cancelAtPeriodEnd ? Text("Wygasa \(date)") : Text("Odnawia się \(date)"))
            }
            usageLine(
                AccountUsageFormat.audio(info.usage.audioSeconds, limit: info.usage.audioSecondsLimit),
                fraction: AccountUsageFormat.fraction(info.usage.audioSeconds, limit: info.usage.audioSecondsLimit)
            )
            usageLine(
                AccountUsageFormat.tokens(info.usage.aiTokens, limit: info.usage.aiTokensLimit),
                fraction: AccountUsageFormat.fraction(info.usage.aiTokens, limit: info.usage.aiTokensLimit)
            )
            if account.isStale {
                ToolStatusLine(
                    text: String(localized: "Nie mogę sprawdzić subskrypcji. Pro wróci po połączeniu z internetem."),
                    tone: .error
                )
            }
            if info.needsPaymentUpdate {
                paymentFailedLine
            }
            manageRow(tone: info.needsPaymentUpdate ? .accent : .neutral)
        }
    }

    // MARK: Payment failed

    /// Free because the renewal was not paid; Stripe still retries the card, so a new purchase
    /// could charge twice. Only the Portal (update the card) is offered.
    private var paymentIssue: some View {
        VStack(alignment: .leading, spacing: 12) {
            paymentFailedLine
            manageRow(tone: .accent)
        }
    }

    private var paymentFailedLine: some View {
        ToolStatusLine(text: String(localized: "Płatność nie przeszła. Zaktualizuj kartę."), tone: .error)
    }

    private func manageRow(tone: GlassButtonStyle.Kind) -> some View {
        HStack(spacing: 8) {
            Button {
                open { await account.portalURL() }
            } label: {
                Text("Zarządzaj subskrypcją")
            }
            .buttonStyle(.glass(tone, size: .small, shape: .capsule))
            .disabled(account.isBusy)
            if account.isBusy {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            signOutButton
        }
    }

    private func usageLine(_ text: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
            ToolProgressTrack(value: fraction)
                .accessibilityLabel(Text(verbatim: text))
        }
    }

    // MARK: Free

    private var freeOffer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolCaption("Pro: chmura i AI bez kluczy, notatki AI ze spotkań, rozpoznawanie mówców, Zapytaj.")
            HStack(spacing: 8) {
                Button("Rocznie, 329 zł") {
                    open { await account.checkoutURL(plan: .yearly) }
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                Button("Miesięcznie, 35 zł") {
                    open { await account.checkoutURL(plan: .monthly) }
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                if account.isBusy {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 8)
                signOutButton
            }
            .disabled(account.isBusy)
        }
    }

    // MARK: Shared

    private var signOutButton: some View {
        Button("Wyloguj") {
            Task { await account.signOut() }
        }
        .buttonStyle(.plain)
        .font(GlassFont.caption)
        .foregroundStyle(GlassColor.textSecondary)
        .underline()
    }

    /// Fetches a billing link and opens it in the browser; a failure shows in `lastError`.
    private func open(_ link: @escaping @MainActor () async -> URL?) {
        Task {
            if let url = await link() {
                openURL(url)
            }
        }
    }

    /// "3 listopada 2026" in the app's locale.
    static func dateText(_ date: Date, locale: Locale = AppLocale.current) -> String {
        date.formatted(Date.FormatStyle(locale: locale).day().month(.wide).year())
    }
}
