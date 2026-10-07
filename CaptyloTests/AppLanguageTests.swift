import Foundation
import Testing
@testable import Captylo

struct AppLanguageTests {
    /// A throwaway defaults domain; the suite name is also its persistent domain name.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "com.captylo.tests.app-language.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func noChoiceFollowsTheSystem() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .system)
    }

    @Test func aChoiceIsSavedAsTheAppsOwnLanguageList() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        AppLanguage.setPreference(.english, defaults: defaults)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["en"])
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .english)

        AppLanguage.setPreference(.polish, defaults: defaults)
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .polish)

        AppLanguage.setPreference(.system, defaults: defaults)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .system)
    }

    /// System Settings > Language & Region > Applications writes region variants ("en-GB").
    @Test func regionVariantsAndForeignListsAreRead() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        defaults.set(["en-GB"], forKey: "AppleLanguages")
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .english)
        defaults.set(["pl-PL", "en"], forKey: "AppleLanguages")
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .polish)
        defaults.set(["de"], forKey: "AppleLanguages")
        #expect(AppLanguage.preference(defaults: defaults, domain: domain) == .system)
    }

    @Test func theSystemLanguageIsTheFirstOneCaptyloHas() {
        #expect(AppLanguage.systemCode(preferred: ["pl-PL", "en-US"]) == "pl")
        #expect(AppLanguage.systemCode(preferred: ["en-GB", "pl"]) == "en")
        #expect(AppLanguage.systemCode(preferred: ["de-DE", "pl-PL"]) == "pl")
        // Neither Polish nor English: Polish, the development region macOS falls back to.
        #expect(AppLanguage.systemCode(preferred: ["de-DE", "fr-FR"]) == "pl")
        #expect(AppLanguage.systemCode(preferred: []) == "pl")
    }

    @Test func aRelaunchIsNeededOnlyForAnotherLanguage() {
        #expect(!AppLanguage.system.needsRelaunch(running: "pl", systemCode: "pl"))
        #expect(AppLanguage.system.needsRelaunch(running: "en", systemCode: "pl"))
        #expect(!AppLanguage.polish.needsRelaunch(running: "pl", systemCode: "en"))
        #expect(AppLanguage.english.needsRelaunch(running: "pl", systemCode: "pl"))
    }

    /// The welcome screen keeps "Jak w systemie" whenever the Mac shows that language anyway.
    @Test func theWelcomeSwitchSavesTheSystemChoiceWhenItMatches() {
        #expect(AppLanguage.choice(showing: "en", systemCode: "en") == .system)
        #expect(AppLanguage.choice(showing: "en", systemCode: "pl") == .english)
        #expect(AppLanguage.choice(showing: "pl", systemCode: "en") == .polish)
    }

    @Test func languagesKeepTheirOwnNames() {
        #expect(AppLanguage.polish.title(systemCode: "en") == "Polski")
        #expect(AppLanguage.english.title(systemCode: "pl") == "English")
        #expect(AppLanguage.system.title(systemCode: "en").hasSuffix("(English)"))
    }
}
