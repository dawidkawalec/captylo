import Foundation

/// The read-only tools of the MCP server (`MCPServer`): their definitions for `tools/list`
/// (JSON Schema inputs, English descriptions for the assistant's model) and the handlers for
/// `tools/call`, which answer in Markdown text. Nothing here writes to the store, calls an AI
/// model or reaches the network.
///
/// - `list_meetings`: newest first, one line per meeting with date, title, length, app and id;
///   optional text filter (the index first, so Polish word forms match, then the store's
///   `contains`), start date and limit.
/// - `get_meeting`: `MeetingExport.markdown` of one meeting (participants, notes, AI notes, the
///   "Pytania" answers and, unless `transcript` is false, the transcript).
/// - `search_meetings`: the Spotkania search (`MeetingSearchResults`): per meeting up to two
///   lines "[12:34] Anna: ...snippet...", or the store's `contains` search with the first
///   matching line when the index cannot answer; then up to `searchNoteLimit` matching notes as
///   "- Notatka: Tytuł (data) · note id: ..." (the name stays for connected assistants).
/// - `list_notes`: newest first, one line per note with date, title (or first line), the length
///   of its recording and id; optional text filter (the index first), start date and limit.
/// - `get_note`: one note as Markdown: title, date, recording length and the text.
struct MCPTools: Sendable {
    /// What a tool call answers: Markdown text, and whether it is an error the model should read
    /// (a bad argument, an unknown meeting) rather than a protocol failure.
    struct Result: Sendable, Equatable {
        var text: String
        var isError = false
    }

    /// Calls the server answers with a JSON-RPC error instead of a result.
    enum Failure: Error, Equatable {
        case unknownTool(String)
    }

    static let names = ["list_meetings", "get_meeting", "search_meetings", "list_notes", "get_note"]
    static let defaultListLimit = 20
    static let maxListLimit = 50
    static let defaultSearchLimit = 10
    static let maxSearchLimit = 30
    /// Notes `search_meetings` adds under the meetings.
    static let searchNoteLimit = 5
    /// Meetings the index search of `list_meetings` reads before the date filter and the limit.
    private static let listSearchCandidates = 200

    let library: MeetingLibraryReader
    /// Dates in the answers and a `since` given as a bare day are in this time zone.
    var timeZone: TimeZone = .current

    /// `tools/list` entries, in the order of `names`.
    var definitions: [JSONValue] {
        [
            Self.tool(
                "list_meetings",
                title: "List meetings",
                description: """
                    List the meetings recorded with Captylo on this Mac, newest first: date and time, \
                    title, length, the call app and the meeting id. Optionally only meetings whose title, \
                    notes or transcript contain the query, or that started on or after a date.
                    """,
                properties: [
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words to look for in the title, notes and transcript (any Polish word form)."),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 date (2026-10-01) or date and time; only meetings that started then or later."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(Self.maxListLimit),
                        "default": .int(Self.defaultListLimit),
                    ]),
                ],
                required: []
            ),
            Self.tool(
                "get_meeting",
                title: "Get a meeting",
                description: """
                    One meeting as Markdown: title, date and length, participants, the user's notes, \
                    the AI notes, answered questions and the transcript with [mm:ss] times and speakers.
                    """,
                properties: [
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The meeting id from list_meetings or search_meetings."),
                    ]),
                    "transcript": .object([
                        "type": .string("boolean"),
                        "description": .string("Include the transcript (default true). False for the notes only."),
                        "default": .bool(true),
                    ]),
                ],
                required: ["id"]
            ),
            Self.tool(
                "search_meetings",
                title: "Search meetings",
                description: """
                    Full-text search over every meeting's title, notes and transcript (Polish word forms \
                    and missing diacritics match). Best meetings first, each with up to two matching \
                    transcript lines: [mm:ss] speaker and the text around the match, plus the meeting id \
                    for get_meeting. Then the user's notes that match ("Notatka:" lines with a note id \
                    for get_note).
                    """,
                properties: [
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words to find, e.g. \"budżet kampanii\"."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Most meetings to return."),
                        "minimum": .int(1),
                        "maximum": .int(Self.maxSearchLimit),
                        "default": .int(Self.defaultSearchLimit),
                    ]),
                ],
                required: ["query"]
            ),
            Self.tool(
                "list_notes",
                title: "List notes",
                description: """
                    List the user's notes in Captylo (typed, dictated or voice notes), newest first: date \
                    and time, title (or the first line), the length of a recording and the note id. \
                    Optionally only notes whose title or text contain the query, or created on or after a date.
                    """,
                properties: [
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words to look for in the title and text (any Polish word form)."),
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 date (2026-10-01) or date and time; only notes created then or later."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(Self.maxListLimit),
                        "default": .int(Self.defaultListLimit),
                    ]),
                ],
                required: []
            ),
            Self.tool(
                "get_note",
                title: "Get a note",
                description: "One note as Markdown: title, date, the length of its recording and the full text.",
                properties: [
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The note id from list_notes or search_meetings."),
                    ]),
                ],
                required: ["id"]
            ),
        ]
    }

    /// Runs one tool. Throws `Failure.unknownTool` for a name not in `names` and
    /// `MeetingLibraryReader.Failure` when the store cannot be read.
    func call(name: String, arguments: JSONValue?) async throws -> Result {
        let arguments = arguments ?? .object([:])
        switch name {
        case "list_meetings":
            return try await listMeetings(arguments)
        case "get_meeting":
            return try await getMeeting(arguments)
        case "search_meetings":
            return try await searchMeetings(arguments)
        case "list_notes":
            return try await listNotes(arguments)
        case "get_note":
            return try await getNote(arguments)
        default:
            throw Failure.unknownTool(name)
        }
    }

    // MARK: Tools

    private func listMeetings(_ arguments: JSONValue) async throws -> Result {
        let limit = Self.clamped(arguments["limit"]?.intValue, default: Self.defaultListLimit, max: Self.maxListLimit)
        var since: Date?
        if let raw = arguments["since"]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let date = parseDate(raw) else {
                return Result(text: String(localized: "Nieprawidłowa data w „since”. Podaj datę jak 2026-10-01 albo datę z godziną w ISO 8601."), isError: true)
            }
            since = date
        }
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let opened = try await library.library()
        var meetings: [MeetingRecord]
        if !query.isEmpty, let index = opened.index,
           let found = try await MeetingSearchResults.load(
               query: query, index: index, database: opened.database, limit: Self.listSearchCandidates
           ) {
            meetings = found.meetings.sorted { $0.createdAt > $1.createdAt }
        } else {
            // Newest first, so the meetings since a date are always the first ones.
            meetings = try await opened.database.meetings(query: query, limit: since == nil ? limit : Self.listSearchCandidates)
        }
        if let since {
            meetings = meetings.filter { $0.createdAt >= since }
        }
        let lines = meetings.prefix(limit).map { meeting in
            var parts = [dateText(meeting.createdAt), Self.oneLine(meeting.title), MeetingTime.clock(meeting.duration)]
            if let app = meeting.appName, !app.isEmpty {
                parts.append(app)
            }
            if meeting.status == .recording {
                parts.append(String(localized: "nagrywa się teraz"))
            }
            parts.append("id: \(meeting.id.uuidString)")
            return "- " + parts.joined(separator: " · ")
        }
        guard !lines.isEmpty else { return Result(text: String(localized: "Brak spotkań.")) }
        return Result(text: lines.joined(separator: "\n"))
    }

    private func getMeeting(_ arguments: JSONValue) async throws -> Result {
        guard let raw = arguments["id"]?.stringValue,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            return Result(text: String(localized: "Podaj id spotkania z list_meetings albo search_meetings."), isError: true)
        }
        let opened = try await library.library()
        guard let meeting = try await opened.database.meeting(id: id) else {
            return Result(text: String(localized: "Nie ma spotkania o tym id."), isError: true)
        }
        let segments = try await opened.database.segments(meetingID: id)
        let transcript = arguments["transcript"]?.boolValue ?? true
        return Result(text: MeetingExport.markdown(meeting, segments: segments, includeTranscript: transcript))
    }

    private func searchMeetings(_ arguments: JSONValue) async throws -> Result {
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return Result(text: String(localized: "Podaj, czego szukać (query)."), isError: true)
        }
        let limit = Self.clamped(arguments["limit"]?.intValue, default: Self.defaultSearchLimit, max: Self.maxSearchLimit)
        let opened = try await library.library()
        let rows: [(meeting: MeetingRecord, lines: [MeetingSearchHitLine])]
        if let index = opened.index,
           let found = try await MeetingSearchResults.load(query: query, index: index, database: opened.database, limit: limit) {
            rows = found.meetings.map { ($0, found.lines[$0.id] ?? []) }
        } else {
            rows = try await storeSearch(query, limit: limit, database: opened.database)
        }
        var lines = rows.flatMap { row -> [String] in
            let head = "- \(Self.oneLine(row.meeting.title)) (\(dateText(row.meeting.createdAt)))"
            let tail = "· id: \(row.meeting.id.uuidString)"
            guard !row.lines.isEmpty else { return ["\(head) \(tail)"] }
            return row.lines.map { line in
                switch line.source {
                case .segment(_, let start):
                    return "\(head) \(MeetingTime.stamp(start)) \(line.label): \(line.snippet.text) \(tail)"
                case .notes:
                    return "\(head) \(line.label): \(line.snippet.text) \(tail)"
                }
            }
        }
        let notes = try await matchingNotes(query, limit: Self.searchNoteLimit, library: opened)
        lines += notes.map { note in
            let label = String(localized: "Notatka")
            return "- \(label): \(Self.oneLine(note.displayTitle)) (\(dateText(note.createdAt))) · note id: \(note.id.uuidString)"
        }
        guard !lines.isEmpty else { return Result(text: String(localized: "Nic nie znalazłem w spotkaniach ani notatkach.")) }
        return Result(text: lines.joined(separator: "\n"))
    }

    private func listNotes(_ arguments: JSONValue) async throws -> Result {
        let limit = Self.clamped(arguments["limit"]?.intValue, default: Self.defaultListLimit, max: Self.maxListLimit)
        var since: Date?
        if let raw = arguments["since"]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let date = parseDate(raw) else {
                return Result(text: String(localized: "Nieprawidłowa data w „since”. Podaj datę jak 2026-10-01 albo datę z godziną w ISO 8601."), isError: true)
            }
            since = date
        }
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let opened = try await library.library()
        var notes: [NoteRecord]
        if query.isEmpty {
            notes = try await opened.database.notes(query: "", limit: since == nil ? limit : Self.listSearchCandidates)
        } else {
            notes = try await matchingNotes(query, limit: Self.listSearchCandidates, library: opened)
                .sorted { $0.createdAt > $1.createdAt }
        }
        if let since {
            notes = notes.filter { $0.createdAt >= since }
        }
        let lines = notes.prefix(limit).map { note in
            var parts = [dateText(note.createdAt), Self.oneLine(note.displayTitle)]
            if note.hasAudio {
                parts.append(String(localized: "nagranie \(MeetingTime.clock(note.audioDuration))"))
            }
            parts.append("id: \(note.id.uuidString)")
            return "- " + parts.joined(separator: " · ")
        }
        guard !lines.isEmpty else { return Result(text: String(localized: "Brak notatek.")) }
        return Result(text: lines.joined(separator: "\n"))
    }

    private func getNote(_ arguments: JSONValue) async throws -> Result {
        guard let raw = arguments["id"]?.stringValue,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            return Result(text: String(localized: "Podaj id notatki z list_notes albo search_meetings."), isError: true)
        }
        let opened = try await library.library()
        guard let note = try await opened.database.note(id: id) else {
            return Result(text: String(localized: "Nie ma notatki o tym id."), isError: true)
        }
        var meta = [dateText(note.createdAt)]
        if note.hasAudio {
            meta.append(String(localized: "nagranie \(MeetingTime.clock(note.audioDuration))"))
        }
        var parts = ["# \(Self.oneLine(note.displayTitle))", meta.joined(separator: " · ")]
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }
        return Result(text: parts.joined(separator: "\n\n"))
    }

    /// The notes that match `query`: the index first (Polish forms, best first), else the
    /// store's `contains` search, newest first.
    private func matchingNotes(_ query: String, limit: Int, library: MeetingLibraryReader.Library) async throws -> [NoteRecord] {
        if let index = library.index, let terms = SearchQuery.terms(query),
           let hits = await index.noteHits(terms: terms, all: true, limit: limit) {
            return try await library.database.notes(ids: hits.map(\.noteID))
        }
        return try await library.database.notes(query: query, limit: limit)
    }

    /// The store's `contains` search (short queries, no index): newest first, each meeting with
    /// its first transcript line that contains the folded query, if any.
    private func storeSearch(
        _ query: String, limit: Int, database: Database
    ) async throws -> [(meeting: MeetingRecord, lines: [MeetingSearchHitLine])] {
        let folded = MeetingSearch.fold(query)
        var rows: [(meeting: MeetingRecord, lines: [MeetingSearchHitLine])] = []
        for meeting in try await database.meetings(query: query, limit: limit) {
            let segments = try await database.segments(meetingID: meeting.id)
            let first = segments.first { !$0.isEcho && MeetingSearch.fold($0.text).contains(folded) }
            let lines = first.map { segment in
                [MeetingSearchHitLine(
                    source: .segment(segment.id, start: segment.start),
                    label: meeting.label(for: segment),
                    snippet: MeetingSearchSnippet.make(segment.text, terms: [folded])
                )]
            } ?? []
            rows.append((meeting, lines))
        }
        return rows
    }

    // MARK: Helpers

    private static func tool(
        _ name: String, title: String, description: String, properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    private static func clamped(_ value: Int?, default fallback: Int, max upper: Int) -> Int {
        min(max(value ?? fallback, 1), upper)
    }

    /// A title on one line (a line break would start a new list item).
    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// "2026-10-02 14:00" in `timeZone`.
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// "2026-10-01" (the start of that day in `timeZone`) or an ISO 8601 date and time, with or
    /// without fractional seconds.
    private func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        if text.count == 10, let date = day.date(from: text) {
            return date
        }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) {
            return date
        }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text)
    }
}
