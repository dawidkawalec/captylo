import Foundation
import Security
import Testing
@testable import Captylo

/// Every test runs against a fresh temp folder, two throwaway defaults suites and in-memory key
/// stores; the real Application Support, preferences and Keychain are never touched.
@MainActor
struct LegacyMigrationTests {
    private final class MemorySecrets: LegacyMigration.SecretStore {
        var items: [String: String]
        /// Accounts whose read fails like a denied ACL prompt.
        var denied: Set<String> = []

        init(_ items: [String: String] = [:]) {
            self.items = items
        }

        func read(_ account: String) -> KeyStore.ReadResult {
            if denied.contains(account) { return KeyStore.ReadResult(value: nil, status: errSecAuthFailed) }
            let value = items[account]
            return KeyStore.ReadResult(value: value, status: value == nil ? errSecItemNotFound : errSecSuccess)
        }

        func set(_ value: String, account: String) throws { items[account] = value }
    }

    private struct Sandbox {
        let root: URL
        let newSuite: String
        let legacySuite: String
        let defaults: UserDefaults
        let legacyDefaults: UserDefaults
        let keys = MemorySecrets()
        let legacyKeys = MemorySecrets()

        var dataDirectory: URL { root.appending(path: "Application Support/Captylo", directoryHint: .isDirectory) }
        var legacyDataDirectory: URL { root.appending(path: "Application Support/VocaType2", directoryHint: .isDirectory) }

        init() throws {
            let id = UUID().uuidString
            root = FileManager.default.temporaryDirectory
                .appending(path: "CaptyloMigration-\(id)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            newSuite = "com.captylo.app.tests.migration.new.\(id)"
            legacySuite = "com.captylo.app.tests.migration.legacy.\(id)"
            defaults = try #require(UserDefaults(suiteName: newSuite))
            legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        }

        var migration: LegacyMigration {
            LegacyMigration(
                defaults: defaults,
                legacyDefaultsDomain: legacySuite,
                dataDirectory: dataDirectory,
                legacyDataDirectory: legacyDataDirectory,
                keys: keys,
                legacyKeys: legacyKeys
            )
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: newSuite)
            legacyDefaults.removePersistentDomain(forName: legacySuite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Data folder

    @Test func movesTheOldFolderAndRenamesTheStoreWithItsSidecars() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        let old = box.legacyDataDirectory
        try box.write("db", to: old.appending(path: "VocaType.store"))
        try box.write("wal", to: old.appending(path: "VocaType.store-wal"))
        try box.write("shm", to: old.appending(path: "VocaType.store-shm"))
        try box.write("{}", to: old.appending(path: "dictionary.json"))
        try box.write("wav", to: old.appending(path: "Recordings/a.wav"))

        let report = box.migration.run()

        #expect(report.data == .moved)
        let new = box.dataDirectory
        #expect(!box.exists(old))
        #expect(box.read(new.appending(path: "Captylo.store")) == "db")
        #expect(box.read(new.appending(path: "Captylo.store-wal")) == "wal")
        #expect(box.read(new.appending(path: "Captylo.store-shm")) == "shm")
        #expect(!box.exists(new.appending(path: "VocaType.store")))
        #expect(box.read(new.appending(path: "dictionary.json")) == "{}")
        #expect(box.read(new.appending(path: "Recordings/a.wav")) == "wav")
    }

    @Test func leavesBothFoldersAloneWhenTheNewOneExists() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        try box.write("old", to: box.legacyDataDirectory.appending(path: "VocaType.store"))
        try box.write("new", to: box.dataDirectory.appending(path: "Captylo.store"))

        let report = box.migration.run()

        #expect(report.data == .keptBoth)
        #expect(box.read(box.legacyDataDirectory.appending(path: "VocaType.store")) == "old")
        #expect(box.read(box.dataDirectory.appending(path: "Captylo.store")) == "new")
        #expect(!box.exists(box.dataDirectory.appending(path: "VocaType.store")))
    }

    @Test func doesNothingWithoutOldData() throws {
        let box = try Sandbox()
        defer { box.tearDown() }

        let report = box.migration.run()

        #expect(report == LegacyMigration.Report(alreadyDone: false, copiedSettings: [], data: .noLegacyData))
        #expect(!box.exists(box.dataDirectory))
        #expect(box.defaults.bool(forKey: LegacyMigration.doneKey))
    }

    // MARK: Settings

    @Test func copiesOnlyAppSettingsKeysIntoAnEmptyDomain() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        box.legacyDefaults.set(true, forKey: "onboarding.done")
        box.legacyDefaults.set("google/gemini-2.5-flash-lite", forKey: "ai.model")
        box.legacyDefaults.set(30, forKey: "dashboard.range")
        box.legacyDefaults.set("404 186 920 692 0 0 1728 1084 ", forKey: "NSWindow Frame main")

        let report = box.migration.run()

        #expect(Set(report.copiedSettings) == ["onboarding.done", "ai.model", "dashboard.range"])
        #expect(box.defaults.object(forKey: "NSWindow Frame main") == nil)
        let settings = AppSettings(defaults: box.defaults)
        #expect(settings.onboardingDone)
        #expect(settings.aiModel == "google/gemini-2.5-flash-lite")
        #expect(settings.dashboardRange == 30)
        #expect(box.legacyDefaults.bool(forKey: "onboarding.done"))
    }

    @Test func keepsSettingsWhenTheNewDomainAlreadyHasSome() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        box.defaults.set("en", forKey: "language")
        box.legacyDefaults.set(true, forKey: "onboarding.done")
        box.legacyDefaults.set("de", forKey: "language")

        let report = box.migration.run()

        #expect(report.copiedSettings.isEmpty)
        #expect(box.defaults.string(forKey: "language") == "en")
        #expect(box.defaults.object(forKey: "onboarding.done") == nil)
    }

    // MARK: Keychain

    @Test func copiesMissingKeysAndKeepsTheOldItems() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        box.keys.items = ["elevenlabs": "el-new"]
        box.legacyKeys.items = ["openrouter": "sk-or-old", "elevenlabs": "el-old"]

        let report = box.migration.runKeys()

        #expect(report.copied == ["openrouter"])
        #expect(report.pending.isEmpty)
        #expect(box.keys.items == ["openrouter": "sk-or-old", "elevenlabs": "el-new"])
        #expect(box.legacyKeys.items == ["openrouter": "sk-or-old", "elevenlabs": "el-old"])
        #expect(box.defaults.bool(forKey: LegacyMigration.keysDoneKey))
        #expect(box.migration.runKeys().alreadyDone)
    }

    @Test func settingsAndDataStepNeverTouchesTheKeychain() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        box.legacyKeys.items = ["openrouter": "sk-or-old"]

        box.migration.run()

        #expect(box.keys.items.isEmpty)
        #expect(!box.defaults.bool(forKey: LegacyMigration.keysDoneKey))
    }

    @Test func deniedKeyReadStaysPendingAndRetriesNextLaunch() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        box.legacyKeys.items = ["openrouter": "sk-or-old", "elevenlabs": "el-old"]
        box.legacyKeys.denied = ["openrouter"]

        let first = box.migration.runKeys()

        #expect(first.copied == ["elevenlabs"])
        #expect(first.pending == ["openrouter"])
        #expect(!box.defaults.bool(forKey: LegacyMigration.keysDoneKey))

        box.legacyKeys.denied = []
        let second = box.migration.runKeys()

        #expect(!second.alreadyDone)
        #expect(second.copied == ["openrouter"])
        #expect(second.pending.isEmpty)
        #expect(box.keys.items == ["openrouter": "sk-or-old", "elevenlabs": "el-old"])
        #expect(box.defaults.bool(forKey: LegacyMigration.keysDoneKey))
    }

    // MARK: Run once

    @Test func runsOnlyOnce() throws {
        let box = try Sandbox()
        defer { box.tearDown() }
        #expect(!box.migration.run().alreadyDone)

        try box.write("late", to: box.legacyDataDirectory.appending(path: "VocaType.store"))
        box.legacyDefaults.set(true, forKey: "onboarding.done")
        box.legacyKeys.items = ["openrouter": "sk-or-late"]

        let second = box.migration.run()

        #expect(second.alreadyDone)
        #expect(second.data == .noLegacyData)
        #expect(box.exists(box.legacyDataDirectory))
        #expect(!box.exists(box.dataDirectory))
        #expect(box.defaults.object(forKey: "onboarding.done") == nil)
        #expect(box.keys.items.isEmpty)
    }

    @Test func liveConfigurationUsesTheOldAndNewIdentifiers() {
        #expect(LegacyMigration.legacyIdentifier == "pl.kawalec.VocaType2")
        #expect(LegacyMigration.doneKey == "migration.vocatype2.done")
        #expect(LegacyMigration.keysDoneKey == "migration.vocatype2.keys.done")
        #expect(AppPaths.folderName == "Captylo")
        #expect(AppPaths.storeFileName == "Captylo.store")
        #expect(KeyStore.defaultService == "com.captylo.app")
        #expect(OldAppDetector.bundleIdentifiers.contains("pl.kawalec.VocaType2"))
    }
}
