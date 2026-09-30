import Foundation
import SQLite3

/// Reads an old Core Data / SwiftData SQLite store without ever opening the original: the store
/// and its `-wal` / `-shm` are copied together into a private temp folder (an APFS clone, so no
/// extra disk space), and the copy is opened with `SQLITE_OPEN_READONLY`. The copy is removed
/// by `close()` or at deinit.
///
/// Not Sendable (it owns a raw `sqlite3` handle): create and use it inside one task or actor.
final class LegacyStoreReader {
    static let transcriptionTable = "ZTRANSCRIPTION"
    static let vocabularyTable = "ZVOCABULARYWORD"
    static let replacementTable = "ZWORDREPLACEMENT"

    /// `ZTRANSCRIPTION` columns in `LegacyRow` order. A column the store lacks reads as NULL.
    static let transcriptionColumns = [
        "Z_PK", "ZID", "ZTIMESTAMP", "ZDURATION", "ZTRANSCRIPTIONDURATION", "ZENHANCEMENTDURATION",
        "ZTEXT", "ZENHANCEDTEXT", "ZTRANSCRIPTIONSTATUS", "ZAUDIOFILEURL", "ZTRANSCRIPTIONMODELNAME",
        "ZAIENHANCEMENTMODELNAME", "ZPROMPTNAME", "ZPOWERMODENAME",
    ]

    let sourceURL: URL
    private let copyDirectory: URL
    private var db: OpaquePointer?

    /// Copies `storeURL` (+ `-wal`, `-shm` when present) into `tempRoot` and opens the copy.
    init(storeURL: URL, tempRoot: URL = FileManager.default.temporaryDirectory) throws {
        sourceURL = storeURL
        let fileManager = FileManager.default
        copyDirectory = tempRoot.appending(path: "captylo-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
            let copyURL = copyDirectory.appending(path: storeURL.lastPathComponent)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(filePath: storeURL.path(percentEncoded: false) + suffix)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                try fileManager.copyItem(at: source, to: URL(filePath: copyURL.path(percentEncoded: false) + suffix))
            }
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(copyURL.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil)
            guard result == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 \(result)"
                sqlite3_close_v2(handle)
                throw LegacyImportError.readFailed(message)
            }
            db = handle
        } catch let error as LegacyImportError {
            try? fileManager.removeItem(at: copyDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: copyDirectory)
            throw LegacyImportError.readFailed(error.localizedDescription)
        }
    }

    deinit {
        close()
    }

    /// Closes the handle and deletes the temp copy. Idempotent.
    func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
        try? FileManager.default.removeItem(at: copyDirectory)
    }

    // MARK: Schema

    func hasTable(_ name: String) throws -> Bool {
        try !columns(of: name).isEmpty
    }

    /// Column names of `table` (empty when the table does not exist).
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { statement in
            if let name = Self.string(statement, 1) {
                names.insert(name.uppercased())
            }
        }
        return names
    }

    // MARK: Transcriptions

    func transcriptionCount() throws -> Int {
        guard try hasTable(Self.transcriptionTable) else { return 0 }
        var count = 0
        try query("SELECT COUNT(*) FROM \(Self.transcriptionTable)") { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    /// One page ordered by `Z_PK` (keyset paging: pass the last `pk` of the previous page).
    func transcriptions(afterPK: Int64, limit: Int) throws -> [LegacyRow] {
        let available = try columns(of: Self.transcriptionTable)
        guard available.contains("Z_PK") else { return [] }
        let select = Self.transcriptionColumns
            .map { available.contains($0) ? $0 : "NULL AS \($0)" }
            .joined(separator: ", ")
        let sql = "SELECT \(select) FROM \(Self.transcriptionTable) WHERE Z_PK > ?1 ORDER BY Z_PK LIMIT ?2"
        var rows: [LegacyRow] = []
        rows.reserveCapacity(limit)
        try query(sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, afterPK)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            rows.append(LegacyRow(
                pk: sqlite3_column_int64(statement, 0),
                id: Self.uuid(statement, 1),
                timestamp: Self.double(statement, 2),
                duration: Self.double(statement, 3),
                transcriptionDuration: Self.double(statement, 4),
                enhancementDuration: Self.double(statement, 5),
                text: Self.string(statement, 6),
                enhancedText: Self.string(statement, 7),
                status: Self.string(statement, 8),
                audioFileURL: Self.string(statement, 9),
                transcriptionModelName: Self.string(statement, 10),
                enhancementModelName: Self.string(statement, 11),
                promptName: Self.string(statement, 12),
                powerModeName: Self.string(statement, 13)
            ))
        }
        return rows
    }

    // MARK: Dictionary

    /// `ZVOCABULARYWORD.ZWORD` in the order they were added.
    func vocabulary() throws -> [String] {
        let available = try columns(of: Self.vocabularyTable)
        guard available.contains("ZWORD") else { return [] }
        let order = available.contains("ZDATEADDED") ? "ZDATEADDED, Z_PK" : "Z_PK"
        var words: [String] = []
        try query("SELECT ZWORD FROM \(Self.vocabularyTable) ORDER BY \(order)") { statement in
            if let word = Self.string(statement, 0) {
                words.append(word)
            }
        }
        return words
    }

    /// `ZWORDREPLACEMENT` rows; a store without `ZISENABLED` counts every rule as enabled.
    func replacements() throws -> [LegacyReplacementRow] {
        let available = try columns(of: Self.replacementTable)
        guard available.contains("ZORIGINALTEXT"), available.contains("ZREPLACEMENTTEXT") else { return [] }
        let enabled = available.contains("ZISENABLED") ? "ZISENABLED" : "1"
        var rows: [LegacyReplacementRow] = []
        try query("SELECT ZORIGINALTEXT, ZREPLACEMENTTEXT, \(enabled) FROM \(Self.replacementTable) ORDER BY Z_PK") { statement in
            guard let original = Self.string(statement, 0), let replacement = Self.string(statement, 1) else { return }
            let isEnabled = sqlite3_column_type(statement, 2) == SQLITE_NULL || sqlite3_column_int64(statement, 2) != 0
            rows.append(LegacyReplacementRow(original: original, replacement: replacement, isEnabled: isEnabled))
        }
        return rows
    }

    // MARK: SQLite helpers

    private func query(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        guard let db else { throw LegacyImportError.readFailed("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyImportError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                try row(statement)
            } else if step == SQLITE_DONE {
                return
            } else {
                throw LegacyImportError.readFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private static func double(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    /// A 16-byte blob (SwiftData / Core Data `UUID`) or, defensively, a UUID string.
    private static func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count == 16, let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return uuid(fromBytes: UnsafeRawBufferPointer(start: bytes, count: count))
        case SQLITE_TEXT:
            return string(statement, column).flatMap { UUID(uuidString: $0) }
        default:
            return nil
        }
    }

    /// The 16 bytes in `uuid_t` order (as SwiftData stores them).
    static func uuid(fromBytes bytes: UnsafeRawBufferPointer) -> UUID? {
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
    }
}
