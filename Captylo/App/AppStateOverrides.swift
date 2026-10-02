import Foundation
import SwiftData

/// Replacements for the services `AppState` would otherwise build against the real machine state.
/// `.live` (all nil) is a normal launch; the design preview (`--design-preview`) passes an
/// in-memory store, a throwaway defaults suite, a temp dictionary file and pinned statuses, so
/// nothing it does can reach the user's data directory, defaults domain or Keychain items.
struct AppStateOverrides {
    /// SwiftData container used instead of `Store.makeContainer()` (which creates the data directory).
    var modelContainer: ModelContainer?
    /// Meeting search index file instead of `AppPaths.searchIndex`. With an overridden (or
    /// fallback) store and no file here the index stays in memory, so the design preview and the
    /// test host never open the real index.
    var searchIndexURL: URL?
    /// `dictionary.json` location instead of `AppPaths.dictionaryJSON`.
    var dictionaryURL: URL?
    /// Key store instead of the login Keychain one.
    var keyStore: KeyStore?
    /// Defaults for the crash-recovery mute marker instead of `.standard`.
    var systemMuteDefaults: UserDefaults?
    /// Parakeet status shown regardless of the files on disk.
    var pinnedModelStatus: ParakeetModelStore.Status?
    /// Meeting voice detector status shown without loading it (the design preview never downloads).
    var pinnedSpeechDetectorStatus: SpeechDetectorStatus.State?
    /// Accessibility grant reported regardless of `AXIsProcessTrusted()`.
    var pinnedAccessibilityTrust: Bool?
    /// Pro status shown regardless of the dev switch (design preview, tests).
    var pinnedPro: Bool?
    /// Calendar events served with full access instead of EventKit (`FixedCalendarSource`): the
    /// design preview and the test host never open the user's calendar.
    var calendarEvents: [CalendarEvent]?
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
        isolated(suiteName: testHostSuiteName, folderPrefix: "captylo-test-host")
    }

    /// An in-memory store (and so an in-memory index), a temp dictionary and a wiped defaults suite.
    @MainActor
    private static func isolated(suiteName: String, folderPrefix: String) -> (settings: AppSettings, overrides: AppStateOverrides) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let container: ModelContainer
        do {
            container = try Store.makeInMemoryContainer()
        } catch {
            fatalError("In-memory store failed: \(error)")
        }
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appending(path: "\(folderPrefix)-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
            .appending(path: "dictionary.json")
        let overrides = AppStateOverrides(
            modelContainer: container,
            dictionaryURL: dictionaryURL,
            systemMuteDefaults: defaults,
            calendarEvents: []
        )
        return (AppSettings(defaults: defaults), overrides)
    }
}
