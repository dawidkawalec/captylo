import FluidAudio
import Foundation

/// Every on-disk location the app uses. Audio rows store only `<id>.wav`; resolve it here.
enum AppPaths {
    static let folderName = "Captylo"
    static let storeFileName = "Captylo.store"

    /// Environment variable that points the whole data folder somewhere else (support and
    /// migration checks on a copy of the store).
    static let dataDirectoryOverrideKey = "CAPTYLO_DATA_DIR"

    /// The override folder from `CAPTYLO_DATA_DIR`, nil for a normal run.
    static let dataDirectoryOverride: URL? = {
        guard let path = ProcessInfo.processInfo.environment[dataDirectoryOverrideKey], !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }()

    /// `~/Library/Application Support/Captylo/` (or `CAPTYLO_DATA_DIR`).
    static let dataDirectory: URL = dataDirectoryOverride ?? URL.applicationSupportDirectory
        .appending(path: folderName, directoryHint: .isDirectory)

    /// SwiftData store (`-wal` / `-shm` live next to it).
    static var store: URL { dataDirectory.appending(path: storeFileName) }

    static var dictionaryJSON: URL { dataDirectory.appending(path: "dictionary.json") }
    /// Self-learning memory (candidates, learned terms, style), next to the dictionary.
    static var learningJSON: URL { dataDirectory.appending(path: "learning.json") }

    static var recordings: URL { dataDirectory.appending(path: "Recordings", directoryHint: .isDirectory) }

    static func recordingURL(for id: UUID) -> URL {
        recordings.appending(path: "\(id.uuidString).wav")
    }

    static func recordingURL(fileName: String) -> URL {
        recordings.appending(path: fileName)
    }

    /// `Meetings/<id>/me.caf` and `them.caf`: never under `Recordings/` (the dictation orphan sweep).
    static var meetings: URL { dataDirectory.appending(path: "Meetings", directoryHint: .isDirectory) }

    static func meetingFolder(_ id: UUID) -> URL {
        meetings.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func meetingTrackURL(_ id: UUID, track: MeetingTrack) -> URL {
        meetingFolder(id).appending(path: track.fileName)
    }

    /// Creates the data, recordings and meetings directories (call before opening the store).
    static func ensureDirectories() throws {
        for directory in [dataDirectory, recordings, meetings] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` (shared with the old app, gotcha 23).
    static var parakeetModelDir: URL { AsrModels.defaultCacheDirectory(for: .v3) }
}
