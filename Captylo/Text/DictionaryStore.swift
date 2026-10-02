import Foundation
import Observation

/// Owner of `dictionary.json` (brief 4.7). Every mutation saves the file atomically and rebuilds
/// `processor`, so the pipeline always gets a ready snapshot. Main-actor only; pass `processor`
/// (a Sendable value) into the dictation pipeline.
@MainActor
@Observable
final class DictionaryStore {
    static let maxVocabularyLength = 60

    private(set) var data: DictionaryData
    private(set) var processor: TextProcessor
    private(set) var paragraphs: Bool
    /// Where an unreadable `dictionary.json` was moved at launch, so the next save cannot
    /// overwrite the user's words and rules. The Słownik screen offers it for re-import.
    private(set) var corruptBackupURL: URL?
    /// Set while the last save of `dictionary.json` failed (disk full, permissions, read-only
    /// volume): the changes work until quit but would be lost on the next launch.
    private(set) var saveError: String?

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppPaths.dictionaryJSON, paragraphs: Bool) {
        self.fileURL = fileURL
        self.paragraphs = paragraphs
        let loaded = Self.load(from: fileURL)
        data = loaded.data
        corruptBackupURL = loaded.backup
        processor = TextProcessor(dictionary: loaded.data, paragraphs: paragraphs)
    }

    /// Hides the "słownik uszkodzony" notice (the backup file stays on disk).
    func dismissCorruptBackupNotice() {
        corruptBackupURL = nil
    }

    /// Mirrors the "Akapity" setting; rebuilds the processor without touching the file.
    func setParagraphs(_ enabled: Bool) {
        guard paragraphs != enabled else { return }
        paragraphs = enabled
        processor = TextProcessor(dictionary: data, paragraphs: enabled)
    }

    // MARK: - Vocabulary

    /// Splits on commas and newlines, trims, drops empties and entries over 60 characters,
    /// dedupes case-insensitively against the list. Returns a Polish error when nothing was added.
    func addVocabulary(_ commaSeparated: String) -> String? {
        let candidates = commaSeparated
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else {
            return String(localized: "Wpisz słowo lub frazę.")
        }
        let accepted = candidates.filter { $0.count <= Self.maxVocabularyLength }
        guard !accepted.isEmpty else {
            return String(localized: "Maksymalnie \(Self.maxVocabularyLength) znaków na słowo.")
        }
        let added = mergeVocabulary(accepted)
        guard added > 0 else {
            if accepted.count == 1 {
                return String(localized: "„\(accepted[0])” jest już w słowniku.")
            }
            return String(localized: "Wszystkie te słowa są już w słowniku.")
        }
        return commit()
    }

    func removeVocabulary(_ word: String) {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let before = data.vocabulary.count
        data.vocabulary.removeAll { $0.lowercased() == key }
        if data.vocabulary.count != before {
            commit()
        }
    }

    func containsVocabulary(_ word: String) -> Bool {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return data.vocabulary.contains { $0.lowercased() == key }
    }

    /// Self-learning: adds one word; true when it was new and saved (undo removes only those).
    @discardableResult
    func addLearnedVocabulary(_ word: String) -> Bool {
        guard mergeVocabulary([word]) > 0 else { return false }
        return commit() == nil
    }

    // MARK: - Replacements

    /// Inserts or updates a rule. Triggers are trimmed, deduped and must be unique across the
    /// other rules (case-insensitive); the replacement is trimmed but may span several lines.
    func upsert(_ rule: ReplacementRule) -> String? {
        let triggers = Self.normalizedTriggers(rule.triggers)
        guard !triggers.isEmpty else {
            return String(localized: "Podaj przynajmniej jedno słowo do zamiany.")
        }
        let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else {
            return String(localized: "Podaj tekst zamiany.")
        }
        if let conflict = firstConflict(among: triggers, excluding: rule.id) {
            return String(localized: "„\(conflict)” jest już używane w innej regule.")
        }
        let normalized = ReplacementRule(id: rule.id, triggers: triggers, replacement: replacement)
        if let index = data.replacements.firstIndex(where: { $0.id == rule.id }) {
            data.replacements[index] = normalized
        } else {
            data.replacements.append(normalized)
        }
        return commit()
    }

    func removeRule(_ id: UUID) {
        let before = data.replacements.count
        data.replacements.removeAll { $0.id == id }
        if data.replacements.count != before {
            commit()
        }
    }

    // MARK: - Fillers

    /// Replaces the filler list (lowercased, trimmed, deduped). An empty list turns removal off.
    func setFillers(_ words: [String]) {
        data.fillerWords = Self.normalizedFillers(words)
        commit()
    }

    // MARK: - Import / export

    /// Accepts the v2 `dictionary.json` shape or the old v1 backup (`vocabularyWords`,
    /// `wordReplacements`). Merges and never deletes. Returns the number of new items.
    func importJSON(from url: URL) throws -> Int {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw DictionaryImportError.unreadable
        }
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw DictionaryImportError.invalidFormat
        }
        let isV1 = object["vocabularyWords"] != nil || object["wordReplacements"] != nil
        let isV2 = object["vocabulary"] != nil || object["replacements"] != nil || object["fillerWords"] != nil
        guard isV1 || isV2 else {
            throw DictionaryImportError.invalidFormat
        }

        var added = 0
        if isV1 {
            added += mergeVocabulary(Self.v1Vocabulary(object["vocabularyWords"]))
            added += mergeRules(Self.v1Rules(object["wordReplacements"]))
        } else {
            let imported: DictionaryData
            do {
                imported = try JSONDecoder().decode(DictionaryData.self, from: raw)
            } catch {
                throw DictionaryImportError.invalidFormat
            }
            added += mergeVocabulary(imported.vocabulary)
            added += mergeRules(imported.replacements)
            if object["fillerWords"] != nil {
                added += mergeFillers(imported.fillerWords)
            }
        }
        if added > 0, commit() != nil {
            throw DictionaryImportError.saveFailed
        }
        return added
    }

    func exportJSON(to url: URL) throws {
        try Self.encoded(data).write(to: url, options: .atomic)
    }

    // MARK: - Merge helpers

    @discardableResult
    private func mergeVocabulary(_ words: [String]) -> Int {
        var known = Set(data.vocabulary.map { $0.lowercased() })
        var added = 0
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= Self.maxVocabularyLength, known.insert(word.lowercased()).inserted else {
                continue
            }
            data.vocabulary.append(word)
            added += 1
        }
        return added
    }

    /// Skips rules with no usable trigger, an empty replacement, or any trigger already in use.
    private func mergeRules(_ rules: [ReplacementRule]) -> Int {
        var added = 0
        for rule in rules {
            let triggers = Self.normalizedTriggers(rule.triggers)
            let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !triggers.isEmpty, !replacement.isEmpty else { continue }
            guard firstConflict(among: triggers, excluding: nil) == nil else { continue }
            let id = data.replacements.contains { $0.id == rule.id } ? UUID() : rule.id
            data.replacements.append(ReplacementRule(id: id, triggers: triggers, replacement: replacement))
            added += 1
        }
        return added
    }

    private func mergeFillers(_ fillers: [String]) -> Int {
        let merged = Self.normalizedFillers(data.fillerWords + fillers)
        let added = merged.count - data.fillerWords.count
        data.fillerWords = merged
        return added
    }

    private func firstConflict(among triggers: [String], excluding id: UUID?) -> String? {
        var used = Set<String>()
        for rule in data.replacements where rule.id != id {
            for trigger in rule.triggers {
                used.insert(trigger.lowercased())
            }
        }
        return triggers.first { used.contains($0.lowercased()) }
    }

    /// Trimmed, inner whitespace collapsed, empties dropped, deduped case-insensitively.
    nonisolated static func normalizedTriggers(_ triggers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in triggers {
            let trigger = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !trigger.isEmpty, seen.insert(trigger.lowercased()).inserted else { continue }
            result.append(trigger)
        }
        return result
    }

    static func normalizedFillers(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in words {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            result.append(word)
        }
        return result
    }

    // MARK: - v1 backup shapes

    /// `[{"word": "X", ...}]` or a plain `["X"]`.
    private static func v1Vocabulary(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            if let entry = item as? [String: Any] { return entry["word"] as? String }
            return item as? String
        }
    }

    /// `[{"originalText": "a, b", "replacementText": "X", "isEnabled": true}]` or `{"a, b": "X"}`.
    private static func v1Rules(_ value: Any?) -> [ReplacementRule] {
        if let entries = value as? [[String: Any]] {
            return entries.compactMap { entry in
                guard let original = entry["originalText"] as? String,
                      let replacement = entry["replacementText"] as? String else { return nil }
                if let enabled = entry["isEnabled"] as? Bool, !enabled { return nil }
                return ReplacementRule(triggers: splitTriggers(original), replacement: replacement)
            }
        }
        if let map = value as? [String: String] {
            return map.keys.sorted().map { ReplacementRule(triggers: splitTriggers($0), replacement: map[$0] ?? "") }
        }
        return []
    }

    private static func splitTriggers(_ commaSeparated: String) -> [String] {
        commaSeparated.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Persistence

    /// Rebuilds the processor and saves. The in-memory state stays valid either way; a failed save
    /// is kept in `saveError` (the Słownik screen shows it with a retry) and returned, so the
    /// action that caused it can report it inline instead of claiming success.
    @discardableResult
    private func commit() -> String? {
        processor = TextProcessor(dictionary: data, paragraphs: paragraphs)
        do {
            try save()
            saveError = nil
            return nil
        } catch {
            Log.data.error("Dictionary save failed: \(error.localizedDescription, privacy: .public)")
            let message = DictionaryImportError.saveFailed.errorDescription
            saveError = message
            return message
        }
    }

    /// Writes the current dictionary again after a failed save.
    func retrySave() {
        commit()
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoded(data).write(to: fileURL, options: .atomic)
    }

    private static func encoded(_ data: DictionaryData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }

    /// Missing file -> defaults. Corrupt file -> defaults in memory, and the file is moved aside to
    /// `dictionary.corrupt-<date>.json` before any save can replace it (returned as `backup`).
    private static func load(from url: URL) -> (data: DictionaryData, backup: URL?) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return (.default, nil)
        }
        do {
            let raw = try Data(contentsOf: url)
            var loaded = try JSONDecoder().decode(DictionaryData.self, from: raw)
            loaded.fillerWords = normalizedFillers(loaded.fillerWords)
            return (loaded, nil)
        } catch {
            Log.data.error("Dictionary load failed, using defaults: \(error.localizedDescription, privacy: .public)")
            return (.default, moveAside(url))
        }
    }

    /// Renames the unreadable file next to itself; nil when even that fails (then it is only logged).
    private static func moveAside(_ url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appending(path: "\(stem).corrupt-\(formatter.string(from: Date())).json")
        do {
            if FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.moveItem(at: url, to: backup)
            Log.data.notice("Moved the unreadable dictionary to \(backup.lastPathComponent, privacy: .public)")
            return backup
        } catch {
            Log.data.error("Could not move the unreadable dictionary aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
