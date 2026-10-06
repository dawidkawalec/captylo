import Foundation

/// What an upsell in Free offers. The server gives a new account signed in from the app 7 days
/// of Pro once (`AccountInfo.trial`), so a signed-out user is offered the trial; a signed-in
/// Free account already had its chance (or bought on the site) and is offered Pro itself.
enum ProOffer: Equatable, Sendable {
    /// Pro already, paid or on the trial: no upsell.
    case none
    /// Signed out: a new account starts 7 days of Pro, no card.
    case trial
    /// Signed in on Free.
    case upgrade

    static func of(isPro: Bool, isSignedIn: Bool) -> ProOffer {
        if isPro { return .none }
        return isSignedIn ? .upgrade : .trial
    }

    /// The button of a Pro card or banner. Both lead to "Konto Captylo" (sign-in for the trial,
    /// the prices for an upgrade).
    var buttonTitle: String {
        switch self {
        case .trial: return String(localized: "Wypróbuj Pro 7 dni za darmo")
        case .upgrade, .none: return String(localized: "Przejdź na Pro")
        }
    }

    /// The small print under the button; nil when there is nothing to add.
    var note: String? {
        switch self {
        case .trial: return String(localized: "Nowe konto, bez karty. Po 7 dniach wracasz do Free.")
        case .upgrade, .none: return nil
        }
    }
}
