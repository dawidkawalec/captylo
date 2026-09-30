import CryptoKit
import Foundation

/// What to do with one old row.
enum LegacyRowDecision: Sendable, Equatable {
    case importRow(LegacyMappedRow)
    /// No text and not failed: nothing worth keeping.
    case skipEmpty
    /// The old app's model warm-up rows ("[PREWARM] "), never real dictations.
    case skipPrewarm
}

/// An old row mapped to the Captylo shape. `record.audioFileName` stays nil until the importer
/// has linked `sourceAudioFileName` into `Recordings/`.
struct LegacyMappedRow: Sendable, Equatable {
    var record: DictationRecord
    /// File name of the old recording (`<UUID>.wav`), nil when the row had none.
    var sourceAudioFileName: String?

    /// One `UsageStat` per completed row, like a fresh dictation (gotcha 82).
    var createsUsageStat: Bool { record.status == .completed }
    var hasAI: Bool { record.enhancedText != nil }
}

/// Pure mapping of the old `ZTRANSCRIPTION` rows (brief Appendix A, refined on the real store).
enum LegacyMapper {
    static let failedTranscriptionPrefix = "Transcription Failed:"
    static let failedEnhancementPrefix = "Enhancement failed:"
    static let prewarmPrefix = "[PREWARM]"

    /// Maps one row. `sourcePath` (the original store path) seeds the id of a row without `ZID`.
    static func map(_ row: LegacyRow, sourcePath: String) -> LegacyRowDecision {
        let text = trimmed(row.text) ?? ""
        if text.hasPrefix(prewarmPrefix) {
            return .skipPrewarm
        }
        let status = row.status?.lowercased() ?? ""
        let isFailed = status == DictationStatus.failed.rawValue || text.hasPrefix(failedTranscriptionPrefix)
        if !isFailed, text.isEmpty {
            return .skipEmpty
        }

        var record = DictationRecord(
            id: row.id ?? deterministicID(sourcePath: sourcePath, pk: row.pk),
            createdAt: Date(timeIntervalSinceReferenceDate: row.timestamp ?? 0),
            text: isFailed ? "" : text,
            status: isFailed ? .failed : .completed,
            errorMessage: isFailed ? (text.isEmpty ? String(localized: "Transkrypcja nie powiodła się.") : text) : nil,
            source: .imported,
            audioDuration: max(row.duration ?? 0, 0),
            audioFileName: nil,
            language: nil,
            modelName: trimmed(row.transcriptionModelName),
            transcriptionMs: milliseconds(row.transcriptionDuration)
        )

        // A failed transcription never had AI; a completed one keeps the AI fields only when AI
        // actually ran (text or failure), so "Bez AI" rows stay plain in Historia.
        if !isFailed {
            let enhanced = trimmed(row.enhancedText)
            if let enhanced, enhanced.hasPrefix(failedEnhancementPrefix) {
                record.enhancementNote = enhanced
            } else if let enhanced {
                record.enhancedText = enhanced
            }
            if record.enhancedText != nil || record.enhancementNote != nil {
                record.enhancementModel = trimmed(row.enhancementModelName)
                record.enhancementMs = milliseconds(row.enhancementDuration)
                record.enhancementMode = trimmed(row.promptName) ?? trimmed(row.powerModeName)
            }
        }
        // The old dashboard rule, so the imported totals match what the owner saw there.
        record.wordCount = WordCounter.legacyCount(record.enhancedText ?? record.text)

        return .importRow(LegacyMappedRow(record: record, sourceAudioFileName: audioFileName(from: row.audioFileURL)))
    }

    /// `file:///.../Recordings/<UUID>.wav` -> `<UUID>.wav` (percent-decoded). Accepts a plain path
    /// too; anything that is not a bare file name is rejected.
    static func audioFileName(from urlString: String?) -> String? {
        guard let raw = trimmed(urlString) else { return nil }
        let name = URL(string: raw)?.lastPathComponent ?? (raw as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", !name.hasPrefix("."), !name.contains("/") else { return nil }
        return name
    }

    /// Name-based id (UUID version 5 layout over SHA-256) for a row without `ZID`: the same store
    /// and `Z_PK` give the same id on every run, so a re-import skips the row.
    static func deterministicID(sourcePath: String, pk: Int64) -> UUID {
        let digest = SHA256.hash(data: Data("captylo.legacy:\(sourcePath)#\(pk)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    // MARK: Dictionary

    /// Trimmed, non-empty, deduped case-insensitively, first spelling wins.
    static func vocabulary(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in words {
            guard let word = trimmed(raw), seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// Enabled rows grouped by replacement text: "a, b -> X" and "c -> X" become one rule with the
    /// triggers a, b, c. Disabled rows and empty replacements are dropped.
    static func rules(_ rows: [LegacyReplacementRow]) -> [ReplacementRule] {
        var order: [String] = []
        var triggers: [String: [String]] = [:]
        for row in rows where row.isEnabled {
            guard let replacement = trimmed(row.replacement) else { continue }
            let parts = row.original
                .components(separatedBy: ",")
                .compactMap { trimmed($0) }
            guard !parts.isEmpty else { continue }
            if triggers[replacement] == nil {
                order.append(replacement)
            }
            triggers[replacement, default: []].append(contentsOf: parts)
        }
        return order.compactMap { replacement in
            let unique = DictionaryStore.normalizedTriggers(triggers[replacement] ?? [])
            return unique.isEmpty ? nil : ReplacementRule(triggers: unique, replacement: replacement)
        }
    }

    // MARK: Helpers

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Seconds -> whole milliseconds; nil for a missing or negative value.
    private static func milliseconds(_ seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
