import Foundation

/// History export (gotcha 84): UTF-8 with BOM, ISO 8601 dates, a field is quoted whenever it
/// contains a quote, a comma, CR or LF, and inner quotes are doubled.
enum CSV {
    static let bom = "\u{FEFF}"
    static let header = ["id", "createdAt", "duration", "text", "enhancedText", "model", "status"]
    static let lineBreak = "\n"

    /// Whole document for the given rows, in the order given.
    static func document(_ records: [DictationRecord]) -> String {
        var lines = [line(header)]
        lines.reserveCapacity(records.count + 1)
        for record in records {
            lines.append(line(fields(for: record)))
        }
        return bom + lines.joined(separator: lineBreak) + lineBreak
    }

    static func fields(for record: DictationRecord) -> [String] {
        [
            record.id.uuidString,
            record.createdAt.ISO8601Format(),
            String(format: "%.1f", record.audioDuration),
            record.text,
            record.enhancedText ?? "",
            record.modelName.map(STTEngine.label(forModelName:)) ?? "",
            record.status.rawValue,
        ]
    }

    static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    static func escape(_ field: String) -> String {
        let needsQuotes = field.contains { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
