import Foundation

/// One installation of the old app whose history can be imported (brief Appendix A): its
/// SwiftData store, the separate dictionary store and the folder its WAV recordings live in.
/// The importer only ever reads these (through temp copies for the stores).
struct LegacySource: Sendable, Equatable, Identifiable {
    /// Display name ("VocaType", "VoiceInk").
    let name: String
    /// `default.store` (`-wal` / `-shm` next to it).
    let storeURL: URL
    /// `dictionary.store` with `ZVOCABULARYWORD` / `ZWORDREPLACEMENT`; nil when there is none.
    let dictionaryStoreURL: URL?
    /// Folder of the recordings the rows point at (`ZAUDIOFILEURL`).
    let recordingsURL: URL

    var id: String { storeURL.path(percentEncoded: false) }

    /// Stable path used for the deterministic id of rows without `ZID`.
    var storePath: String { storeURL.standardizedFileURL.path(percentEncoded: false) }

    /// The two installations found on the owner's Mac, newest first: the installed VocaType 1.64
    /// (`com.dawidkawalec.vocatype`, its recordings still under the VoiceInk-era folder) and the
    /// VoiceInk upstream it grew from. When both hold the same `ZID` the first one wins.
    static func knownLocations(applicationSupport: URL = URL.applicationSupportDirectory) -> [LegacySource] {
        let vocaType = applicationSupport.appending(path: "com.dawidkawalec.VocaType", directoryHint: .isDirectory)
        let voiceInk = applicationSupport.appending(path: "com.prakashjoshipax.VoiceInk", directoryHint: .isDirectory)
        return [
            LegacySource(
                name: "VocaType",
                storeURL: vocaType.appending(path: "default.store"),
                dictionaryStoreURL: vocaType.appending(path: "dictionary.store"),
                recordingsURL: applicationSupport
                    .appending(path: "com.prakashjoshipax.VocaType", directoryHint: .isDirectory)
                    .appending(path: "Recordings", directoryHint: .isDirectory)
            ),
            LegacySource(
                name: "VoiceInk",
                storeURL: voiceInk.appending(path: "default.store"),
                dictionaryStoreURL: voiceInk.appending(path: "dictionary.store"),
                recordingsURL: voiceInk.appending(path: "Recordings", directoryHint: .isDirectory)
            ),
        ]
    }

    /// The candidates whose store file exists.
    static func discover(_ candidates: [LegacySource] = knownLocations()) -> [LegacySource] {
        candidates.filter { FileManager.default.fileExists(atPath: $0.storeURL.path(percentEncoded: false)) }
    }

    /// The dictionary store when the file exists.
    var existingDictionaryStoreURL: URL? {
        guard let dictionaryStoreURL,
              FileManager.default.fileExists(atPath: dictionaryStoreURL.path(percentEncoded: false)) else { return nil }
        return dictionaryStoreURL
    }
}
