import Foundation
import SQLite3

/// One connection to a SQLite file through the system `libsqlite3` (the meeting search index).
/// Not Sendable: its owner (`MeetingSearchIndex`) touches it only on its own serial queue.
final class SQLiteConnection {
    /// A failed SQLite call: the result code and SQLite's message (never bound values).
    struct Failure: LocalizedError, Equatable {
        let code: Int32
        let message: String

        var errorDescription: String? { "SQLite \(code): \(message)" }
    }

    private let handle: OpaquePointer
    /// Prepared statements by SQL text, reused for the life of the connection.
    private var cache: [String: SQLiteStatement] = [:]

    /// Opens the file at `path` (created when missing unless `readOnly`), or an in-memory
    /// database when `path` is nil.
    init(path: String?, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let access = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let code = sqlite3_open_v2(path ?? ":memory:", &db, access | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw Failure(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    /// A prepared statement for `sql`, reset and with its bindings cleared, ready to bind and step.
    func statement(_ sql: String) throws -> SQLiteStatement {
        if let cached = cache[sql] {
            cached.reset()
            return cached
        }
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let pointer else { throw failure(code) }
        let statement = SQLiteStatement(pointer, connection: self)
        cache[sql] = statement
        return statement
    }

    /// Runs `body` in one write transaction, rolled back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The first column of the first row as an integer (`PRAGMA user_version`, counts), 0 when no row.
    func integer(_ sql: String) throws -> Int {
        let statement = try statement(sql)
        defer { statement.reset() }
        return try statement.step() ? statement.int(0) : 0
    }

    /// The first column of the first row as text (`PRAGMA quick_check`), nil when no row.
    func text(_ sql: String) throws -> String? {
        let statement = try statement(sql)
        defer { statement.reset() }
        return try statement.step() ? statement.text(0) : nil
    }

    /// Row id of the last insert on this connection.
    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// A `Failure` for `code` with the connection's current message.
    func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
