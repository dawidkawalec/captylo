import Foundation
import Observation

/// Owner of `learning.json` (self-learning memory, local only). Every `update` saves the file
/// atomically; an unreadable file is moved aside so a save cannot overwrite it. Main-actor only.
@MainActor
@Observable
final class LearningStore {
    private(set) var data: LearningData
    /// Set while the last save failed; the learning keeps working until quit.
    private(set) var saveError: String?

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppPaths.learningJSON) {
        self.fileURL = fileURL
        data = Self.load(from: fileURL)
    }

    /// Mutates the memory and saves it.
    func update(_ change: (inout LearningData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        data = copy
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(copy).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            Log.learning.error("Learning save failed: \(error.localizedDescription, privacy: .public)")
            saveError = error.localizedDescription
        }
    }

    /// Forgets everything learned (Słownik "Wyczyść naukę"). The dictionary is cleaned by the caller.
    func reset() {
        update { $0 = .empty }
    }

    private static func load(from url: URL) -> LearningData {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LearningData.self, from: Data(contentsOf: url))
        } catch {
            Log.learning.error("Learning load failed, starting empty: \(error.localizedDescription, privacy: .public)")
            let backup = url.deletingLastPathComponent()
                .appending(path: "learning.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return .empty
        }
    }
}
