import Foundation

/// "a, b -> X": every trigger is replaced by `replacement` (whole word, case-insensitive).
struct ReplacementRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var triggers: [String]
    var replacement: String

    init(id: UUID = UUID(), triggers: [String], replacement: String) {
        self.id = id
        self.triggers = triggers
        self.replacement = replacement
    }

    private enum CodingKeys: String, CodingKey {
        case id, triggers, replacement
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        triggers = try container.decodeIfPresent([String].self, forKey: .triggers) ?? []
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
    }
}

/// Contents of `dictionary.json` (v2 format). Missing keys decode to their defaults so a
/// partial file still loads; v1 backups (`vocabularyWords` / `wordReplacements`) are handled by `DictionaryStore`.
struct DictionaryData: Codable, Hashable, Sendable {
    static let currentVersion = 1

    /// Non-words only (gotcha 77). Real Polish words ("no", "jakby", "wiesz") are never removed deterministically.
    static let defaultFillerWords: [String] = ["yyy", "yy", "eee", "ee", "mmm", "hmm", "hm", "um", "uh", "uhm"]

    var version: Int
    /// Hints for cloud STT keyterms and the AI prompt. The local model gets none (a Whisper
    /// prompt dropped words on a real meeting, see `WhisperEngine.init`).
    var vocabulary: [String]
    var replacements: [ReplacementRule]
    var fillerWords: [String]

    init(
        version: Int = DictionaryData.currentVersion,
        vocabulary: [String] = [],
        replacements: [ReplacementRule] = [],
        fillerWords: [String] = DictionaryData.defaultFillerWords
    ) {
        self.version = version
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.fillerWords = fillerWords
    }

    /// Fresh dictionary with the default fillers and nothing else.
    static let `default` = DictionaryData()

    private enum CodingKeys: String, CodingKey {
        case version, vocabulary, replacements, fillerWords
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? DictionaryData.currentVersion
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        replacements = try container.decodeIfPresent([ReplacementRule].self, forKey: .replacements) ?? []
        fillerWords = try container.decodeIfPresent([String].self, forKey: .fillerWords) ?? DictionaryData.defaultFillerWords
    }
}
