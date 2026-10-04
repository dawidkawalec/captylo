import Foundation
import Testing
@testable import Captylo

@MainActor
struct DictionaryStoreTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptyloTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var fileURL: URL { directory.appending(path: "dictionary.json") }

    private func makeStore(paragraphs: Bool = true) -> DictionaryStore {
        DictionaryStore(fileURL: fileURL, paragraphs: paragraphs)
    }

    private func write(_ json: String, to name: String = "import.json") throws -> URL {
        let url = directory.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: Save failures

    @Test func saveFailuresAreReportedInsteadOfSwallowed() throws {
        // The parent "folder" is a regular file, so every save of dictionary.json fails.
        let blocker = directory.appending(path: "blocker")
        try Data("x".utf8).write(to: blocker)
        let store = DictionaryStore(fileURL: blocker.appending(path: "dictionary.json"), paragraphs: true)
        let failure = DictionaryImportError.saveFailed.errorDescription

        #expect(store.addVocabulary("Captylo") == failure)
        #expect(store.data.vocabulary.contains("Captylo"), "the change still works in memory")
        #expect(store.saveError == failure)

        #expect(store.upsert(ReplacementRule(triggers: ["kap tylo"], replacement: "Captylo")) == failure)

        let json = try write(#"{"vocabulary": ["Kawalec"]}"#)
        #expect(throws: DictionaryImportError.saveFailed) { try store.importJSON(from: json) }

        // Once the path is writable again, a retry clears the error.
        try FileManager.default.removeItem(at: blocker)
        store.retrySave()
        #expect(store.saveError == nil)
        #expect(FileManager.default.fileExists(atPath: blocker.appending(path: "dictionary.json").path))
    }

    // MARK: Loading

    @Test func missingFileLoadsDefaults() {
        let store = makeStore()
        #expect(store.data == .default)
        #expect(store.data.fillerWords == DictionaryData.defaultFillerWords)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    @Test func corruptFileIsMovedAsideBeforeTheNextSave() throws {
        let original = Data(#"{"vocabulary": ["Kawalec", "#.utf8)
        try original.write(to: fileURL)
        let store = makeStore()
        #expect(store.data == .default)
        let backup = try #require(store.corruptBackupURL)
        #expect(backup.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(backup.lastPathComponent.hasPrefix("dictionary.corrupt-"))
        #expect(try Data(contentsOf: backup) == original, "the user's file survives byte for byte")

        #expect(store.addVocabulary("Captylo") == nil)
        #expect(try Data(contentsOf: backup) == original, "a save never touches the backup")
        #expect(makeStore().data.vocabulary == ["Captylo"])
        #expect(makeStore().corruptBackupURL == nil)

        store.dismissCorruptBackupNotice()
        #expect(store.corruptBackupURL == nil)
    }

    @Test func partialFileFillsMissingKeys() throws {
        try Data(#"{"vocabulary": ["Kawalec"]}"#.utf8).write(to: fileURL)
        let store = makeStore()
        #expect(store.data.vocabulary == ["Kawalec"])
        #expect(store.data.replacements.isEmpty)
        #expect(store.data.fillerWords == DictionaryData.defaultFillerWords)
    }

    // MARK: Vocabulary

    @Test func addVocabularySplitsTrimsAndDedupes() throws {
        let store = makeStore()
        #expect(store.addVocabulary(" Kawalec, CraftWeb \nCaptylo,, ") == nil)
        #expect(store.data.vocabulary == ["Kawalec", "CraftWeb", "Captylo"])
        #expect(store.addVocabulary("kawalec") == "„kawalec” jest już w słowniku.")
        #expect(store.addVocabulary("KAWALEC, craftweb") == "Wszystkie te słowa są już w słowniku.")
        #expect(store.addVocabulary(" , ") == "Wpisz słowo lub frazę.")
        #expect(store.addVocabulary(String(repeating: "a", count: 61)) == "Maksymalnie 60 znaków na słowo.")
        #expect(store.addVocabulary("Nowe, kawalec") == nil)
        #expect(store.data.vocabulary.count == 4)

        let reloaded = makeStore()
        #expect(reloaded.data.vocabulary == ["Kawalec", "CraftWeb", "Captylo", "Nowe"])
    }

    @Test func removeVocabularyIsCaseInsensitive() {
        let store = makeStore()
        _ = store.addVocabulary("Kawalec, CraftWeb")
        store.removeVocabulary("KAWALEC")
        #expect(store.data.vocabulary == ["CraftWeb"])
        #expect(makeStore().data.vocabulary == ["CraftWeb"])
    }

    // MARK: Replacements

    @Test func upsertValidatesAndRebuildsTheProcessor() {
        let store = makeStore()
        let rule = ReplacementRule(triggers: [" kap tylo ", "kaptilo", "KAP TYLO", ""], replacement: " Captylo ")
        #expect(store.upsert(rule) == nil)
        #expect(store.data.replacements.count == 1)
        #expect(store.data.replacements[0].triggers == ["kap tylo", "kaptilo"])
        #expect(store.data.replacements[0].replacement == "Captylo")
        #expect(store.processor.process("to kap tylo") == "to Captylo")

        #expect(store.upsert(ReplacementRule(triggers: [""], replacement: "X")) == "Podaj przynajmniej jedno słowo do zamiany.")
        #expect(store.upsert(ReplacementRule(triggers: ["abc"], replacement: "  ")) == "Podaj tekst zamiany.")
        let conflict = store.upsert(ReplacementRule(triggers: ["inne", "Kaptilo"], replacement: "X"))
        #expect(conflict == "„Kaptilo” jest już używane w innej regule.")
        #expect(store.data.replacements.count == 1)
    }

    @Test func upsertUpdatesAnExistingRuleWithoutConflictingWithItself() {
        let store = makeStore()
        var rule = ReplacementRule(triggers: ["kawalec"], replacement: "Kawalec")
        #expect(store.upsert(rule) == nil)
        rule.triggers = ["kawalec", "kawalecki"]
        rule.replacement = "Firma\nsp. z o.o."
        #expect(store.upsert(rule) == nil)
        #expect(store.data.replacements.count == 1)
        #expect(store.data.replacements[0].replacement == "Firma\nsp. z o.o.")
        #expect(store.processor.process("pan kawalecki") == "pan Firma\nsp. z o.o.")
        #expect(makeStore().data.replacements == store.data.replacements)
    }

    @Test func removeRuleDeletesById() {
        let store = makeStore()
        let rule = ReplacementRule(triggers: ["a"], replacement: "b")
        _ = store.upsert(rule)
        store.removeRule(rule.id)
        #expect(store.data.replacements.isEmpty)
        #expect(store.processor.process("a") == "a")
    }

    // MARK: Fillers and paragraphs

    @Test func setFillersNormalizesAndAffectsProcessing() {
        let store = makeStore()
        store.setFillers([" Yyy ", "yyy", "", "no"])
        #expect(store.data.fillerWords == ["yyy", "no"])
        #expect(store.processor.process("no yyy tak") == "Tak")
        store.setFillers([])
        #expect(store.processor.process("yyy tak") == "yyy tak")
    }

    @Test func setParagraphsRebuildsProcessor() {
        let store = makeStore(paragraphs: false)
        let text = Array(repeating: "To jest zdanie numer jeden w tekście.", count: 5).joined(separator: " ")
        #expect(store.processor.process(text) == text)
        store.setParagraphs(true)
        #expect(store.processor.process(text).contains("\n\n"))
        #expect(store.paragraphs)
    }

    // MARK: Import / export

    @Test func importsV1BackupWithArrayRules() throws {
        let store = makeStore()
        _ = store.addVocabulary("Kawalec")
        let url = try write("""
        {
          "version": "1.64",
          "vocabularyWords": [{"word": "Kawalec", "dateAdded": 1}, {"word": "CraftWeb"}, {"word": ""}],
          "wordReplacements": [
            {"originalText": "craft web, craftweb", "replacementText": "CraftWeb", "isEnabled": true},
            {"originalText": "off", "replacementText": "Wyłączone", "isEnabled": false},
            {"originalText": "puste", "replacementText": ""}
          ],
          "generalSettings": {"isTextFormattingEnabled": true}
        }
        """)
        let added = try store.importJSON(from: url)
        #expect(added == 2)
        #expect(store.data.vocabulary == ["Kawalec", "CraftWeb"])
        #expect(store.data.replacements.count == 1)
        #expect(store.data.replacements[0].triggers == ["craft web", "craftweb"])
        #expect(store.processor.process("craft web") == "CraftWeb")
        #expect(try store.importJSON(from: url) == 0)
    }

    @Test func importsV1BackupWithDictionaryRules() throws {
        let store = makeStore()
        let url = try write("""
        {"wordReplacements": {"voice ink": "Captylo", "kawalec": "Kawalec"}}
        """)
        #expect(try store.importJSON(from: url) == 2)
        #expect(store.data.replacements.map(\.replacement) == ["Kawalec", "Captylo"])
    }

    @Test func importsV2MergingWithoutDeleting() throws {
        let store = makeStore()
        _ = store.addVocabulary("Kawalec")
        _ = store.upsert(ReplacementRule(triggers: ["kawalec"], replacement: "Kawalec"))
        store.setFillers(["yyy"])
        let url = try write("""
        {
          "version": 1,
          "vocabulary": ["kawalec", "CraftWeb"],
          "replacements": [
            {"triggers": ["Kawalec"], "replacement": "Kolizja"},
            {"triggers": ["kap tylo"], "replacement": "Captylo"}
          ],
          "fillerWords": ["yyy", "eee"]
        }
        """)
        #expect(try store.importJSON(from: url) == 3)
        #expect(store.data.vocabulary == ["Kawalec", "CraftWeb"])
        #expect(store.data.replacements.map(\.replacement) == ["Kawalec", "Captylo"])
        #expect(store.data.fillerWords == ["yyy", "eee"])
    }

    @Test func importRejectsForeignAndUnreadableFiles() throws {
        let store = makeStore()
        let foreign = try write(#"{"hello": "world"}"#)
        #expect(throws: DictionaryImportError.invalidFormat) { try store.importJSON(from: foreign) }
        let broken = try write("[1, 2", to: "broken.json")
        #expect(throws: DictionaryImportError.invalidFormat) { try store.importJSON(from: broken) }
        let missing = directory.appending(path: "missing.json")
        #expect(throws: DictionaryImportError.unreadable) { try store.importJSON(from: missing) }
    }

    @Test func exportRoundTrips() throws {
        let store = makeStore()
        _ = store.addVocabulary("Kawalec, CraftWeb")
        _ = store.upsert(ReplacementRule(triggers: ["kap tylo"], replacement: "Captylo\n$5 \\ ok"))
        store.setFillers(["yyy", "eee"])
        let url = directory.appending(path: "export.json")
        try store.exportJSON(to: url)

        let otherDirectory = directory.appending(path: "other", directoryHint: .isDirectory)
        let other = DictionaryStore(fileURL: otherDirectory.appending(path: "dictionary.json"), paragraphs: true)
        #expect(try other.importJSON(from: url) == 3)
        #expect(other.data.vocabulary == store.data.vocabulary)
        #expect(other.data.replacements == store.data.replacements)
        #expect(Set(store.data.fillerWords).isSubset(of: Set(other.data.fillerWords)))
        #expect(other.processor.process("kap tylo") == "Captylo\n$5 \\ ok")

        let decoded = try JSONDecoder().decode(DictionaryData.self, from: Data(contentsOf: url))
        #expect(decoded == store.data)
    }
}
