import Foundation

/// `legacy-import.json` next to the store: when the last real import finished and what it did.
/// It lives in the data folder (not in the defaults), so a `CAPTYLO_DATA_DIR` run never marks
/// the user's real data as imported.
struct LegacyImportMarker: Codable, Sendable, Equatable {
    static let fileName = "legacy-import.json"

    var importedAt: Date
    var report: LegacyImportReport

    static var defaultURL: URL { AppPaths.dataDirectory.appending(path: fileName) }

    static func load(from url: URL = defaultURL) -> LegacyImportMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LegacyImportMarker.self, from: data)
    }

    func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
