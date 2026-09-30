import Foundation

/// Locale for numbers, dates and language names shown in the UI. It follows the UI language
/// the app runs in (not the system region), so Polish UI always gets Polish formatting
/// ("1,2 tys.", "25 wrz") and English UI gets English formatting ("1.2K", "Sep 25").
enum AppLocale {
    static let current: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "pl"
        return Locale(identifier: language.hasPrefix("en") ? "en_US" : "pl_PL")
    }()
}
