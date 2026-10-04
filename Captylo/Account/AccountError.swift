import Foundation

/// What can go wrong talking to the Captylo account server, in words the user can act on.
/// Never names a vendor.
enum AccountError: LocalizedError, Equatable, Sendable {
    case invalidEmail
    case invalidCode
    case unauthorized
    case alreadyPro
    /// The subscription's last payment failed and Stripe still retries it: update the card in
    /// the Portal instead of buying a second subscription.
    case paymentPending
    case noCustomer
    case mailFailed
    case offline
    case serverUnavailable
    /// The session token could not be read from the Keychain right now (denied prompt, locked
    /// keychain, slow read): retryable, never a sign-out.
    case keychainUnavailable
    case quotaExceeded(resetsAt: Date?)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return String(localized: "To nie wygląda na adres e-mail.")
        case .invalidCode: return String(localized: "Ten kod nie pasuje albo wygasł.")
        case .unauthorized: return String(localized: "Zaloguj się ponownie.")
        case .alreadyPro: return String(localized: "Masz już Pro.")
        case .paymentPending: return String(localized: "Poprzednia płatność wciąż czeka. Zaktualizuj kartę zamiast kupować drugi raz.")
        case .noCustomer: return String(localized: "To konto nie ma jeszcze subskrypcji.")
        case .mailFailed: return String(localized: "Nie udało się wysłać kodu. Spróbuj za chwilę.")
        case .offline: return String(localized: "Brak połączenia z internetem.")
        case .serverUnavailable: return String(localized: "Serwer Captylo nie odpowiada. Spróbuj za chwilę.")
        case .keychainUnavailable: return String(localized: "Nie udało się odczytać sesji z pęku kluczy. Spróbuj ponownie.")
        case .quotaExceeded: return String(localized: "Limit chmury w tym miesiącu jest wyczerpany.")
        }
    }

    /// Short, stable name for logs (no user data).
    var logName: String {
        switch self {
        case .invalidEmail: return "invalidEmail"
        case .invalidCode: return "invalidCode"
        case .unauthorized: return "unauthorized"
        case .alreadyPro: return "alreadyPro"
        case .paymentPending: return "paymentPending"
        case .noCustomer: return "noCustomer"
        case .mailFailed: return "mailFailed"
        case .offline: return "offline"
        case .serverUnavailable: return "serverUnavailable"
        case .keychainUnavailable: return "keychainUnavailable"
        case .quotaExceeded: return "quotaExceeded"
        }
    }
}
