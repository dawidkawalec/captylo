import Foundation
import Security

/// One-time move of what the pre-rename dev build ("VocaType 2", `pl.kawalec.VocaType2`) left on
/// this Mac. `AppDelegate` runs `run()` (settings and data folder) before `AppState` opens the
/// SwiftData store and reads `AppSettings`; the flag `doneKey` makes it run once. The Keychain
/// copy is a separate step (`runKeys()`, flag `keysDoneKey`) started after launch off the main
/// thread by `migrateKeysInBackground(into:)`: reading the old items can raise an ACL prompt that
/// blocks until the user answers, and a denied or failed read is retried on the next launch.
/// Every source is injectable, so the tests use temp directories, throwaway defaults suites and
/// in-memory key stores.
struct LegacyMigration {
    /// The Keychain surface the migration needs: `KeyStore` in the app, a dictionary in tests.
    /// `read` keeps the status so "absent" and "unreadable right now" stay distinct.
    protocol SecretStore {
        func read(_ account: String) -> KeyStore.ReadResult
        func set(_ value: String, account: String) throws
    }

    enum DataOutcome: Equatable, Sendable {
        /// Nothing at the old path.
        case noLegacyData
        /// The old folder became the new one and the store files were renamed.
        case moved
        /// Both folders exist: the new one wins, the old one stays untouched.
        case keptBoth
        case failed(String)
    }

    struct Report: Equatable, Sendable {
        var alreadyDone = false
        var copiedSettings: [String] = []
        var data: DataOutcome = .noLegacyData
    }

    struct KeyReport: Equatable, Sendable {
        var alreadyDone = false
        var copied: [String] = []
        /// Accounts without a definite answer (denied prompt, locked keychain, failed write):
        /// the step stays open and runs again next launch.
        var pending: [String] = []
    }

    static let doneKey = "migration.vocatype2.done"
    static let keysDoneKey = "migration.vocatype2.keys.done"
    /// Defaults domain and Keychain service of the pre-rename dev build.
    static let legacyIdentifier = "pl.kawalec.VocaType2"
    /// `~/Library/Application Support/VocaType2/` and the store file inside it.
    static let legacyFolderName = "VocaType2"
    static let legacyStoreFileName = "VocaType.store"
    /// SQLite sidecars travel with the store; renaming all three is safe while the app is not using them.
    static let storeSuffixes = ["", "-wal", "-shm"]
    static let keyAccounts = [KeyStore.Account.openRouter, KeyStore.Account.elevenLabs]

    /// Where `AppSettings` reads (`.standard` in the app).
    var defaults: UserDefaults
    /// Persistent domain of the old build, read with `persistentDomain(forName:)` so the global
    /// domain never counts as old settings.
    var legacyDefaultsDomain: String
    var dataDirectory: URL
    var legacyDataDirectory: URL
    var storeFileName: String = AppPaths.storeFileName
    var keys: any SecretStore
    var legacyKeys: any SecretStore

    /// The real locations: standard defaults, Application Support and the login Keychain.
    /// `keys` should be the app's own `KeyStore`, so a copied key lands in the cache it reads.
    static func live(keys: KeyStore = KeyStore()) -> LegacyMigration {
        LegacyMigration(
            defaults: .standard,
            legacyDefaultsDomain: legacyIdentifier,
            dataDirectory: AppPaths.dataDirectory,
            legacyDataDirectory: URL.applicationSupportDirectory
                .appending(path: legacyFolderName, directoryHint: .isDirectory),
            keys: keys,
            legacyKeys: KeyStore(service: legacyIdentifier)
        )
    }

    /// Settings and the data folder. Never touches the Keychain, so it is safe in `AppDelegate.init`.
    @discardableResult
    func run() -> Report {
        var report = Report()
        guard !defaults.bool(forKey: Self.doneKey) else {
            report.alreadyDone = true
            return report
        }
        report.copiedSettings = migrateSettings()
        report.data = migrateDataDirectory()
        defaults.set(true, forKey: Self.doneKey)
        Log.app.notice(
            "Legacy migration: \(report.copiedSettings.count) settings, data \(String(describing: report.data), privacy: .public)"
        )
        return report
    }

    /// The Keychain step. Blocks while an ACL prompt is open: call it off the main thread
    /// (`migrateKeysInBackground(into:)`). Marks itself done only when every account ended in a
    /// definite answer.
    @discardableResult
    func runKeys() -> KeyReport {
        var report = KeyReport()
        guard !defaults.bool(forKey: Self.keysDoneKey) else {
            report.alreadyDone = true
            return report
        }
        (report.copied, report.pending) = migrateKeys()
        if report.pending.isEmpty {
            defaults.set(true, forKey: Self.keysDoneKey)
        }
        Log.app.notice(
            "Legacy key migration: copied \(report.copied, privacy: .public), retry next launch \(report.pending, privacy: .public)"
        )
        return report
    }

    /// Runs `runKeys()` on its own queue (never the main thread or the cooperative pool).
    static func migrateKeysInBackground(into keys: KeyStore) {
        keyQueue.async {
            live(keys: keys).runKeys()
        }
    }

    private static let keyQueue = DispatchQueue(label: "com.captylo.app.migration.keys", qos: .utility)

    // MARK: Steps

    /// Copies every `AppSettings` key (never window frames or other system keys) when the new
    /// domain has none of them yet.
    func migrateSettings() -> [String] {
        let names = AppSettings.keys.map(\.rawValue)
        guard !names.contains(where: { defaults.object(forKey: $0) != nil }) else { return [] }
        guard let legacy = defaults.persistentDomain(forName: legacyDefaultsDomain), !legacy.isEmpty else { return [] }
        var copied: [String] = []
        for name in names {
            guard let value = legacy[name] else { continue }
            defaults.set(value, forKey: name)
            copied.append(name)
        }
        return copied
    }

    /// Moves the old data folder to the new path and renames the store with its `-wal` / `-shm`.
    func migrateDataDirectory() -> DataOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDataDirectory.path(percentEncoded: false)) else {
            return .noLegacyData
        }
        guard !fileManager.fileExists(atPath: dataDirectory.path(percentEncoded: false)) else {
            Log.app.notice("Legacy data folder left untouched: the new one already exists")
            return .keptBoth
        }
        do {
            try fileManager.createDirectory(
                at: dataDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyDataDirectory, to: dataDirectory)
            for suffix in Self.storeSuffixes {
                let source = dataDirectory.appending(path: Self.legacyStoreFileName + suffix)
                let target = dataDirectory.appending(path: storeFileName + suffix)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)),
                      !fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                try fileManager.moveItem(at: source, to: target)
            }
            return .moved
        } catch {
            Log.app.error("Legacy data move failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Copies API keys the new service lacks; the old items stay in place. An account whose new
    /// or old item could not be read (or whose copy failed) is reported as pending.
    func migrateKeys() -> (copied: [String], pending: [String]) {
        var copied: [String] = []
        var pending: [String] = []
        for account in Self.keyAccounts {
            let current = keys.read(account)
            guard current.isCacheable else {
                pending.append(account)
                continue
            }
            guard current.value == nil else { continue }
            let legacy = legacyKeys.read(account)
            guard legacy.isCacheable else {
                Log.app.error("Legacy key for \(account, privacy: .public) unreadable (\(legacy.status)), retrying next launch")
                pending.append(account)
                continue
            }
            guard let value = legacy.value, !value.isEmpty else { continue }
            do {
                try keys.set(value, account: account)
                copied.append(account)
            } catch {
                Log.app.error("Legacy key copy failed for \(account, privacy: .public)")
                pending.append(account)
            }
        }
        return (copied, pending)
    }
}

extension KeyStore: LegacyMigration.SecretStore {}
