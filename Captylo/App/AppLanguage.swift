import Foundation

/// "Język aplikacji": follow macOS, or always Polish or English. The choice is the app's own
/// `AppleLanguages`, the same value System Settings > Language & Region > Applications writes, so
/// after a relaunch everything follows it: strings, menus, Sparkle's windows, the permission
/// prompts and `AppLocale`. A running process keeps the language it started with, hence
/// `needsRelaunch`. Not the dictation language (`AppSettings.language`).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case polish = "pl"
    case english = "en"

    var id: String { rawValue }

    static let defaultsKey = "AppleLanguages"

    /// The app's own choice. Read from its persistent domain only: `UserDefaults.array(forKey:)`
    /// would merge in the global system list and never answer `.system`.
    static func preference(
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) -> AppLanguage {
        guard let domain,
              let first = (defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String])?.first
        else { return .system }
        return code(of: first).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static func setPreference(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        switch language {
        case .system: defaults.removeObject(forKey: defaultsKey)
        case .polish, .english: defaults.set([language.rawValue], forKey: defaultsKey)
        }
    }

    /// The choice that shows `code`: "Jak w systemie" when the Mac picks that language anyway, so
    /// a later change of the Mac's language still reaches the app.
    static func choice(showing code: String, systemCode: String = AppLanguage.systemCode()) -> AppLanguage {
        code == systemCode ? .system : AppLanguage(rawValue: code) ?? .system
    }

    /// "pl" or "en": what Captylo shows with no choice of its own, the first of the Mac's languages
    /// it has. Polish when there is none: that is `CFBundleDevelopmentRegion`, which has to stay
    /// `pl` (project.yml), so a German Mac switches with the welcome screen's "English".
    static func systemCode(preferred: [String] = systemLanguages()) -> String {
        preferred.lazy.compactMap(code(of:)).first ?? "pl"
    }

    /// The Mac's language list from the global domain, without the app's own choice.
    static func systemLanguages() -> [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[defaultsKey] as? [String]
            ?? Locale.preferredLanguages
    }

    /// "pl" or "en": the language this process runs in.
    static var runningCode: String {
        Bundle.main.preferredLocalizations.first.flatMap(code(of:)) ?? "en"
    }

    /// "pl" or "en" for this choice.
    func code(systemCode: String = AppLanguage.systemCode()) -> String {
        self == .system ? systemCode : rawValue
    }

    /// True when the choice shows a different language than the running one.
    func needsRelaunch(running: String = AppLanguage.runningCode, systemCode: String = AppLanguage.systemCode()) -> Bool {
        code(systemCode: systemCode) != running
    }

    /// Each language under its own name ("Polski", "English"), never translated; "Jak w systemie"
    /// names the language the Mac picks.
    func title(systemCode: String = AppLanguage.systemCode()) -> String {
        switch self {
        case .system:
            let name = Self.name(of: systemCode)
            return String(localized: "Jak w systemie (\(name))")
        case .polish, .english:
            return Self.name(of: rawValue)
        }
    }

    private static func name(of code: String) -> String {
        code == "pl" ? "Polski" : "English"
    }

    private static func code(of language: String) -> String? {
        let lowered = language.lowercased()
        if lowered.hasPrefix("pl") { return "pl" }
        if lowered.hasPrefix("en") { return "en" }
        return nil
    }
}
