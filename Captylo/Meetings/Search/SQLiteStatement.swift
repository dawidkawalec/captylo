import Foundation
import SQLite3

/// One prepared statement of a `SQLiteConnection`. Parameters are 1-based, columns 0-based, as in
/// the C API. Like its connection it is used on one queue only.
final class SQLiteStatement {
    private let pointer: OpaquePointer
    /// For error messages. Unowned: the connection caches its statements and finalizes them
    /// before it closes, so a statement never outlives it.
    private unowned let connection: SQLiteConnection

    init(_ pointer: OpaquePointer, connection: SQLiteConnection) {
        self.pointer = pointer
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    /// SQLite copies the bound bytes (`SQLITE_TRANSIENT`), so Swift strings can go away after binding.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func reset() {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
    }

    func bind(_ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(pointer, index, value, -1, Self.transient))
    }

    func bind(_ index: Int32, _ value: Double) throws {
        try check(sqlite3_bind_double(pointer, index, value))
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(pointer, index, value))
    }

    /// Advances to the next row: true while there is one, false when done.
    @discardableResult
    func step() throws -> Bool {
        let code = sqlite3_step(pointer)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.failure(code)
        }
    }

    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(pointer, column) else { return "" }
        return String(cString: bytes)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(pointer, column)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(pointer, column))
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(pointer, column)
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw connection.failure(code) }
    }
}
