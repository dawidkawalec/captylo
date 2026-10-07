import Foundation
import os

/// One id per installation: the device that last changed a record (sync, M7). `AppState` loads it
/// once at launch; until then (test host, MCP) it is empty, which sync reads as "this Mac".
enum DeviceIdentity {
    static let fileName = "device.json"
    private static let storage = OSAllocatedUnfairLock(initialState: "")

    static var current: String { storage.withLock { $0 } }

    static func set(_ id: String) {
        storage.withLock { $0 = id }
    }

    /// Reads `device.json` in `folder`, or writes a fresh UUID there when it is missing or broken.
    @discardableResult
    static func load(from folder: URL) -> String {
        let url = folder.appending(path: fileName)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           UUID(uuidString: stored.id) != nil {
            set(stored.id)
            return stored.id
        }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(id: id)).write(to: url, options: .atomic)
        } catch {
            Log.data.error("Device id could not be saved: \(error.localizedDescription, privacy: .public)")
        }
        set(id)
        return id
    }

    private struct Stored: Codable {
        var id: String
    }
}
