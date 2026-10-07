import Foundation

/// Pages on captylo.com in the app's UI language: English at the root, Polish under /pl/
/// (the site's addresses since 2026-10-07). Stripe's return pages follow the same language
/// through `lang` in the billing calls (`AccountClient`).
enum SiteLinks {
    static let base = "https://captylo.com"

    /// `path` on the site for `language` ("pl" or "en"): "/kawa/" is "/pl/kawa/" under Polish.
    static func url(_ path: String, language: String = AppLanguage.runningCode) -> URL {
        URL(string: base + (language == "pl" ? "/pl" : "") + path)!
    }
}
