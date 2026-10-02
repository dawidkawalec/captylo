import Foundation
import SwiftData

/// The meeting library as the MCP server sees it: the app's store opened read-only
/// (`Store.openReadOnlyContainer`, never migrated or saved) and its search index opened
/// read-only (`MeetingSearchIndex(url:readOnly:)`). The MCP process runs next to a running
/// Captylo, so both are opened again whenever their files changed since the last call (size,
/// modification date or file identity of the file and its WAL), and a meeting saved meanwhile
/// shows up without restarting the assistant. The only file it may create is an empty `-wal`
/// next to a database that has none (`ensureWALFile`). Tests hand in an in-memory library instead.
actor MeetingLibraryReader {
    /// What one tool call reads from.
    struct Library: Sendable {
        let database: Database
        /// Nil when there is no usable index file: search falls back to the store.
        let index: MeetingSearchIndex?
    }

    enum Failure: LocalizedError, Equatable {
        /// The store is missing, of another schema version or cannot be read.
        case storeUnavailable

        var errorDescription: String? {
            String(localized: "Nie mogę odczytać spotkań Captylo. Uruchom Captylo na tym Macu (po aktualizacji raz wystarczy) i spróbuj ponownie.")
        }
    }

    /// What the stat of a file and its `-wal` said; another value means it changed.
    private struct Stamp: Equatable {
        var parts: [String]

        init(_ url: URL) {
            let path = url.path(percentEncoded: false)
            parts = [path, path + "-wal"].map { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                return "\(modified) \(size) \(inode)"
            }
        }
    }

    private enum Source {
        case files(store: URL, index: URL)
        case fixed(Library)
    }

    private let source: Source
    private var opened: (stamp: Stamp, database: Database)?
    private var openedIndex: (stamp: Stamp, index: MeetingSearchIndex?)?

    /// The app's files (`AppPaths.store`, `AppPaths.searchIndex`); nothing is opened until the first call.
    init(storeURL: URL, indexURL: URL) {
        source = .files(store: storeURL, index: indexURL)
    }

    /// A library that is already open (tests).
    init(database: Database, index: MeetingSearchIndex?) {
        source = .fixed(Library(database: database, index: index))
    }

    /// The store and index for one call, opened again when their files changed.
    func library() throws(Failure) -> Library {
        switch source {
        case .fixed(let library):
            return library
        case .files(let storeURL, let indexURL):
            return Library(database: try database(at: storeURL), index: index(at: indexURL))
        }
    }

    private func database(at url: URL) throws(Failure) -> Database {
        Self.ensureWALFile(for: url)
        let stamp = Stamp(url)
        if let opened, opened.stamp == stamp {
            return opened.database
        }
        do {
            let database = Database(modelContainer: try Store.openReadOnlyContainer(at: url))
            opened = (stamp, database)
            return database
        } catch {
            opened = nil
            Log.data.error("MCP: store could not be opened read-only: \(error.localizedDescription, privacy: .public)")
            throw .storeUnavailable
        }
    }

    private func index(at url: URL) -> MeetingSearchIndex? {
        Self.ensureWALFile(for: url)
        let stamp = Stamp(url)
        if let openedIndex, openedIndex.stamp == stamp {
            return openedIndex.index
        }
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        let index = exists ? MeetingSearchIndex(url: url, readOnly: true) : nil
        openedIndex = (stamp, index)
        return index
    }

    /// SQLite opens a WAL database read-only only when its `-wal` file exists (it creates the
    /// `-shm` itself); a store or index closed cleanly may have none, and the open then fails
    /// with SQLITE_CANTOPEN. An empty `-wal` is what SQLite leaves after a checkpoint: it is
    /// created only when missing (`O_EXCL`, so an existing one with frames is never touched) and
    /// only next to an existing database file. The database file itself is never written.
    private static func ensureWALFile(for url: URL) {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let descriptor = open(path + "-wal", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if descriptor >= 0 {
            close(descriptor)
        }
    }
}
