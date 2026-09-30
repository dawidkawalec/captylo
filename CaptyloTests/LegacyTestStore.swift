import Foundation
import SQLite3
@testable import Captylo

/// Builds a fake old VocaType store with the exact schema of the real one (Z_PK / Z_ENT / Z_OPT
/// included) through the SQLite C API, for the legacy import tests.
final class LegacyTestStore {
    /// `CREATE TABLE` statements copied from the owner's `default.store` (VocaType 1.64).
    static let schema = """
    CREATE TABLE ZTRANSCRIPTION ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDURATION FLOAT, ZENHANCEMENTDURATION FLOAT, ZTIMESTAMP TIMESTAMP, ZTRANSCRIPTIONDURATION FLOAT, ZAIENHANCEMENTMODELNAME VARCHAR, ZAIREQUESTSYSTEMMESSAGE VARCHAR, ZAIREQUESTUSERMESSAGE VARCHAR, ZAUDIOFILEURL VARCHAR, ZENHANCEDTEXT VARCHAR, ZPOWERMODEEMOJI VARCHAR, ZPOWERMODENAME VARCHAR, ZPROMPTNAME VARCHAR, ZTEXT VARCHAR, ZTRANSCRIPTIONMODELNAME VARCHAR, ZTRANSCRIPTIONSTATUS VARCHAR, ZID BLOB );
    CREATE TABLE ZVOCABULARYWORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDATEADDED TIMESTAMP, ZWORD VARCHAR );
    CREATE UNIQUE INDEX Z_VocabularyWord_UNIQUE_word ON ZVOCABULARYWORD (ZWORD COLLATE BINARY ASC);
    CREATE TABLE ZWORDREPLACEMENT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISENABLED INTEGER, ZDATEADDED TIMESTAMP, ZORIGINALTEXT VARCHAR, ZREPLACEMENTTEXT VARCHAR, ZID BLOB );
    """

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    /// Creates the file with the schema. `wal` keeps the journal in WAL mode with no automatic
    /// checkpoint, so rows written while the store stays open live only in `-wal`.
    init(url: URL, wal: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw LegacyImportError.readFailed("open test store")
        }
        if wal {
            try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        }
        try exec(Self.schema)
    }

    deinit {
        close()
    }

    func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LegacyImportError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func insert(_ row: LegacyRow, entity: Int = 3) throws {
        let sql = """
        INSERT INTO ZTRANSCRIPTION (Z_PK, Z_ENT, Z_OPT, ZID, ZTIMESTAMP, ZDURATION, ZTRANSCRIPTIONDURATION, ZENHANCEMENTDURATION,
            ZTEXT, ZENHANCEDTEXT, ZTRANSCRIPTIONSTATUS, ZAUDIOFILEURL, ZTRANSCRIPTIONMODELNAME, ZAIENHANCEMENTMODELNAME,
            ZPROMPTNAME, ZPOWERMODENAME, ZAIREQUESTSYSTEMMESSAGE)
        VALUES (?1, ?2, 1, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 'system prompt')
        """
        try withStatement(sql) { statement in
            sqlite3_bind_int64(statement, 1, row.pk)
            sqlite3_bind_int64(statement, 2, Int64(entity))
            if let id = row.id {
                var raw = id.uuid
                withUnsafeBytes(of: &raw) { bytes in
                    _ = sqlite3_bind_blob(statement, 3, bytes.baseAddress, 16, Self.transient)
                }
            }
            bind(row.timestamp, statement, 4)
            bind(row.duration, statement, 5)
            bind(row.transcriptionDuration, statement, 6)
            bind(row.enhancementDuration, statement, 7)
            bind(row.text, statement, 8)
            bind(row.enhancedText, statement, 9)
            bind(row.status, statement, 10)
            bind(row.audioFileURL, statement, 11)
            bind(row.transcriptionModelName, statement, 12)
            bind(row.enhancementModelName, statement, 13)
            bind(row.promptName, statement, 14)
            bind(row.powerModeName, statement, 15)
        }
    }

    func insertWord(_ word: String, date: Double = 0) throws {
        try withStatement("INSERT INTO ZVOCABULARYWORD (Z_ENT, Z_OPT, ZDATEADDED, ZWORD) VALUES (5, 1, ?1, ?2)") { statement in
            bind(date, statement, 1)
            bind(word, statement, 2)
        }
    }

    func insertReplacement(_ original: String, _ replacement: String, enabled: Bool = true) throws {
        try withStatement("INSERT INTO ZWORDREPLACEMENT (Z_ENT, Z_OPT, ZISENABLED, ZDATEADDED, ZORIGINALTEXT, ZREPLACEMENTTEXT) VALUES (6, 1, ?1, 0, ?2, ?3)") { statement in
            sqlite3_bind_int64(statement, 1, enabled ? 1 : 0)
            bind(original, statement, 2)
            bind(replacement, statement, 3)
        }
    }

    // MARK: Helpers

    private func withStatement(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyImportError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LegacyImportError.readFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String?, _ statement: OpaquePointer, _ index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Double?, _ statement: OpaquePointer, _ index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
