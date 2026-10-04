import Foundation

/// Pure facts about the update setup (Sparkle), read from the Info.plist and testable without
/// Sparkle. The updater starts only when `isConfigured`: a feed URL and a real EdDSA public key.
/// Until the owner has generated the key, `SPARKLE_PUBLIC_ED_KEY` in `project.yml` is
/// `placeholderKey` and updates stay off.
enum AppUpdaterConfiguration {
    static let placeholderKey = "REPLACE_ME"
    static let feedKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"
    /// Debug builds only: a local appcast for the tampered-update test. Release builds ignore it.
    static let feedOverrideVariable = "CAPTYLO_APPCAST_URL"

    /// `SUFeedURL`, an absolute http(s) URL. In debug builds `CAPTYLO_APPCAST_URL` wins when it
    /// is a valid URL itself.
    static func feedURL(
        info: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        #if DEBUG
        if let override = environment[feedOverrideVariable].flatMap(webURL) {
            return override
        }
        #endif
        return (info[feedKey] as? String).flatMap(webURL)
    }

    /// `SUPublicEDKey`, nil for the placeholder, an empty value or an unexpanded build setting.
    static func publicKey(info: [String: Any]) -> String? {
        guard let raw = info[publicKeyKey] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != placeholderKey, !key.hasPrefix("$(") else { return nil }
        return key
    }

    /// `make release` and Xcode builds keep project.yml's `CURRENT_PROJECT_VERSION` 1; only
    /// `make dist` stamps the commit count. Such a development copy never checks for updates,
    /// or every public release would be offered over the owner's working build.
    static let developmentBuild = 1

    static func isConfigured(
        info: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        feedURL(info: info, environment: environment) != nil
            && publicKey(info: info) != nil
            && buildNumber(info: info) != developmentBuild
    }

    /// `CFBundleVersion` as a whole number (what Sparkle compares); nil for anything else.
    static func buildNumber(info: [String: Any]) -> Int? {
        guard let raw = info["CFBundleVersion"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }

    /// "1.0.0 (142)", or "1.0.0" without a numeric build.
    static func versionString(info: [String: Any]) -> String {
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        guard let build = buildNumber(info: info) else { return version }
        return "\(version) (\(build))"
    }

    /// "Wersja 1.0.0 (142)": the settings footer and the "Aktualizacje" row.
    static func versionLine(info: [String: Any]) -> String {
        let version = versionString(info: info)
        return String(localized: "Wersja \(version)")
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        return url
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
