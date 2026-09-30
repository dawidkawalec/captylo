import Foundation
import SwiftData

/// Replacements for the services `AppState` would otherwise build against the real machine state.
/// `.live` (all nil) is a normal launch; the design preview (`--design-preview`) passes an
/// in-memory store, a throwaway defaults suite, a temp dictionary file and pinned statuses, so
/// nothing it does can reach the user's data directory, defaults domain or Keychain items.
struct AppStateOverrides {
    /// SwiftData container used instead of `Store.makeContainer()` (which creates the data directory).
    var modelContainer: ModelContainer?
    /// `dictionary.json` location instead of `AppPaths.dictionaryJSON`.
    var dictionaryURL: URL?
    /// Key store instead of the login Keychain one.
    var keyStore: KeyStore?
    /// Defaults for the crash-recovery mute marker instead of `.standard`.
    var systemMuteDefaults: UserDefaults?
    /// Parakeet status shown regardless of the files on disk.
    var pinnedModelStatus: ParakeetModelStore.Status?
    /// Accessibility grant reported regardless of `AXIsProcessTrusted()`.
    var pinnedAccessibilityTrust: Bool?
    /// Pro status shown regardless of the dev switch (design preview, tests).
    var pinnedPro: Bool?
    /// True for `--design-preview`: code that would touch the system (the hotkey tap) stays off.
    var isDesignPreview = false

    static var live: AppStateOverrides { AppStateOverrides() }

    /// Defaults suite of the unit-test host, wiped at every launch.
    static let testHostSuiteName = "com.captylo.app.test-host"

    /// True when the app is the unit-test host (`make test`).
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The unit-test host must never open the real store: a schema change would migrate the
    /// user's history under a running Captylo. It gets an in-memory store, a temp dictionary
    /// and a throwaway defaults suite instead.
    @MainActor
    static func testHost() -> (settings: AppSettings, overrides: AppStateOverrides) {
        let defaults = UserDefaults(suiteName: testHostSuiteName) ?? .standard
        defaults.removePersistentDomain(forName: testHostSuiteName)
        let container: ModelContainer
        do {
            container = try Store.makeInMemoryContainer()
        } catch {
            fatalError("Test host: in-memory store failed: \(error)")
        }
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appending(path: "captylo-test-host-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
            .appending(path: "dictionary.json")
        let overrides = AppStateOverrides(
            modelContainer: container,
            dictionaryURL: dictionaryURL,
            systemMuteDefaults: defaults
        )
        return (AppSettings(defaults: defaults), overrides)
    }
}
