import Foundation
import os

/// Full-text search over every meeting: one SQLite file next to the store (`AppPaths.searchIndex`)
/// with an FTS5 table on the trigram tokenizer, so a word stem finds its Polish case forms
/// ("ofert" in "ofertę", "ofertą"). The body of every row is already folded
/// (`MeetingSearch.fold`): the tokenizer's own case and diacritics handling is not relied on (it
/// keeps "ł"). The original text is not stored; snippets come from the store, so the index never
/// holds anything the store does not.
///
/// A class with its own serial queue rather than an actor: `Database` calls the `MeetingIndexing`
/// writes synchronously right after a save, they are queued in exactly that order, and the store
/// path never waits for (or is reentered by) the index. The connection lives only on `queue`.
///
/// Rows: one per segment that is not echo, plus a title and a notes row per meeting. The `keys`
/// table maps a segment id (or "title:<meeting>", "notes:<meeting>") to its FTS row, so an upsert
/// or a meeting delete never scans the FTS table.
final class MeetingSearchIndex: MeetingIndexing, @unchecked Sendable {
    /// `PRAGMA user_version` of the file; another value drops the tables and rebuilds them.
    static let version = 1
    /// File name inside the data folder (`AppPaths.searchIndex`).
    static let fileName = "Search.sqlite"

    /// Rows a full build would hold: one title row per meeting and one row per segment that is not echo.
    struct Counts: Sendable, Equatable {
        var meetings: Int
        var segments: Int
    }

    /// What a full rebuild did (log and `--rebuild-search-index`).
    struct Rebuild: Sendable, Equatable {
        var meetings: Int
        var rows: Int
        var ms: Int
    }

    /// What `prepare(database:)` found.
    enum Preparation: Sendable, Equatable {
        /// The file matched the store: searchable right away.
        case ready
        /// The file was missing, old, corrupt or out of step with the store and was rebuilt.
        case rebuilt(Rebuild)
        /// The index could not be opened or rebuilt: search stays on the store's `contains` path.
        case unavailable
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable

        var errorDescription: String? { "The search index could not be opened" }
    }

    /// The file, or nil for an in-memory index (tests, design preview, test host).
    let url: URL?
    /// The MCP server's view of the app's index file (`MeetingLibraryReader`): opened with
    /// `SQLITE_OPEN_READONLY`, never created, recreated, rebuilt or written to; it answers only
    /// while the file has this version and a finished full build (the `meetings` mark in `meta`,
    /// which a rebuild clears first and sets last). Otherwise search returns nil (the fallback).
    let isReadOnly: Bool

    private let queue = DispatchQueue(label: "com.captylo.app.search-index", qos: .utility)
    private let readyFlag: OSAllocatedUnfairLock<Bool>

    // Touched only on `queue`.
    private var connection: SQLiteConnection?
    private var openAttempted = false
    /// The file was created, recreated or had another version: its rows say nothing about the store.
    private var needsRebuild = false

    /// Nothing is opened here: the file is opened on the index queue by the first call that needs it.
    /// An in-memory index starts empty and ready (its store starts empty too); a file index is
    /// ready once `prepare(database:)` or `rebuild(from:)` has checked it against the store; a
    /// read-only one checks the file at every search instead.
    init(url: URL?, readOnly: Bool = false) {
        self.url = url
        isReadOnly = readOnly && url != nil
        readyFlag = OSAllocatedUnfairLock(initialState: url == nil || isReadOnly)
    }

    /// True when search answers from the index; false while it is checked or rebuilt (the caller
    /// then uses the store's `contains` search).
    var isReady: Bool {
        readyFlag.withLock { $0 }
    }

    // MARK: Launch

    /// Opens the file and checks it against the store; rebuilds it when it is new, of another
    /// version, corrupt (deleted and recreated) or its row counts differ from the store's (a crash
    /// lost writes). Runs on the index queue and the database queue, never on the caller's thread.
    @discardableResult
    func prepare(database: Database) async -> Preparation {
        guard !isReadOnly else { return .unavailable }
        let state: (opened: Bool, needsRebuild: Bool, counts: Counts?) = await onQueue {
            guard let connection = self.openIfNeeded() else { return (false, false, nil) }
            // No `meta.meetings`: the last rebuild never finished (a crash or quit midway), and a
            // read-only reader (MCP) would ignore the file until a full build marks it again.
            let finished = (try? connection.integer("SELECT count(*) FROM meta WHERE key = 'meetings'")) == 1
            return (true, self.needsRebuild || !finished, try? self.counts(in: connection))
        }
        guard state.opened else {
            setReady(false)
            return .unavailable
        }
        if !state.needsRebuild, let indexed = state.counts,
           let stored = try? await database.searchIndexCounts(), indexed == stored {
            setReady(true)
            return .ready
        }
        do {
            return .rebuilt(try await rebuild(from: database))
        } catch {
            Log.data.error("Search index rebuild failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// Empties the index and fills it again from the store, one meeting per transaction, newest
    /// first. Not ready (search falls back) until it ends. Writes made meanwhile still land: each
    /// meeting is read and queued in one step on the database actor, so a later save always
    /// queues after it.
    @discardableResult
    func rebuild(from database: Database) async throws -> Rebuild {
        guard !isReadOnly else { throw Failure.unavailable }
        let started = ContinuousClock.now
        setReady(false)
        try await withConnection { connection in
            try connection.transaction {
                try connection.execute("DELETE FROM entries; DELETE FROM keys; DELETE FROM meta;")
            }
        }
        for id in try await database.meetingIDs() {
            try await database.reindexMeeting(id: id, into: self)
        }
        let built: (meetings: Int, rows: Int) = try await withConnection { connection in
            let counts = try self.counts(in: connection)
            let rows = try connection.integer("SELECT count(*) FROM keys")
            try connection.transaction {
                try self.setMeta("meetings", String(counts.meetings), in: connection)
                try self.setMeta("builtAt", ISO8601DateFormatter().string(from: Date()), in: connection)
            }
            self.needsRebuild = false
            return (counts.meetings, rows)
        }
        setReady(true)
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.data.notice("Search index rebuilt: \(built.meetings, privacy: .public) meetings, \(built.rows, privacy: .public) rows in \(ms, privacy: .public) ms")
        return Rebuild(meetings: built.meetings, rows: built.rows, ms: ms)
    }

    // MARK: Search

    /// Entries that contain every term of `query` (`SearchQuery.terms`), best first. Nil when the
    /// query has no word of 3+ characters or the index is not ready: the caller keeps the old
    /// `contains` search.
    func search(_ query: String, limit: Int) async -> [SearchHit]? {
        guard let terms = SearchQuery.terms(query) else { return nil }
        return await search(terms: terms, all: true, limit: limit)
    }

    /// Entries that contain all (`all`) or any of `terms`, best first (bm25, title and notes
    /// weighted up). Nil when not ready or the query fails.
    func search(terms: [String], all: Bool, limit: Int) async -> [SearchHit]? {
        guard !terms.isEmpty, limit > 0, isReady else { return nil }
        let match = SearchQuery.match(terms, all: all)
        return await onQueue {
            guard let connection = self.openIfNeeded(), self.canAnswer(connection) else { return nil }
            do {
                return try self.hits(match: match, limit: limit, in: connection)
            } catch let failure as SQLiteConnection.Failure {
                // The message can quote the query: only the code goes to the log.
                Log.data.error("Search index query failed: SQLite \(failure.code, privacy: .public)")
                return nil
            } catch {
                return nil
            }
        }
    }

    /// Hits ranked per meeting rather than per entry: the `meetings` meetings whose best entry
    /// ranks best, each with at most `segmentsPerMeeting` segment hits (its best ones) plus its
    /// title and notes hits, meetings in the order of their best hit. A meeting that says a word
    /// hundreds of times never crowds out the others, as a flat `limit` over entries would. Nil
    /// when not ready or the query fails. `within` limits the hits to those meetings (nil: all).
    func meetingHits(
        terms: [String], all: Bool, meetings: Int, segmentsPerMeeting: Int, within: [UUID]? = nil
    ) async -> [SearchHit]? {
        guard !terms.isEmpty, meetings > 0, isReady else { return nil }
        if let within, within.isEmpty { return [] }
        let match = SearchQuery.match(terms, all: all)
        let perMeeting = max(segmentsPerMeeting, 0)
        // A JSON array of the ids, read with `json_each` (one bound parameter for any count).
        let only = within.map { "[" + $0.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]" }
        return await onQueue {
            guard let connection = self.openIfNeeded(), self.canAnswer(connection) else { return nil }
            do {
                return try self.meetingHits(match: match, meetings: meetings, perMeeting: perMeeting, only: only, in: connection)
            } catch let failure as SQLiteConnection.Failure {
                Log.data.error("Search index query failed: SQLite \(failure.code, privacy: .public)")
                return nil
            } catch {
                return nil
            }
        }
    }

    // MARK: MeetingIndexing

    func indexMeeting(_ meeting: MeetingRecord, segments: [MeetingSegmentRecord]) {
        write { connection in
            try self.deleteRows(meeting: meeting.id, in: connection)
            try self.insertTitleNotes(meeting, in: connection)
            for segment in segments where segment.meetingID == meeting.id && !segment.isEcho {
                try self.insert(segment, in: connection)
            }
        }
    }

    func indexSegments(_ segments: [MeetingSegmentRecord]) {
        guard !segments.isEmpty else { return }
        write { connection in
            for segment in segments {
                try self.deleteRow(key: segment.id.uuidString, in: connection)
                if !segment.isEcho {
                    try self.insert(segment, in: connection)
                }
            }
        }
    }

    func indexTitleNotes(_ meeting: MeetingRecord) {
        write { connection in
            try self.deleteRow(key: Self.titleKey(meeting.id), in: connection)
            try self.deleteRow(key: Self.notesKey(meeting.id), in: connection)
            try self.insertTitleNotes(meeting, in: connection)
        }
    }

    func removeMeeting(_ id: UUID) {
        write { connection in
            try self.deleteRows(meeting: id, in: connection)
        }
    }

    // MARK: Queue

    private func setReady(_ ready: Bool) {
        readyFlag.withLock { $0 = ready }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func withConnection<T: Sendable>(_ work: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let connection = self.openIfNeeded() else {
                    continuation.resume(throwing: Failure.unavailable)
                    return
                }
                continuation.resume(with: Result { try work(connection) })
            }
        }
    }

    /// Queues one write transaction; a failure is logged, never thrown back to the store path.
    private func write(_ body: @escaping @Sendable (SQLiteConnection) throws -> Void) {
        guard !isReadOnly else { return }
        queue.async {
            guard let connection = self.openIfNeeded() else { return }
            do {
                try connection.transaction {
                    try body(connection)
                }
            } catch {
                Log.data.error("Search index write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Opening (on `queue`)

    /// The connection, opened on first use. A file that cannot be opened or fails `quick_check`
    /// is deleted and created again (and marked for a rebuild). Nil when even that fails: every
    /// write is skipped and search stays on the fallback.
    private func openIfNeeded() -> SQLiteConnection? {
        if let connection { return connection }
        guard !openAttempted else { return nil }
        openAttempted = true
        guard let url else {
            do {
                let memory = try SQLiteConnection(path: nil)
                try Self.createSchema(memory)
                connection = memory
            } catch {
                Log.data.error("In-memory search index failed: \(error.localizedDescription, privacy: .public)")
            }
            return connection
        }
        if isReadOnly {
            connection = openReadOnly(url)
            return connection
        }
        do {
            connection = try openFile(url)
        } catch {
            Log.data.error("Search index unusable, recreating it: \(error.localizedDescription, privacy: .public)")
            Self.removeFiles(at: url)
            do {
                connection = try openFile(url)
            } catch {
                Log.data.error("Search index could not be created: \(error.localizedDescription, privacy: .public)")
            }
        }
        return connection
    }

    private func openFile(_ url: URL) throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        let existed = FileManager.default.fileExists(atPath: path)
        let file = try SQLiteConnection(path: path)
        guard try file.text("PRAGMA quick_check") == "ok" else {
            throw SQLiteConnection.Failure(code: 11, message: "quick_check failed")
        }
        try file.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        let version = try file.integer("PRAGMA user_version")
        if !existed || version != Self.version {
            try file.execute("DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS keys; DROP TABLE IF EXISTS meta;")
            try Self.createSchema(file)
            needsRebuild = true
        }
        return file
    }

    /// The app's file as it is, for reading only: nil when it is missing, cannot be opened or
    /// has another version (nothing is created, checked, repaired or dropped here).
    private func openReadOnly(_ url: URL) -> SQLiteConnection? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let file = try SQLiteConnection(path: path, readOnly: true)
            guard try file.integer("PRAGMA user_version") == Self.version else {
                Log.data.notice("Read-only search index has another version, not used")
                return nil
            }
            return file
        } catch let failure as SQLiteConnection.Failure {
            Log.data.error("Read-only search index could not be opened: SQLite \(failure.code, privacy: .public)")
            return nil
        } catch {
            return nil
        }
    }

    /// A read-only index answers only after a finished full build (`meta.meetings` is set last
    /// by `rebuild`, after it emptied the table); the app's own index always answers.
    private func canAnswer(_ connection: SQLiteConnection) -> Bool {
        guard isReadOnly else { return true }
        return (try? connection.integer("SELECT count(*) FROM meta WHERE key = 'meetings'")) == 1
    }

    private static func createSchema(_ connection: SQLiteConnection) throws {
        try connection.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
                body,
                meeting UNINDEXED,
                segment UNINDEXED,
                kind UNINDEXED,
                start UNINDEXED,
                track UNINDEXED,
                tokenize = 'trigram'
            );
            CREATE TABLE IF NOT EXISTS keys (
                key TEXT PRIMARY KEY,
                meeting TEXT NOT NULL,
                kind TEXT NOT NULL,
                entry INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS keys_meeting ON keys(meeting);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            PRAGMA user_version = \(version);
            """)
    }

    /// The index file and its WAL and shared-memory files.
    private static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
        }
    }

    // MARK: Rows (on `queue`)

    private static func titleKey(_ id: UUID) -> String { "title:" + id.uuidString }
    private static func notesKey(_ id: UUID) -> String { "notes:" + id.uuidString }

    private func counts(in connection: SQLiteConnection) throws -> Counts {
        Counts(
            meetings: try connection.integer("SELECT count(*) FROM keys WHERE kind = 'title'"),
            segments: try connection.integer("SELECT count(*) FROM keys WHERE kind = 'segment'")
        )
    }

    private func insertTitleNotes(_ meeting: MeetingRecord, in connection: SQLiteConnection) throws {
        try insert(key: Self.titleKey(meeting.id), meeting: meeting.id, segment: "", kind: .title,
                   start: 0, track: "", body: MeetingSearch.fold(meeting.title), in: connection)
        try insert(key: Self.notesKey(meeting.id), meeting: meeting.id, segment: "", kind: .notes,
                   start: 0, track: "", body: MeetingSearch.fold(meeting.notes), in: connection)
    }

    private func insert(_ segment: MeetingSegmentRecord, in connection: SQLiteConnection) throws {
        try insert(key: segment.id.uuidString, meeting: segment.meetingID, segment: segment.id.uuidString,
                   kind: .segment, start: segment.start, track: segment.track.rawValue,
                   body: MeetingSearch.fold(segment.text), in: connection)
    }

    private func insert(
        key: String, meeting: UUID, segment: String, kind: SearchHit.Kind,
        start: Double, track: String, body: String, in connection: SQLiteConnection
    ) throws {
        let entry = try connection.statement(
            "INSERT INTO entries(body, meeting, segment, kind, start, track) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try entry.bind(1, body)
        try entry.bind(2, meeting.uuidString)
        try entry.bind(3, segment)
        try entry.bind(4, kind.rawValue)
        try entry.bind(5, start)
        try entry.bind(6, track)
        try entry.step()
        let rowID = connection.lastInsertRowID
        let mapping = try connection.statement(
            "INSERT OR REPLACE INTO keys(key, meeting, kind, entry) VALUES (?, ?, ?, ?)"
        )
        try mapping.bind(1, key)
        try mapping.bind(2, meeting.uuidString)
        try mapping.bind(3, kind.rawValue)
        try mapping.bind(4, rowID)
        try mapping.step()
    }

    private func deleteRow(key: String, in connection: SQLiteConnection) throws {
        let entry = try connection.statement(
            "DELETE FROM entries WHERE rowid IN (SELECT entry FROM keys WHERE key = ?)"
        )
        try entry.bind(1, key)
        try entry.step()
        let mapping = try connection.statement("DELETE FROM keys WHERE key = ?")
        try mapping.bind(1, key)
        try mapping.step()
    }

    private func deleteRows(meeting: UUID, in connection: SQLiteConnection) throws {
        let entries = try connection.statement(
            "DELETE FROM entries WHERE rowid IN (SELECT entry FROM keys WHERE meeting = ?)"
        )
        try entries.bind(1, meeting.uuidString)
        try entries.step()
        let mapping = try connection.statement("DELETE FROM keys WHERE meeting = ?")
        try mapping.bind(1, meeting.uuidString)
        try mapping.step()
    }

    private func setMeta(_ key: String, _ value: String, in connection: SQLiteConnection) throws {
        let statement = try connection.statement("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)")
        try statement.bind(1, key)
        try statement.bind(2, value)
        try statement.step()
    }

    /// The weighted bm25 of an entry: title and notes count more than a transcript line.
    private static let score = "bm25(entries) * CASE kind WHEN 'title' THEN 2.0 WHEN 'notes' THEN 1.5 ELSE 1.0 END"

    private func hits(match: String, limit: Int, in connection: SQLiteConnection) throws -> [SearchHit] {
        let statement = try connection.statement("""
            SELECT meeting, segment, kind, start, track, \(Self.score) AS score
            FROM entries WHERE entries MATCH ? ORDER BY score LIMIT ?
            """)
        defer { statement.reset() }
        try statement.bind(1, match)
        try statement.bind(2, Int64(limit))
        return try read(statement)
    }

    /// Every match is scored once (`scored`), the meetings are ranked by their best entry
    /// (`best`, cut to `meetings`), and each meeting keeps its best `perMeeting` segment hits
    /// (title and notes are one row each). `only`: a JSON array of meeting ids to keep, nil
    /// (left unbound, so NULL) keeps all.
    private func meetingHits(
        match: String, meetings: Int, perMeeting: Int, only: String?, in connection: SQLiteConnection
    ) throws -> [SearchHit] {
        let statement = try connection.statement("""
            WITH scored AS MATERIALIZED (
                SELECT meeting, segment, kind, start, track, \(Self.score) AS score
                FROM entries WHERE entries MATCH ?1
                AND (?4 IS NULL OR meeting IN (SELECT value FROM json_each(?4)))
            ),
            best AS (
                SELECT meeting, min(score) AS best FROM scored GROUP BY meeting ORDER BY best, meeting LIMIT ?2
            ),
            numbered AS (
                SELECT scored.*, best.best AS best,
                       row_number() OVER (PARTITION BY scored.meeting, scored.kind ORDER BY scored.score) AS place
                FROM scored JOIN best ON best.meeting = scored.meeting
            )
            SELECT meeting, segment, kind, start, track, score FROM numbered
            WHERE kind != 'segment' OR place <= ?3
            ORDER BY best, meeting, score
            """)
        defer { statement.reset() }
        try statement.bind(1, match)
        try statement.bind(2, Int64(meetings))
        try statement.bind(3, Int64(perMeeting))
        if let only {
            try statement.bind(4, only)
        }
        return try read(statement)
    }

    /// Rows of `meeting, segment, kind, start, track, score` as hits; a row that does not parse is skipped.
    private func read(_ statement: SQLiteStatement) throws -> [SearchHit] {
        var hits: [SearchHit] = []
        while try statement.step() {
            guard let meetingID = UUID(uuidString: statement.text(0)),
                  let kind = SearchHit.Kind(rawValue: statement.text(2)) else { continue }
            hits.append(SearchHit(
                meetingID: meetingID,
                segmentID: UUID(uuidString: statement.text(1)),
                kind: kind,
                start: statement.double(3),
                track: MeetingTrack(rawValue: statement.text(4)),
                rank: statement.double(5)
            ))
        }
        return hits
    }
}
