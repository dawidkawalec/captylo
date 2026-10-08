import Foundation
import os
import Testing
@testable import Captylo

/// The MCP server over in-memory lines: JSON-RPC framing, the setting, the three read-only tools
/// on a seeded in-memory store, and the store and index files opened read-only.
@Suite(.serialized)
struct MCPServerTests {
    private struct Fixture {
        let database: Database
        let index: MeetingSearchIndex
        let budget: MeetingRecord
        let client: MeetingRecord
        let offer: MeetingSegmentRecord
        /// A voice note (12 s) without a typed title, and an older typed note.
        let gate: NoteRecord
        let shopping: NoteRecord
    }

    /// Lines the server wrote.
    private final class Output: Sendable {
        private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

        var all: [String] { lines.withLock { $0 } }

        func write(_ line: String) {
            lines.withLock { $0.append(line) }
        }
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .current

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    /// "Budżet Q4" (Zoom, 47:12, Anna's offer at 12:34, an echo line) and "Rozmowa z klientem"
    /// four days earlier, in an in-memory store with an in-memory index.
    private static func seeded() async throws -> Fixture {
        let index = MeetingSearchIndex(url: nil)
        let database = Database(modelContainer: try Store.makeInMemoryContainer(), searchIndex: index)
        var budget = MeetingRecord(title: "Budżet Q4")
        budget.createdAt = try date("2026-10-02T14:00:00Z")
        budget.status = .completed
        budget.duration = 2832
        budget.appName = "Zoom"
        budget.participants = ["Anna Nowak"]
        budget.speakerNames = ["1": "Anna"]
        budget.notes = "Sprawdzić koszty kampanii"
        var client = MeetingRecord(title: "Rozmowa z klientem")
        client.createdAt = try date("2026-09-28T09:30:00Z")
        client.status = .completed
        client.duration = 1500
        try await database.createMeeting(budget)
        try await database.createMeeting(client)
        let offer = MeetingSegmentRecord(
            meetingID: budget.id, track: .them, start: 754, end: 760,
            text: "Wyślę ofertę jutro rano, razem z budżetem.", speaker: "1"
        )
        let segments = [
            MeetingSegmentRecord(meetingID: budget.id, track: .me, start: 10, end: 12, text: "Dzień dobry, zaczynamy."),
            offer,
            MeetingSegmentRecord(meetingID: budget.id, track: .me, start: 754, end: 760, text: "Echo z głośnika", isEcho: true),
            MeetingSegmentRecord(meetingID: client.id, track: .them, start: 60, end: 64, text: "Potrzebujemy wdrożenia do końca miesiąca."),
        ]
        for segment in segments {
            try await database.appendSegment(segment)
        }
        let gate = NoteRecord(
            createdAt: try date("2026-10-03T08:00:00Z"), title: "",
            body: "Kod do bramy u Ani: 4512.\nWejście od podwórza.", audioFileName: "gate.wav", audioDuration: 12
        )
        let shopping = NoteRecord(createdAt: try date("2026-09-20T18:00:00Z"), title: "Zakupy", body: "Mleko, chleb, kawa.")
        try await database.createNote(gate)
        try await database.createNote(shopping)
        return Fixture(
            database: database, index: index, budget: budget, client: client, offer: offer, gate: gate, shopping: shopping
        )
    }

    private static func server(
        _ reader: MeetingLibraryReader,
        enabled: Bool = true,
        input: AsyncStream<String> = AsyncStream { $0.finish() },
        output: Output = Output()
    ) -> MCPServer {
        MCPServer(
            input: input,
            output: { output.write($0) },
            tools: MCPTools(library: reader, timeZone: utc),
            isEnabled: { enabled },
            version: "1.2.3"
        )
    }

    private static func server(_ fixture: Fixture, enabled: Bool = true) -> MCPServer {
        server(MeetingLibraryReader(database: fixture.database, index: fixture.index), enabled: enabled)
    }

    /// Sends one line; the reply decoded, nil when the server stays silent.
    private static func send(_ server: MCPServer, _ line: String) async throws -> JSONValue? {
        guard let reply = await server.handle(line) else { return nil }
        #expect(!reply.contains("\n"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }

    private static func callLine(id: Int, _ tool: String, _ arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
    }

    /// A `tools/call` that must answer with a result: its text and whether it is an error.
    private static func call(_ server: MCPServer, _ tool: String, _ arguments: String = "{}") async throws -> (text: String, isError: Bool) {
        let reply = try #require(try await send(server, callLine(id: 9, tool, arguments)))
        let result = try #require(reply["result"])
        let text = try #require(result["content"]?[0]?["text"]?.stringValue)
        #expect(result["content"]?[0]?["type"] == .string("text"))
        return (text, result["isError"]?.boolValue ?? false)
    }

    private static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "captylo-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Protocol

    @Test func initializeNamesTheServerAndItsToolsCapability() async throws {
        let server = Self.server(try await Self.seeded())
        let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        let reply = try #require(try await Self.send(server, line))
        #expect(reply["jsonrpc"] == .string("2.0"))
        #expect(reply["id"] == .int(1))
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == .string("2025-06-18"))
        #expect(result["serverInfo"]?["name"] == .string("captylo"))
        #expect(result["serverInfo"]?["version"] == .string("1.2.3"))
        #expect(result["capabilities"]?["tools"] != nil)
    }

    @Test func initializeAgreesOnAnOlderVersionTheClientAsksFor() async throws {
        let server = Self.server(try await Self.seeded())
        let older = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
        #expect(older["result"]?["protocolVersion"] == .string("2024-11-05"))
        let unknown = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknown["result"]?["protocolVersion"] == .string(MCPServer.protocolVersion))
    }

    @Test func notificationsGetNoReply() async throws {
        let server = Self.server(try await Self.seeded())
        #expect(try await Self.send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await Self.send(server, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#) == nil)
        #expect(try await Self.send(server, #"{"jsonrpc":"2.0","method":"something/unknown"}"#) == nil)
        // A response to a request the server never sent is ignored too.
        #expect(try await Self.send(server, #"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)
        #expect(try await Self.send(server, "   ") == nil)
    }

    @Test func pingEchoesStringIDs() async throws {
        let server = Self.server(try await Self.seeded())
        let reply = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#))
        #expect(reply["id"] == .string("abc-1"))
        #expect(reply["result"] == .object([:]))
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let server = Self.server(try await Self.seeded())
        let reply = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#))
        #expect(reply["id"] == .int(7))
        #expect(reply["error"]?["code"] == .int(-32601))
        #expect(reply["result"] == nil)
    }

    @Test func malformedJSONIsAParseError() async throws {
        let server = Self.server(try await Self.seeded())
        let reply = try #require(try await Self.send(server, "{not json"))
        #expect(reply["id"] == .null)
        #expect(reply["error"]?["code"] == .int(-32700))
    }

    @Test func aMessageThatIsNotARequestIsInvalid() async throws {
        let server = Self.server(try await Self.seeded())
        let noMethod = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":3}"#))
        #expect(noMethod["id"] == .int(3))
        #expect(noMethod["error"]?["code"] == .int(-32600))
        let batch = try #require(try await Self.send(server, "[1,2]"))
        #expect(batch["id"] == .null)
        #expect(batch["error"]?["code"] == .int(-32600))
    }

    @Test func toolsListShowsTheFiveToolsOnlyWhenTheSettingIsOn() async throws {
        let fixture = try await Self.seeded()
        let line = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let on = try #require(try await Self.send(Self.server(fixture), line))
        let tools = try #require(on["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["list_meetings", "get_meeting", "search_meetings", "list_notes", "get_note"])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == .string("object"))
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
        }
        let off = try #require(try await Self.send(Self.server(fixture, enabled: false), line))
        #expect(off["result"]?["tools"] == .array([]))
    }

    @Test func aToolCallWhileOffSaysWhereToTurnItOn() async throws {
        let server = Self.server(try await Self.seeded(), enabled: false)
        let answer = try await Self.call(server, "list_meetings")
        #expect(answer.isError)
        #expect(answer.text == MCPServer.disabledMessage)
        #expect(answer.text.contains("Ustawienia > Spotkania"))
    }

    @Test func anUnknownToolIsInvalidParams() async throws {
        let server = Self.server(try await Self.seeded())
        let reply = try #require(try await Self.send(server, Self.callLine(id: 4, "delete_meeting", "{}")))
        #expect(reply["id"] == .int(4))
        #expect(reply["error"]?["code"] == .int(-32602))
    }

    @Test func runWritesOnlyJSONLinesForRequests() async throws {
        let fixture = try await Self.seeded()
        let (input, feed) = AsyncStream<String>.makeStream()
        for line in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
            "garbage",
            Self.callLine(id: 4, "list_meetings", "{}"),
        ] {
            feed.yield(line)
        }
        feed.finish()
        let output = Output()
        let server = Self.server(
            MeetingLibraryReader(database: fixture.database, index: fixture.index), input: input, output: output
        )
        await server.run()
        let lines = output.all
        #expect(lines.count == 5)
        var ids: [JSONValue?] = []
        for line in lines {
            #expect(!line.contains("\n"))
            let message = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            #expect(message["jsonrpc"] == .string("2.0"))
            ids.append(message["id"])
        }
        #expect(ids == [.int(1), .int(2), .int(3), .null, .int(4)])
    }

    // MARK: Tools

    @Test func listMeetingsNewestFirstWithDateLengthAppAndID() async throws {
        let fixture = try await Self.seeded()
        let answer = try await Self.call(Self.server(fixture), "list_meetings")
        #expect(!answer.isError)
        #expect(answer.text == """
            - 2026-10-02 14:00 · Budżet Q4 · 47:12 · Zoom · id: \(fixture.budget.id.uuidString)
            - 2026-09-28 09:30 · Rozmowa z klientem · 25:00 · id: \(fixture.client.id.uuidString)
            """)
    }

    @Test func listMeetingsFiltersByTextDateAndLimit() async throws {
        let fixture = try await Self.seeded()
        let server = Self.server(fixture)
        let budget = "id: \(fixture.budget.id.uuidString)"
        let client = "id: \(fixture.client.id.uuidString)"

        // Another form of a transcript word (the index), and a word of the title.
        let inflected = try await Self.call(server, "list_meetings", #"{"query":"wdrożenie"}"#)
        #expect(inflected.text.contains(client) && !inflected.text.contains(budget))
        let titled = try await Self.call(server, "list_meetings", #"{"query":"klient"}"#)
        #expect(titled.text.contains(client) && !titled.text.contains(budget))

        let sinceDay = try await Self.call(server, "list_meetings", #"{"since":"2026-10-01"}"#)
        #expect(sinceDay.text.contains(budget) && !sinceDay.text.contains(client))
        let sinceMoment = try await Self.call(server, "list_meetings", #"{"since":"2026-10-02T14:00:00Z"}"#)
        #expect(sinceMoment.text.contains(budget) && !sinceMoment.text.contains(client))

        let limited = try await Self.call(server, "list_meetings", #"{"limit":1}"#)
        #expect(limited.text.contains(budget) && !limited.text.contains(client))

        let none = try await Self.call(server, "list_meetings", #"{"since":"2027-01-01"}"#)
        #expect(!none.isError)
        #expect(!none.text.contains("id:"))

        let badDate = try await Self.call(server, "list_meetings", #"{"since":"wczoraj"}"#)
        #expect(badDate.isError)
    }

    // MARK: Notes (1.0.16)

    @Test func listNotesNewestFirstWithDateTitleRecordingAndID() async throws {
        let fixture = try await Self.seeded()
        let answer = try await Self.call(Self.server(fixture), "list_notes")
        #expect(!answer.isError)
        #expect(answer.text == """
            - 2026-10-03 08:00 · Kod do bramy u Ani: 4512. · nagranie 0:12 · id: \(fixture.gate.id.uuidString)
            - 2026-09-20 18:00 · Zakupy · id: \(fixture.shopping.id.uuidString)
            """)
    }

    @Test func listNotesFiltersByTextDateAndLimit() async throws {
        let fixture = try await Self.seeded()
        let server = Self.server(fixture)
        let gate = "id: \(fixture.gate.id.uuidString)"
        let shopping = "id: \(fixture.shopping.id.uuidString)"
        // "bramy" through the index finds the form in the note ("bramę" would too).
        let byText = try await Self.call(server, "list_notes", #"{"query":"brama"}"#)
        #expect(byText.text.contains(gate) && !byText.text.contains(shopping))
        let since = try await Self.call(server, "list_notes", #"{"since":"2026-10-01"}"#)
        #expect(since.text.contains(gate) && !since.text.contains(shopping))
        let one = try await Self.call(server, "list_notes", #"{"limit":1}"#)
        #expect(one.text.contains(gate) && !one.text.contains(shopping))
        #expect(try await Self.call(server, "list_notes", #"{"since":"wczoraj"}"#).isError)
        let none = try await Self.call(server, "list_notes", #"{"query":"helikopter"}"#)
        #expect(!none.isError && !none.text.contains("id:"))
    }

    @Test func getNoteReturnsTheTitleDateAndText() async throws {
        let fixture = try await Self.seeded()
        let server = Self.server(fixture)
        let answer = try await Self.call(server, "get_note", #"{"id":"\#(fixture.gate.id.uuidString)"}"#)
        #expect(!answer.isError)
        #expect(answer.text.hasPrefix("# Kod do bramy u Ani: 4512.\n"))
        #expect(answer.text.contains("2026-10-03 08:00"))
        #expect(answer.text.contains("0:12"))
        #expect(answer.text.hasSuffix("Kod do bramy u Ani: 4512.\nWejście od podwórza."))
        #expect(try await Self.call(server, "get_note", #"{"id":"\#(UUID().uuidString)"}"#).isError)
        #expect(try await Self.call(server, "get_note", #"{"id":"nie-uuid"}"#).isError)
    }

    @Test func searchMeetingsAlsoListsMatchingNotes() async throws {
        let fixture = try await Self.seeded()
        let server = Self.server(fixture)
        let answer = try await Self.call(server, "search_meetings", #"{"query":"kod do bramy"}"#)
        #expect(!answer.isError)
        #expect(answer.text.contains("- Notatka: Kod do bramy u Ani: 4512. (2026-10-03 08:00) · note id: \(fixture.gate.id.uuidString)"))
        #expect(!answer.text.contains(fixture.budget.id.uuidString))
        // A meeting query that matches no note answers exactly as before.
        let meetings = try await Self.call(server, "search_meetings", #"{"query":"oferta"}"#)
        #expect(!meetings.text.contains("Notatka:"))
    }

    @Test func getMeetingReturnsTheMarkdownExport() async throws {
        let fixture = try await Self.seeded()
        let server = Self.server(fixture)
        let full = try await Self.call(server, "get_meeting", #"{"id":"\#(fixture.budget.id.uuidString)"}"#)
        #expect(!full.isError)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.budget.id))
        let segments = try await fixture.database.segments(meetingID: fixture.budget.id)
        #expect(full.text == MeetingExport.markdown(meeting, segments: segments))
        #expect(full.text.contains("# Budżet Q4"))
        #expect(full.text.contains("Anna Nowak"))
        #expect(full.text.contains("Sprawdzić koszty kampanii"))
        #expect(full.text.contains("**[12:34] Anna:** Wyślę ofertę jutro rano, razem z budżetem."))
        #expect(!full.text.contains("Echo z głośnika"))

        let short = try await Self.call(server, "get_meeting", #"{"id":"\#(fixture.budget.id.uuidString)","transcript":false}"#)
        #expect(!short.isError)
        #expect(short.text.contains("# Budżet Q4"))
        #expect(short.text.contains("47:12"))
        #expect(!short.text.contains("Wyślę ofertę"))
    }

    @Test func getMeetingWithAnUnknownOrBadIDIsAnErrorResult() async throws {
        let server = Self.server(try await Self.seeded())
        #expect(try await Self.call(server, "get_meeting", #"{"id":"\#(UUID().uuidString)"}"#).isError)
        #expect(try await Self.call(server, "get_meeting", #"{"id":"nope"}"#).isError)
        #expect(try await Self.call(server, "get_meeting").isError)
    }

    @Test func searchMeetingsFindsPolishFormsWithTheMomentAndSpeaker() async throws {
        let fixture = try await Self.seeded()
        let answer = try await Self.call(Self.server(fixture), "search_meetings", #"{"query":"oferta"}"#)
        #expect(!answer.isError)
        #expect(answer.text == "- Budżet Q4 (2026-10-02 14:00) [12:34] Anna: Wyślę ofertę jutro rano, razem z budżetem. · id: \(fixture.budget.id.uuidString)")
    }

    @Test func searchMeetingsFallsBackToTheStoreWithoutTheIndex() async throws {
        let fixture = try await Self.seeded()
        // Two letters never reach the index: the title still matches.
        let short = try await Self.call(Self.server(fixture), "search_meetings", #"{"query":"Q4"}"#)
        #expect(short.text == "- Budżet Q4 (2026-10-02 14:00) · id: \(fixture.budget.id.uuidString)")
        // No index at all: the store's search, with the first matching line.
        let reader = MeetingLibraryReader(database: fixture.database, index: nil)
        let answer = try await Self.call(Self.server(reader), "search_meetings", #"{"query":"ofertę"}"#)
        #expect(answer.text == "- Budżet Q4 (2026-10-02 14:00) [12:34] Anna: Wyślę ofertę jutro rano, razem z budżetem. · id: \(fixture.budget.id.uuidString)")
    }

    @Test func searchMeetingsSaysWhenNothingMatchesAndNeedsAQuery() async throws {
        let server = Self.server(try await Self.seeded())
        let nothing = try await Self.call(server, "search_meetings", #"{"query":"helikopter"}"#)
        #expect(!nothing.isError)
        #expect(!nothing.text.isEmpty && !nothing.text.contains("id:"))
        #expect(try await Self.call(server, "search_meetings", #"{"query":"  "}"#).isError)
        #expect(try await Self.call(server, "search_meetings").isError)
    }

    // MARK: Files

    @Test func aStoreThatCannotBeOpenedFailsEveryCallWithAMessage() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "captylo-mcp-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let reader = MeetingLibraryReader(
            storeURL: folder.appending(path: Store.configurationName + ".store"),
            indexURL: folder.appending(path: MeetingSearchIndex.fileName)
        )
        let server = Self.server(reader)
        let reply = try #require(try await Self.send(server, Self.callLine(id: 6, "list_meetings", "{}")))
        #expect(reply["id"] == .int(6))
        #expect(reply["error"]?["code"] == .int(-32603))
        #expect(reply["error"]?["message"]?.stringValue == MeetingLibraryReader.Failure.storeUnavailable.errorDescription)
        let tools = try #require(try await Self.send(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#))
        #expect(tools["result"]?["tools"]?.arrayValue?.count == MCPTools.names.count)
        // Nothing was created on the way.
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test func theStoreIsReadOnlyAndNewMeetingsAppear() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storeURL = folder.appending(path: Store.configurationName + ".store")
        let indexURL = folder.appending(path: MeetingSearchIndex.fileName)
        let writer = Database(modelContainer: try Store.openContainer(at: storeURL))
        let first = MeetingRecord(title: "Pierwsze", status: .completed)
        try await writer.createMeeting(first)

        let server = Self.server(MeetingLibraryReader(storeURL: storeURL, indexURL: indexURL))
        let before = try FileManager.default.attributesOfItem(atPath: storeURL.path(percentEncoded: false))
        let listed = try await Self.call(server, "list_meetings")
        #expect(listed.text.contains(first.id.uuidString))
        let after = try FileManager.default.attributesOfItem(atPath: storeURL.path(percentEncoded: false))
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.size] as? Int == after[.size] as? Int)
        // The reader never creates the index file.
        #expect(!FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))

        // A meeting saved by the app meanwhile shows up without restarting the server.
        var second = MeetingRecord(title: "Drugie", status: .completed)
        second.createdAt = first.createdAt.addingTimeInterval(60)
        try await writer.createMeeting(second)
        let again = try await Self.call(server, "list_meetings")
        #expect(again.text.contains(second.id.uuidString))
        #expect(again.text.contains(first.id.uuidString))
    }

    /// A store closed cleanly may have no `-wal` file, and SQLite cannot open a WAL database
    /// read-only without one (SQLITE_CANTOPEN): the reader puts an empty one next to it first.
    @Test func aStoreAndIndexWithoutTheirWALFilesStillOpen() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = MeetingSearchIndex(url: folder.appending(path: MeetingSearchIndex.fileName))
        let writer = Database(
            modelContainer: try Store.openContainer(at: folder.appending(path: Store.configurationName + ".store")),
            searchIndex: index
        )
        let meeting = MeetingRecord(title: "Sprzedaż", status: .completed)
        try await writer.createMeeting(meeting)
        try await writer.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 30, end: 33, text: "Wyślę ofertę jutro"))
        #expect(await index.prepare(database: writer) != .unavailable)

        // Closed copies of both files, in WAL mode, with no `-wal` or `-shm` next to them.
        let copy = folder.appending(path: "copy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in [Store.configurationName + ".store", MeetingSearchIndex.fileName] {
            let source = folder.appending(path: name).path(percentEncoded: false)
            let target = copy.appending(path: name).path(percentEncoded: false)
            do {
                try SQLiteConnection(path: source).execute("VACUUM INTO '\(target)'")
                let file = try SQLiteConnection(path: target)
                try file.execute("PRAGMA journal_mode = WAL")
            }
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: target + suffix)
            }
            #expect(!FileManager.default.fileExists(atPath: target + "-wal"))
        }

        let server = Self.server(MeetingLibraryReader(
            storeURL: copy.appending(path: Store.configurationName + ".store"),
            indexURL: copy.appending(path: MeetingSearchIndex.fileName)
        ))
        let listed = try await Self.call(server, "list_meetings")
        #expect(listed.text.contains(meeting.id.uuidString))
        // "oferta" finds "ofertę" only through the index.
        let found = try await Self.call(server, "search_meetings", #"{"query":"oferta"}"#)
        #expect(found.text.contains("[0:30]"))
    }

    @Test func theIndexIsReadOnlyAndAnswersOnlyAfterAFullBuild() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storeURL = folder.appending(path: Store.configurationName + ".store")
        let indexURL = folder.appending(path: MeetingSearchIndex.fileName)

        // No file yet: nothing to answer from (the caller falls back), nothing created.
        let missing = MeetingSearchIndex(url: indexURL, readOnly: true)
        #expect(await missing.search("oferta", limit: 10) == nil)
        #expect(!FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)))

        let index = MeetingSearchIndex(url: indexURL)
        let writer = Database(modelContainer: try Store.openContainer(at: storeURL), searchIndex: index)
        let meeting = MeetingRecord(title: "Sprzedaż", status: .completed)
        try await writer.createMeeting(meeting)
        let offer = MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 30, end: 33, text: "Wyślę ofertę jutro")
        try await writer.appendSegment(offer)
        #expect(await index.prepare(database: writer) != .unavailable)

        let reading = MeetingSearchIndex(url: indexURL, readOnly: true)
        #expect(try #require(await reading.search("oferta", limit: 10)).compactMap(\.segmentID) == [offer.id])
        // Writes through a read-only index go nowhere.
        reading.removeMeeting(meeting.id)
        let fresh = MeetingSearchIndex(url: indexURL, readOnly: true)
        #expect(await fresh.search("oferta", limit: 10)?.count == 1)

        // The MCP search uses the index (the store's search would not find "oferta" in "ofertę").
        let server = Self.server(MeetingLibraryReader(storeURL: storeURL, indexURL: indexURL))
        let answer = try await Self.call(server, "search_meetings", #"{"query":"oferta"}"#)
        #expect(answer.text.contains("[0:30]"))
        #expect(answer.text.contains(meeting.id.uuidString))

        // Mid-rebuild (no "meetings" mark yet) the read-only index does not answer.
        let raw = try SQLiteConnection(path: indexURL.path(percentEncoded: false))
        try raw.execute("DELETE FROM meta")
        let midBuild = MeetingSearchIndex(url: indexURL, readOnly: true)
        #expect(await midBuild.search("oferta", limit: 10) == nil)
    }

    // MARK: Settings

    @Test func theCopiedConfigurationStartsThisAppInMCPMode() throws {
        let path = "/Applications/Captylo.app/Contents/MacOS/Captylo"
        let text = MCPSettingsRow.configuration(executablePath: path)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(json["mcpServers"]?["captylo"]?["command"] == .string(path))
        #expect(json["mcpServers"]?["captylo"]?["args"] == .array([.string("--mcp")]))
        #expect(text.contains("\n"))
        #expect(!text.contains("\\/"))
    }
}
