import Foundation
import Testing
@testable import Captylo

struct AppUpdaterConfigurationTests {
    private let feed = "https://captylo.com/updates/appcast.xml"
    private let key = "pGg3aW1lc3RhbXAtcHVibGljLWtleS1mb3ItdGVzdHM="

    @Test func feedURLComesFromTheInfoDictionary() {
        let url = AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": feed], environment: [:])
        #expect(url == URL(string: feed))
    }

    @Test func feedURLMissingOrBrokenIsNil() {
        #expect(AppUpdaterConfiguration.feedURL(info: [:], environment: [:]) == nil)
        #expect(AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": ""], environment: [:]) == nil)
        #expect(AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": "appcast.xml"], environment: [:]) == nil)
        #expect(AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": "file:///tmp/appcast.xml"], environment: [:]) == nil)
        #expect(AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": 42], environment: [:]) == nil)
    }

    /// The tampered-update test serves a local appcast; only debug builds (like the test host) read it.
    @Test func debugBuildsTakeTheEnvironmentOverride() {
        let local = "http://127.0.0.1:8123/appcast.xml"
        let url = AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": feed], environment: ["CAPTYLO_APPCAST_URL": local])
        #if DEBUG
        #expect(url == URL(string: local))
        #else
        #expect(url == URL(string: feed))
        #endif
        // A broken override never wins over the real feed.
        let broken = AppUpdaterConfiguration.feedURL(info: ["SUFeedURL": feed], environment: ["CAPTYLO_APPCAST_URL": "nope"])
        #expect(broken == URL(string: feed))
    }

    @Test func placeholderKeyIsNotConfigured() {
        let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": AppUpdaterConfiguration.placeholderKey]
        #expect(AppUpdaterConfiguration.publicKey(info: info) == nil)
        #expect(!AppUpdaterConfiguration.isConfigured(info: info, environment: [:]))
    }

    @Test func emptyOrUnexpandedKeyIsNotConfigured() {
        for value in ["", "   ", "$(SPARKLE_PUBLIC_ED_KEY)"] {
            let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": value]
            #expect(AppUpdaterConfiguration.publicKey(info: info) == nil)
            #expect(!AppUpdaterConfiguration.isConfigured(info: info, environment: [:]))
        }
        #expect(!AppUpdaterConfiguration.isConfigured(info: ["SUFeedURL": feed], environment: [:]))
    }

    @Test func realKeyAndFeedAreConfigured() {
        let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key]
        #expect(AppUpdaterConfiguration.publicKey(info: info) == key)
        #expect(AppUpdaterConfiguration.isConfigured(info: info, environment: [:]))
        // A key without a feed is not enough.
        #expect(!AppUpdaterConfiguration.isConfigured(info: ["SUPublicEDKey": key], environment: [:]))
    }

    /// `make release` keeps project.yml's build number 1; only `make dist` stamps the commit count.
    /// A development copy must never be offered the public build over itself.
    @Test func developmentBuildNeverUpdates() {
        let dev: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key, "CFBundleVersion": "1"]
        #expect(!AppUpdaterConfiguration.isConfigured(info: dev, environment: [:]))
        let release: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key, "CFBundleVersion": "142"]
        #expect(AppUpdaterConfiguration.isConfigured(info: release, environment: [:]))
    }

    @Test func buildNumberParsesWholeNumbersOnly() {
        #expect(AppUpdaterConfiguration.buildNumber(info: ["CFBundleVersion": "142"]) == 142)
        #expect(AppUpdaterConfiguration.buildNumber(info: ["CFBundleVersion": " 7 "]) == 7)
        #expect(AppUpdaterConfiguration.buildNumber(info: ["CFBundleVersion": "abc"]) == nil)
        #expect(AppUpdaterConfiguration.buildNumber(info: ["CFBundleVersion": "1.2"]) == nil)
        #expect(AppUpdaterConfiguration.buildNumber(info: ["CFBundleVersion": "-3"]) == nil)
        #expect(AppUpdaterConfiguration.buildNumber(info: [:]) == nil)
    }

    @Test func versionStringShowsTheBuildWhenThereIsOne() {
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "142"]
        #expect(AppUpdaterConfiguration.versionString(info: full) == "1.0.0 (142)")
        #expect(AppUpdaterConfiguration.versionString(info: ["CFBundleShortVersionString": "1.0.0"]) == "1.0.0")
        #expect(AppUpdaterConfiguration.versionString(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "abc"]) == "1.0.0")
        #expect(AppUpdaterConfiguration.versionString(info: [:]) == "?")
    }

    @Test func versionLineIsTheLocalizedVersionLabel() throws {
        let full: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "142"]
        let version = "1.0.0 (142)"
        #expect(AppUpdaterConfiguration.versionLine(info: full) == String(localized: "Wersja \(version)"))
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: enPath))
        #expect(String(localized: "Wersja \(version)", bundle: en, locale: Locale(identifier: "en")) == "Version 1.0.0 (142)")
    }

    @Test func updateStringsHaveEnglishTranslations() throws {
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: enPath))
        func english(_ key: String.LocalizationValue) -> String {
            String(localized: key, bundle: en, locale: Locale(identifier: "en"))
        }
        #expect(english("Aktualizacje") == "Updates")
        #expect(english("Sprawdź aktualizacje…") == "Check for Updates…")
        #expect(english("Sprawdzaj automatycznie") == "Check automatically")
        #expect(english("Sprawdź teraz") == "Check now")
        #expect(english("Aktualizacje będą dostępne w wersji publicznej.") == "Updates will be available in the public version.")
    }

    /// The preview and the test host never get a live updater, whatever the Info.plist says.
    @Test @MainActor func disabledUpdaterHasNoControllerAndNeverStarts() {
        let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": key]
        let updater = AppUpdater(bundleInfo: info, enabled: false)
        #expect(!updater.isConfigured)
        #expect(!updater.hasController)
        updater.start()
        updater.checkNow()
        #expect(!updater.isStarted)
        #expect(!updater.automaticChecks)
    }

    @Test @MainActor func unconfiguredUpdaterStaysOff() {
        let info: [String: Any] = ["SUFeedURL": feed, "SUPublicEDKey": AppUpdaterConfiguration.placeholderKey]
        let updater = AppUpdater(bundleInfo: info, enabled: true)
        #expect(!updater.isConfigured)
        #expect(!updater.hasController)
        updater.start()
        #expect(!updater.isStarted)
    }

    /// A configured updater builds Sparkle's controller but never starts it on its own: only
    /// `start()` (from `startServices()`) does. Nothing is written or fetched here.
    @Test @MainActor func configuredUpdaterWaitsForStart() {
        let info: [String: Any] = [
            "SUFeedURL": feed, "SUPublicEDKey": key,
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "142",
        ]
        let updater = AppUpdater(bundleInfo: info, enabled: true)
        #expect(updater.isConfigured)
        #expect(updater.hasController)
        #expect(!updater.isStarted)
        #expect(!updater.isChecking)
        #expect(updater.versionLine == String(localized: "Wersja \("1.0.0 (142)")"))
        // checkNow before start is ignored (no Sparkle window from the test host).
        updater.checkNow()
        #expect(!updater.isStarted)
    }

    /// The app's own Info.plist (the test host is the app) points at captylo.com, checks on.
    @Test func shippedInfoPlistHasTheFeed() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(AppUpdaterConfiguration.feedURL(info: info, environment: [:]) == URL(string: feed))
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }
}
