import Foundation

/// The plan the server grants (`entitlement` on the server: active, trialing and a short
/// past-due grace are Pro).
enum AccountPlan: String, Codable, Sendable {
    case free
    case pro
}

/// The billing period picked for Checkout.
enum BillingPlan: String, Codable, Sendable, CaseIterable {
    case yearly
    case monthly
}

/// This month's relay counters and the fair-use caps (`usage` of `/v1/me`).
struct AccountUsage: Codable, Sendable, Equatable {
    /// "YYYY-MM", UTC.
    var month: String
    var audioSeconds: Int
    var audioSecondsLimit: Int
    var aiTokens: Int
    var aiTokensLimit: Int
}

/// The account as `/v1/me` describes it. Decoded with `AccountClient`'s date strategy (the
/// server writes ISO 8601 with milliseconds).
struct AccountInfo: Codable, Sendable, Equatable {
    var email: String
    var plan: AccountPlan
    /// The Stripe subscription status (`active`, `past_due`, `canceled`...), nil without one.
    var status: String?
    var periodEnd: Date?
    var cancelAtPeriodEnd: Bool
    var usage: AccountUsage

    var isPro: Bool { plan == .pro }

    /// The last payment failed and Stripe keeps retrying the card (`past_due`, `unpaid`): the
    /// card offers "Zarządzaj subskrypcją" to update it, never a second subscription.
    var needsPaymentUpdate: Bool { status == "past_due" || status == "unpaid" }
}
