import Foundation
import Testing
@testable import Captylo

@MainActor
struct AppSettingsAIModesTests {
    private static let suiteName = "com.captylo.app.tests.ai-modes"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    private func makeSettings() throws -> AppSettings {
        AppSettings(defaults: try makeDefaults())
    }

    private static let customPrompt = "Popraw tekst i dodaj emoji. Słownik: {DICTIONARY}"

    // MARK: Defaults

    @Test func defaultsAreTheBuiltInsWithCleanupActive() throws {
        let settings = try makeSettings()
        let modes = settings.aiModes
        #expect(modes.map(\.builtInKey) == ["cleanup", "english", "organize", "email", "tasks"])
        #expect(modes.map(\.id) == BuiltInAIModes.all.map(\.id))
        #expect(modes.map(\.kind) == [.cleanup, .rewrite, .rewrite, .rewrite, .rewrite])
        #expect(modes.map(\.deadlineSeconds) == [3, 6, 8, 6, 6])
        #expect(modes.map(\.symbol) == ["sparkles", "globe", "list.bullet.indent", "envelope", "checklist"])
        #expect(settings.aiActiveModeID == BuiltInAIModes.cleanupID)
        #expect(settings.activeMode.builtInKey == BuiltInAIModes.Key.cleanup)
        #expect(settings.activeMode.prompt == CleanupPrompt.defaultTemplate)
        #expect(!settings.aiEnabled, "Bez AI stays the default master switch")
        // Nothing is written until the user changes something.
        #expect(UserDefaults(suiteName: Self.suiteName)?.object(forKey: "ai.modes") == nil)
        #expect(AppSettings.keys.contains(.aiModes))
        #expect(AppSettings.keys.contains(.aiActiveModeID))
    }

    @Test func activeModeFallsBackWhenTheIdIsUnknown() throws {
        let settings = try makeSettings()
        settings.aiActiveModeID = UUID()
        #expect(settings.activeMode.id == BuiltInAIModes.cleanupID)
        settings.aiActiveModeID = BuiltInAIModes.englishID
        #expect(settings.activeMode.builtInKey == BuiltInAIModes.Key.english)
    }

    // MARK: Migration from ai.prompt

    @Test func customLegacyPromptBecomesMojPromptAndIsActive() throws {
        let defaults = try makeDefaults()
        defaults.set(Self.customPrompt, forKey: "ai.prompt")
        let settings = AppSettings(defaults: defaults)

        let modes = settings.aiModes
        #expect(modes.count == 6)
        let migrated = try #require(modes.last)
        #expect(migrated.id == BuiltInAIModes.migratedPromptID)
        #expect(migrated.name == String(localized: "Mój prompt"))
        #expect(migrated.prompt == Self.customPrompt)
        #expect(migrated.kind == .cleanup)
        #expect(migrated.deadlineSeconds == 3)
        #expect(migrated.builtInKey == nil)
        #expect(settings.activeMode == migrated)
    }

    @Test func migrationHappensOnceAndSurvivesALaterPromptChange() throws {
        let defaults = try makeDefaults()
        defaults.set(Self.customPrompt, forKey: "ai.prompt")
        let settings = AppSettings(defaults: defaults)
        // The first change stores the list with "Mój prompt" in it.
        settings.moveMode(id: BuiltInAIModes.migratedPromptID, by: -10)
        #expect(settings.aiModes.first?.id == BuiltInAIModes.migratedPromptID)

        // A later edit of the legacy key (or clearing it) no longer changes the modes.
        settings.aiPrompt = "Coś zupełnie innego"
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiModes.count == 6)
        #expect(reloaded.aiModes.first?.prompt == Self.customPrompt)
        reloaded.aiPrompt = ""
        #expect(reloaded.aiModes.count == 6)
    }

    @Test func defaultOrBlankLegacyPromptAddsNoMode() throws {
        for legacy in ["", "   \n", CleanupPrompt.defaultTemplate, "\n" + CleanupPrompt.defaultTemplate + "\n"] {
            let defaults = try makeDefaults()
            defaults.set(legacy, forKey: "ai.prompt")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.aiModes.count == BuiltInAIModes.all.count)
            #expect(settings.aiActiveModeID == BuiltInAIModes.cleanupID)
        }
    }

    // MARK: CRUD

    @Test func addUpdateDuplicateDelete() throws {
        let settings = try makeSettings()

        var draft = AIMode.newCustom()
        draft.deadlineSeconds = 50
        draft.builtInKey = "english"
        let added = settings.addMode(draft)
        #expect(added.id != draft.id)
        #expect(added.builtInKey == nil)
        #expect(added.deadlineSeconds == 20)
        #expect(settings.aiModes.last == added)
        #expect(added.kind == .rewrite)
        #expect(added.prompt.contains(CleanupPrompt.dictionaryPlaceholder))

        var edited = added
        edited.name = "LinkedIn"
        edited.deadlineSeconds = 0.2
        edited.builtInKey = "cleanup"
        settings.updateMode(edited)
        let stored = try #require(settings.mode(id: added.id))
        #expect(stored.name == "LinkedIn")
        #expect(stored.deadlineSeconds == 1)
        #expect(stored.builtInKey == nil, "update never turns a custom mode into a built-in")

        // Editing a built-in keeps its key, so "Przywróć domyślne tryby" can find it again.
        var english = try #require(settings.mode(id: BuiltInAIModes.englishID))
        english.prompt = "Translate to British English."
        english.builtInKey = nil
        settings.updateMode(english)
        #expect(settings.mode(id: BuiltInAIModes.englishID)?.builtInKey == BuiltInAIModes.Key.english)

        let copy = try #require(settings.duplicateMode(id: BuiltInAIModes.englishID))
        #expect(copy.id != BuiltInAIModes.englishID)
        #expect(copy.builtInKey == nil)
        #expect(copy.name == String(localized: "\(BuiltInAIModes.english.name) (kopia)"))
        #expect(copy.prompt == "Translate to British English.")
        let englishIndex = try #require(settings.aiModes.firstIndex { $0.id == BuiltInAIModes.englishID })
        #expect(settings.aiModes[englishIndex + 1].id == copy.id)
        #expect(settings.duplicateMode(id: UUID()) == nil)

        settings.aiActiveModeID = copy.id
        #expect(settings.deleteMode(id: copy.id))
        #expect(settings.mode(id: copy.id) == nil)
        #expect(settings.aiActiveModeID == BuiltInAIModes.cleanupID, "deleting the active mode falls back to Czyszczenie")
        #expect(!settings.deleteMode(id: UUID()))
    }

    @Test func theLastModeCannotBeDeleted() throws {
        let settings = try makeSettings()
        for mode in settings.aiModes.dropFirst() {
            #expect(settings.deleteMode(id: mode.id))
        }
        let last = try #require(settings.aiModes.first)
        #expect(!settings.deleteMode(id: last.id))
        #expect(settings.aiModes.count == 1)
    }

    @Test func deletingCleanupWhileActiveFallsBackToTheFirstMode() throws {
        let settings = try makeSettings()
        #expect(settings.deleteMode(id: BuiltInAIModes.cleanupID))
        #expect(settings.activeMode.id == BuiltInAIModes.englishID)
        #expect(settings.aiActiveModeID == BuiltInAIModes.englishID)
    }

    @Test func moveFollowsListOnMoveSemantics() throws {
        let settings = try makeSettings()
        let ids = BuiltInAIModes.all.map(\.id)
        // Move "Czyszczenie" (0) to the end.
        settings.moveModes(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        #expect(settings.aiModes.map(\.id) == Array(ids[1...]) + [ids[0]])
        // Move the last two to the top.
        settings.moveModes(fromOffsets: IndexSet([3, 4]), toOffset: 0)
        #expect(settings.aiModes.map(\.id) == [ids[4], ids[0], ids[1], ids[2], ids[3]])

        settings.moveMode(id: ids[3], by: -1)
        #expect(settings.aiModes.map(\.id) == [ids[4], ids[0], ids[1], ids[3], ids[2]])
        settings.moveMode(id: ids[4], by: -1)
        #expect(settings.aiModes.first?.id == ids[4], "clamped at the top")
    }

    // MARK: Restore defaults

    @Test func restoreDefaultsRebuildsBuiltInsAndKeepsCustomModes() throws {
        let settings = try makeSettings()
        let custom = settings.addMode(AIMode(name: "Twitter", prompt: "Short tweet. {DICTIONARY}", kind: .rewrite, deadlineSeconds: 5))
        var english = try #require(settings.mode(id: BuiltInAIModes.englishID))
        english.name = "EN"
        english.prompt = "zepsuty prompt"
        english.kind = .cleanup
        english.deadlineSeconds = 19
        settings.updateMode(english)
        #expect(settings.deleteMode(id: BuiltInAIModes.emailID))
        settings.aiActiveModeID = BuiltInAIModes.englishID

        settings.restoreDefaultModes()

        let modes = settings.aiModes
        #expect(modes.contains(custom))
        #expect(settings.mode(id: BuiltInAIModes.englishID) == BuiltInAIModes.english)
        #expect(modes.filter { $0.builtInKey == BuiltInAIModes.Key.email }.count == 1)
        #expect(modes.last?.builtInKey == BuiltInAIModes.Key.email, "a deleted built-in comes back at the end")
        #expect(Set(modes.compactMap(\.builtInKey)) == Set(BuiltInAIModes.all.compactMap(\.builtInKey)))
        #expect(modes.count == BuiltInAIModes.all.count + 1)
        #expect(settings.activeMode.id == BuiltInAIModes.englishID, "the selection survives the restore")

        // Idempotent.
        settings.restoreDefaultModes()
        #expect(settings.aiModes == modes)
    }

    @Test func resetForgetsModesAndSelection() throws {
        let settings = try makeSettings()
        settings.addMode()
        settings.aiActiveModeID = BuiltInAIModes.tasksID
        settings.reset()
        #expect(settings.aiModes == BuiltInAIModes.all)
        #expect(settings.aiActiveModeID == BuiltInAIModes.cleanupID)
    }

    @Test func modesRoundTripThroughDefaults() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let added = settings.addMode(AIMode(name: "Notatka", symbol: "note.text", prompt: "p", kind: .rewrite, deadlineSeconds: 4.5))
        settings.aiActiveModeID = added.id
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiModes == settings.aiModes)
        #expect(reloaded.activeMode == added)
    }
}
