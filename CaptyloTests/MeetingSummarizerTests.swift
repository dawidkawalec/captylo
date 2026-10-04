import Foundation
import os
import Testing
@testable import Captylo

/// `MeetingSummarizer` over the stubbed network, and `MeetingNotesProcessor` storing its result.
struct MeetingSummarizerTests {
    private static let model = Enhancer.relayModelPlaceholder
    private static let notes = "## Podsumowanie\n- Wdrożenie w piątek [0:01]"

    private static func segments(_ id: UUID) -> [MeetingSegmentRecord] {
        [MeetingSegmentRecord(meetingID: id, track: .them, start: 1, end: 3, text: "Wdrożenie przesuwamy na piątek, testy do czwartku.")]
    }

    private static func chat(_ content: String, finish: String = "stop") -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"choices":[{"message":{"content":"\#(escaped)"},"finish_reason":"\#(finish)"}]}"#
    }

    /// The Pro relay: the session as the key, no model (the server picks it); nil = no Pro session.
    private static func summarizer(_ handler: @escaping StubURLProtocol.Handler, key: String? = "session-token") -> (MeetingSummarizer, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let client = OpenRouterClient(baseURL: baseURL)
        let summarizer = MeetingSummarizer(
            session: StubURLProtocol.makeSession(),
            route: { key.map { AIRoute(client: client, key: $0, model: nil) } }
        )
        return (summarizer, baseURL)
    }

    @Test func proRelayWritesNotesAsCaptyloAI() async throws {
        let seen = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let (summarizer, baseURL) = Self.summarizer { request in
            seen.withLock { $0 = request }
            // Whatever the answer names, history keeps "captylo-ai".
            return .json(###"{"model":"vendor/some-model","choices":[{"message":{"content":"## Podsumowanie\n- ok"},"finish_reason":"stop"}]}"###)
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "Standup")
        let out = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.standup)
        #expect(out.markdown == "## Podsumowanie\n- ok")
        #expect(out.model == Enhancer.relayModelPlaceholder)
        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        let body = Self.json(Self.rawBody(of: request))
        #expect(body["model"] as? String == Enhancer.relayModelPlaceholder)
        #expect((body["reasoning"] as? [String: Any])?["enabled"] as? Bool == false)
        let task = try #require(body["captylo_task"] as? [String: Any])
        #expect(task["kind"] as? String == "meeting_notes")
        #expect(task["template"] as? String == "standup")
        let roles = (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
        #expect(roles == ["user"])
    }

    @Test func anOwnKeyRouteIsRefused() async throws {
        let meeting = MeetingRecord(title: "x")
        let ownKey = MeetingSummarizer(session: .shared, route: { AIRoute(client: OpenRouterClient(), key: "sk-or-test", model: "m") })
        await #expect(throws: MeetingSummaryError.noKey) {
            try await ownKey.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        }
    }

    @Test func proRelayQuotaAndRefusalAreTyped() async throws {
        let meeting = MeetingRecord(title: "x")
        let replies: [(StubURLProtocol.Reply, MeetingSummaryError)] = [
            (.json(#"{"error":"quota_exceeded","resetsAt":"2026-11-01T00:00:00.000Z"}"#, status: 402), .quotaExceeded),
            (.json(#"{"error":"pro_required"}"#, status: 403), .noKey),
            (.json(#"{"error":"unauthorized"}"#, status: 401), .noKey),
            (.json(#"{"error":"upstream_failed"}"#, status: 502), .server(502)),
        ]
        for (reply, expected) in replies {
            let (summarizer, baseURL) = Self.summarizer { _ in reply }
            defer { StubURLProtocol.unregister(baseURL) }
            await #expect(throws: expected) {
                try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
            }
        }
    }

    private static func rawBody(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return data
    }

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func messages(_ body: [String: Any]) -> [String] {
        (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
    }

    /// `captylo_task.template` of the request body.
    private static func template(of request: URLRequest) -> String? {
        (json(rawBody(of: request))["captylo_task"] as? [String: Any])?["template"] as? String
    }

    // MARK: Summarizer

    @Test func returnsTheMarkdownAndModel() async throws {
        let seen = OSAllocatedUnfairLock(initialState: Data())
        let (summarizer, baseURL) = Self.summarizer { request in
            let data = Self.rawBody(of: request)
            seen.withLock { $0 = data }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "Standup")
        let out = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.standup)
        #expect(out.markdown == Self.notes)
        #expect(out.model == Self.model)

        let body = Self.json(seen.withLock { $0 })
        #expect(body["model"] as? String == Self.model)
        #expect(body["max_tokens"] as? Int == MeetingSummarizer.maxTokens)
        let messages = Self.messages(body)
        #expect(messages.count == 1)
        #expect(messages.last?.contains("[0:01] Rozmówcy: Wdrożenie przesuwamy na piątek") == true)
    }

    @Test func missingKeyAndEmptyTranscriptFailClearly() async throws {
        let meeting = MeetingRecord(title: "x")
        let noKey = MeetingSummarizer(session: .shared, route: { nil })
        await #expect(throws: MeetingSummaryError.noKey) {
            try await noKey.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        }
        let blankKey = MeetingSummarizer(session: .shared, route: { AIRoute(client: OpenRouterClient(), key: "", model: nil) })
        await #expect(throws: MeetingSummaryError.noKey) {
            try await blankKey.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        }
        let withKey = MeetingSummarizer(session: .shared, route: { AIRoute(client: OpenRouterClient(), key: "k", model: nil) })
        await #expect(throws: MeetingSummaryError.noTranscript) {
            try await withKey.summarize(meeting: meeting, segments: [], template: BuiltInMeetingTemplates.general)
        }
        // Echo is never sent, so a transcript of echo alone is as good as none.
        var echo = Self.segments(meeting.id)[0]
        echo.isEcho = true
        await #expect(throws: MeetingSummaryError.noTranscript) {
            try await withKey.summarize(meeting: meeting, segments: [echo], template: BuiltInMeetingTemplates.general)
        }
    }

    @Test func serverErrorsTimeoutsAndEmptyAnswersAreTyped() async throws {
        let meeting = MeetingRecord(title: "x")
        let replies: [(StubURLProtocol.Reply, MeetingSummaryError)] = [
            (.json(#"{"error":{"message":"boom","code":502}}"#, status: 502), .server(502)),
            (.json("{}", status: 429), .server(429)),
            (.failure(.timedOut), .timedOut),
            (.json(Self.chat("   ")), .empty),
            (.json(Self.chat("<think>plan</think>")), .empty),
        ]
        for (reply, expected) in replies {
            let (summarizer, baseURL) = Self.summarizer { _ in reply }
            defer { StubURLProtocol.unregister(baseURL) }
            await #expect(throws: expected) {
                try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
            }
        }
    }

    @Test func errorMessagesReuseTheAppsKeyAndStatusTexts() {
        #expect(MeetingSummaryError.noKey.errorDescription == "Brak dostępu do AI spotkań. Włącz Captylo Pro.")
        #expect(MeetingSummaryError.quotaExceeded.errorDescription == "Limit AI w tym miesiącu jest wyczerpany.")
        #expect(MeetingSummaryError.server(401).errorDescription == OpenRouterError.unauthorized.errorDescription)
        #expect(MeetingSummaryError.server(429).errorDescription == OpenRouterError.rateLimited.errorDescription)
        #expect(MeetingSummaryError.server(500).errorDescription?.contains("500") == true)
    }

    @Test func stripsReasoningFromTheAnswer() async throws {
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat("<think>plan</think>\n" + Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "x")
        let out = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        #expect(out.markdown == Self.notes)
    }

    @Test func meetingSessionOutlastsALongAnswer() {
        let configuration = HTTP.meetingLLMSession.configuration
        #expect(configuration.timeoutIntervalForRequest == 150)
        #expect(configuration.timeoutIntervalForResource == 180)
    }

    // MARK: Processor

    private struct Fixture {
        let database: Database
        let meetingID: UUID
    }

    private static func fixture(title: String = "Daily standup") async throws -> Fixture {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        var meeting = MeetingRecord(title: title)
        meeting.status = .processing
        meeting.summaryError = "stary błąd"
        try await database.createMeeting(meeting)
        for segment in Self.segments(meeting.id) {
            try await database.appendSegment(segment)
        }
        return Fixture(database: database, meetingID: meeting.id)
    }

    private static func processor(_ fixture: Fixture, summarizer: MeetingSummarizer, allowed: Bool = true) -> MeetingNotesProcessor {
        MeetingNotesProcessor(database: fixture.database, summarizer: summarizer, isAllowed: { allowed })
    }

    @Test func storesTheNotesTemplateAndModel() async throws {
        let fixture = try await Self.fixture()
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: fixture.meetingID)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == Self.notes)
        #expect(meeting.summaryTemplateID == "standup")
        #expect(meeting.summaryModel == Self.model)
        #expect(meeting.summaryError == nil)
        #expect(meeting.status == .processing)
    }

    @Test func storesThePolishErrorAndKeepsEarlierNotes() async throws {
        let fixture = try await Self.fixture()
        var meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        meeting.summary = "## Podsumowanie\n- wcześniejsze"
        try await fixture.database.updateMeeting(meeting)
        let (summarizer, baseURL) = Self.summarizer({ _ in .json(Self.chat(Self.notes)) }, key: nil)
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: fixture.meetingID)
        meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summaryError == MeetingSummaryError.noKey.errorDescription)
        #expect(meeting.summary == "## Podsumowanie\n- wcześniejsze")
    }

    @Test func freePlanMakesNoCall() async throws {
        let fixture = try await Self.fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (summarizer, baseURL) = Self.summarizer { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer, allowed: false).process(meetingID: fixture.meetingID)
        #expect(calls.withLock { $0 } == 0)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == nil)
        #expect(meeting.summaryError == "stary błąd")
    }

    @Test func regenerateUsesThePickedTemplate() async throws {
        let fixture = try await Self.fixture()
        let templates = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let (summarizer, baseURL) = Self.summarizer { request in
            let template = Self.template(of: request)
            templates.withLock { $0.append(template) }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).regenerate(meetingID: fixture.meetingID, templateID: "client")
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summaryTemplateID == "client")
        #expect(templates.withLock { $0 } == ["client"])
    }

    /// The call can take minutes: notes and a title typed meanwhile must survive the save.
    @Test func keepsEditsMadeWhileTheNotesWereWritten() async throws {
        let fixture = try await Self.fixture()
        let requested = OSAllocatedUnfairLock(initialState: false)
        let (summarizer, baseURL) = Self.summarizer { _ in
            requested.withLock { $0 = true }
            return .json(Self.chat(Self.notes), delay: .milliseconds(800))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let processor = Self.processor(fixture, summarizer: summarizer)
        let run = Task { await processor.process(meetingID: fixture.meetingID) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !requested.withLock({ $0 }), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        var edited = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        edited.title = "Standup po zmianie"
        edited.notes = "dopisane w trakcie"
        try await fixture.database.updateMeeting(edited)
        await run.value

        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == Self.notes)
        #expect(meeting.title == "Standup po zmianie")
        #expect(meeting.notes == "dopisane w trakcie")
    }

    @Test func aDeletedMeetingIsLeftAlone() async throws {
        let fixture = try await Self.fixture()
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: UUID())
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == nil)
    }
}
