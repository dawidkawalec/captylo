import Foundation
import SwiftData

// Brief 4.9. Every property has a default so later schema changes stay lightweight (gotcha 80).
// Models never cross actors: use `DictationRecord` (see the mapping extensions below).

@Model
final class Dictation {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// After `TextProcessor` ("Oryginał"). Never an error message (gotcha 70).
    var text: String = ""
    /// AI output, success only.
    var enhancedText: String? = nil
    /// `completed` | `failed`
    var status: String = "completed"
    var errorMessage: String? = nil
    /// `dictation` | `file` | `imported`
    var source: String = "dictation"
    var audioDuration: Double = 0
    /// `<id>.wav` under `AppPaths.recordings` (gotcha 81).
    var audioFileName: String? = nil
    var language: String? = nil
    var modelName: String? = nil
    var transcriptionMs: Int? = nil
    var enhancementModel: String? = nil
    var enhancementMs: Int? = nil
    /// Name of the AI mode used ("Czyszczenie", "Po angielsku"...). Added with "Tryby AI":
    /// optional with a nil default, so older stores migrate lightweight.
    var enhancementMode: String? = nil
    /// Why AI produced no text ("Brak klucza OpenRouter", "Przekroczono limit 3 s"...).
    var enhancementNote: String? = nil
    /// Of the delivered text (`enhancedText ?? text`).
    var wordCount: Int = 0

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String = "",
        enhancedText: String? = nil,
        status: String = "completed",
        errorMessage: String? = nil,
        source: String = "dictation",
        audioDuration: Double = 0,
        audioFileName: String? = nil,
        language: String? = nil,
        modelName: String? = nil,
        transcriptionMs: Int? = nil,
        enhancementModel: String? = nil,
        enhancementMs: Int? = nil,
        enhancementMode: String? = nil,
        enhancementNote: String? = nil,
        wordCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.enhancedText = enhancedText
        self.status = status
        self.errorMessage = errorMessage
        self.source = source
        self.audioDuration = audioDuration
        self.audioFileName = audioFileName
        self.language = language
        self.modelName = modelName
        self.transcriptionMs = transcriptionMs
        self.enhancementModel = enhancementModel
        self.enhancementMs = enhancementMs
        self.enhancementMode = enhancementMode
        self.enhancementNote = enhancementNote
        self.wordCount = wordCount
    }

    var finalText: String { enhancedText ?? text }
}

/// Append-only; the dashboard reads only this table. History delete and retention never touch it (gotcha 82).
@Model
final class UsageStat {
    var dictationID: UUID = UUID()
    var createdAt: Date = Date()
    var wordCount: Int = 0
    var audioDuration: Double = 0
    var source: String = "dictation"

    init(
        dictationID: UUID = UUID(),
        createdAt: Date = Date(),
        wordCount: Int = 0,
        audioDuration: Double = 0,
        source: String = "dictation"
    ) {
        self.dictationID = dictationID
        self.createdAt = createdAt
        self.wordCount = wordCount
        self.audioDuration = audioDuration
        self.source = source
    }
}

// MARK: - Record mapping

extension Dictation {
    convenience init(_ record: DictationRecord) {
        self.init(
            id: record.id,
            createdAt: record.createdAt,
            text: record.text,
            enhancedText: record.enhancedText,
            status: record.status.rawValue,
            errorMessage: record.errorMessage,
            source: record.source.rawValue,
            audioDuration: record.audioDuration,
            audioFileName: record.audioFileName,
            language: record.language,
            modelName: record.modelName,
            transcriptionMs: record.transcriptionMs,
            enhancementModel: record.enhancementModel,
            enhancementMs: record.enhancementMs,
            enhancementMode: record.enhancementMode,
            enhancementNote: record.enhancementNote,
            wordCount: record.wordCount
        )
    }

    /// Overwrites every field except `id` (retranscribe updates the same row, gotcha 85).
    func apply(_ record: DictationRecord) {
        createdAt = record.createdAt
        text = record.text
        enhancedText = record.enhancedText
        status = record.status.rawValue
        errorMessage = record.errorMessage
        source = record.source.rawValue
        audioDuration = record.audioDuration
        audioFileName = record.audioFileName
        language = record.language
        modelName = record.modelName
        transcriptionMs = record.transcriptionMs
        enhancementModel = record.enhancementModel
        enhancementMs = record.enhancementMs
        enhancementMode = record.enhancementMode
        enhancementNote = record.enhancementNote
        wordCount = record.wordCount
    }

    /// Overwrites only the AI fields ("Przetwórz przez AI"): text, word count and stats stay.
    func applyEnhancement(of record: DictationRecord) {
        enhancedText = record.enhancedText
        enhancementModel = record.enhancementModel
        enhancementMs = record.enhancementMs
        enhancementMode = record.enhancementMode
        enhancementNote = record.enhancementNote
    }

    var record: DictationRecord {
        DictationRecord(
            id: id,
            createdAt: createdAt,
            text: text,
            enhancedText: enhancedText,
            status: DictationStatus(rawValue: status) ?? .completed,
            errorMessage: errorMessage,
            source: DictationSource(rawValue: source) ?? .dictation,
            audioDuration: audioDuration,
            audioFileName: audioFileName,
            language: language,
            modelName: modelName,
            transcriptionMs: transcriptionMs,
            enhancementModel: enhancementModel,
            enhancementMs: enhancementMs,
            enhancementMode: enhancementMode,
            enhancementNote: enhancementNote,
            wordCount: wordCount
        )
    }
}

extension UsageStat {
    convenience init(_ record: DictationRecord) {
        self.init(
            dictationID: record.id,
            createdAt: record.createdAt,
            wordCount: record.wordCount,
            audioDuration: record.audioDuration,
            source: record.source.rawValue
        )
    }
}
