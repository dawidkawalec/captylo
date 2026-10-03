import Foundation
import os
import Testing
@testable import Captylo

/// "Zapytaj" about one meeting: the prompt, `MeetingAsker` over the stubbed network storing the
/// exchange on the row, and `MeetingAskRuns`.
struct MeetingAskTests {
    private static let model = "openai/gpt-4.1-mini"
    private static let answer = "- Dwutygodniowy test LinkedIn, do 5 tys. zł [1:45]"

    private static func chat(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"choices":[{"message":{"content":"\#(escaped)"},"finish_reason":"stop"}]}"#
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

    // MARK: Prompt

    @Test func systemPromptGroundsTheAnswerInThisMeeting() {
        let system = MeetingAskPrompt.system
        #expect(system.contains(MeetingAskPrompt.notFound))
        #expect(MeetingAskPrompt.notFound == "Nie znalazłem tego w tym spotkaniu.")
        #expect(system.contains(MeetingAskPrompt.notFoundEnglish))
        #expect(system.contains("[mm:ss]"))
        #expect(system.contains("[h:mm:ss]"))
        #expect(system.contains("w języku pytania"))
        #expect(system.contains("Nie wymyślaj"))
        #expect(!system.contains("\u{2014}") && !system.contains("\u{2013}"))
    }

    @Test func userMessageCarriesTheMeetingNotesTranscriptAndQuestion() throws {
        let id = UUID()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z"))
        var meeting = MeetingRecord(id: id, createdAt: date, title: "Budżet Q4")
        meeting.participants = ["Anna Kowalska", " ", "Piotr Nowak"]
        meeting.noteLines = [MeetingNoteLine(text: "budżet reklam", at: 65), MeetingNoteLine(text: "  ", at: 70)]
        meeting.speakerNames = ["1": "Anna"]
        let segments = [
            MeetingSegmentRecord(meetingID: id, track: .them, start: 65, end: 70, text: "Dwadzieścia tysięcy.", speaker: "1"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 61, end: 64, text: "Ile mamy na reklamy?"),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 66, end: 69, text: "odbite echo", isEcho: true),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 72, end: 74, text: "A ile na targi?", speaker: "2"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 3_725, end: 3_727, text: "Do zobaczenia."),
        ]
        let user = MeetingAskPrompt.user(meeting: meeting, segments: segments, question: "  Ile na reklamy?  ", history: [])
        #expect(user.contains("Tytuł: Budżet Q4"))
        #expect(user.contains("Data: 2 października 2026"))
        #expect(user.contains("Uczestnicy: Anna Kowalska, Piotr Nowak\n"))
        #expect(user.contains("<user_notes>\n[1:05] budżet reklam\n</user_notes>"))
        #expect(user.contains("<transcript>\n[1:01] Ja: Ile mamy na reklamy?\n[1:05] Anna: Dwadzieścia tysięcy.\n[1:12] Mówca 2: A ile na targi?"))
        #expect(user.contains("[1:02:05] Rozmówcy: Do zobaczenia.\n</transcript>"))
        #expect(!user.contains("echo"))
        #expect(!user.contains("<previous_questions>"))
        #expect(user.hasSuffix("<question>\nIle na reklamy?\n</question>"))
    }

    /// Notes typed before line times existed (no `noteLines`) still reach the prompt.
    @Test func plainNotesWithoutLineTimesAreSent() {
        var meeting = MeetingRecord(title: "Stare spotkanie")
        meeting.notes = "pierwsza myśl\ndruga"
        let user = MeetingAskPrompt.user(meeting: meeting, segments: [], question: "Co?", history: [])
        #expect(user.contains("<user_notes>\npierwsza myśl\ndruga\n</user_notes>"))
        #expect(!user.contains("Uczestnicy:"))
    }

    @Test func historyKeepsTheLastThreeAnsweredQuestions() {
        let meeting = MeetingRecord(title: "x")
        let history = [
            MeetingQuestion(question: "Pytanie 1", answer: "Odpowiedź 1"),
            MeetingQuestion(question: "Pytanie 2", answer: "Odpowiedź 2"),
            MeetingQuestion(question: "Pytanie 3", error: "Brak klucza"),
            MeetingQuestion(question: "Pytanie 4", answer: "Odpowiedź 4"),
            MeetingQuestion(question: "Pytanie 5", answer: "  "),
            MeetingQuestion(question: "Pytanie 6", answer: "Odpowiedź 6"),
        ]
        let user = MeetingAskPrompt.user(meeting: meeting, segments: [], question: "A kto?", history: history)
        #expect(!user.contains("Pytanie 1"))
        #expect(user.contains("<previous_questions>\nPytanie: Pytanie 2\nOdpowiedź: Odpowiedź 2\n\nPytanie: Pytanie 4\nOdpowiedź: Odpowiedź 4\n\nPytanie: Pytanie 6\nOdpowiedź: Odpowiedź 6\n</previous_questions>"))
        #expect(!user.contains("Pytanie 3"))
        #expect(!user.contains("Pytanie 5"))
        #expect(MeetingAskPrompt.historyLimit == 3)
    }

    // MARK: Asker

    private struct Fixture {
        let database: Database
        let meetingID: UUID
    }

    private static func fixture(questions: [MeetingQuestion] = [], status: MeetingStatus = .completed) async throws -> Fixture {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        var meeting = MeetingRecord(title: "Budżet Q4", status: status, duration: 200)
        meeting.questions = questions
        try await database.createMeeting(meeting)
        try await database.appendSegment(MeetingSegmentRecord(
            meetingID: meeting.id, track: .them, start: 105, end: 117,
            text: "Proponuję test na dwóch grupach odbiorców, dwa tygodnie, maksymalnie pięć tysięcy."
        ))
        return Fixture(database: database, meetingID: meeting.id)
    }

    private static func asker(
        _ fixture: Fixture,
        key: String? = "sk-or-test",
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (MeetingAsker, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let client = OpenRouterClient(baseURL: baseURL)
        let asker = MeetingAsker(
            database: fixture.database,
            session: StubURLProtocol.makeSession(),
            route: { key.map { AIRoute(client: client, key: $0, model: Self.model) } }
        )
        return (asker, baseURL)
    }

    @Test func storesTheAnswerAndModelNewestLast() async throws {
        let earlier = MeetingQuestion(question: "Co ustaliliśmy?", answer: "- Test LinkedIn [1:45]")
        let fixture = try await Self.fixture(questions: [earlier])
        let seen = OSAllocatedUnfairLock(initialState: Data())
        let (asker, baseURL) = Self.asker(fixture) { request in
            let data = Self.rawBody(of: request)
            seen.withLock { $0 = data }
            return .json(Self.chat(Self.answer))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let asked = try #require(await asker.ask(meetingID: fixture.meetingID, question: "  Jaki budżet na test?\n"))
        #expect(asked.question == "Jaki budżet na test?")
        #expect(asked.answer == Self.answer)
        #expect(asked.model == Self.model)
        #expect(asked.error == nil)

        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.questions.map(\.question) == ["Co ustaliliśmy?", "Jaki budżet na test?"])
        #expect(meeting.questions.last == asked)

        let body = Self.json(seen.withLock { $0 })
        #expect(body["model"] as? String == Self.model)
        #expect(body["max_tokens"] as? Int == MeetingAsker.maxTokens)
        #expect(MeetingAsker.maxTokens == 1_500)
        let messages = Self.messages(body)
        #expect(messages.first == MeetingAskPrompt.system)
        #expect(messages.last?.contains("[1:45] Rozmówcy: Proponuję test") == true)
        #expect(messages.last?.contains("Pytanie: Co ustaliliśmy?") == true)
        #expect(messages.last?.hasSuffix("<question>\nJaki budżet na test?\n</question>") == true)
    }

    @Test func aMissingKeyIsStoredWithoutACall() async throws {
        let fixture = try await Self.fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (asker, baseURL) = Self.asker(fixture, key: nil) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.answer))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let asked = try #require(await asker.ask(meetingID: fixture.meetingID, question: "Co ustaliliśmy?"))
        #expect(asked.answer == nil)
        #expect(asked.error == MeetingSummaryError.noKey.errorDescription)
        #expect(asked.model == nil)
        #expect(calls.withLock { $0 } == 0)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.questions == [asked])
    }

    @Test func aRejectedKeyIsStoredAsThePolishError() async throws {
        let fixture = try await Self.fixture()
        let (asker, baseURL) = Self.asker(fixture) { _ in .json("{}", status: 401) }
        defer { StubURLProtocol.unregister(baseURL) }
        let asked = try #require(await asker.ask(meetingID: fixture.meetingID, question: "Co ustaliliśmy?"))
        #expect(asked.answer == nil)
        #expect(asked.error == OpenRouterError.unauthorized.errorDescription)
        #expect(try await fixture.database.meeting(id: fixture.meetingID)?.questions.first?.error == asked.error)
    }

    @Test func keepsTheNewestFiftyQuestions() async throws {
        let old = (1...MeetingAsker.maxStoredQuestions).map { MeetingQuestion(question: "Pytanie \($0)", answer: "Odpowiedź \($0)") }
        let fixture = try await Self.fixture(questions: old)
        let (asker, baseURL) = Self.asker(fixture) { _ in .json(Self.chat(Self.answer)) }
        defer { StubURLProtocol.unregister(baseURL) }
        _ = await asker.ask(meetingID: fixture.meetingID, question: "Nowe pytanie")
        let questions = try #require(try await fixture.database.meeting(id: fixture.meetingID)?.questions)
        #expect(MeetingAsker.maxStoredQuestions == 50)
        #expect(questions.count == 50)
        #expect(questions.first?.question == "Pytanie 2")
        #expect(questions.last?.question == "Nowe pytanie")
    }

    @Test func blankQuestionsAndMissingMeetingsAskNothing() async throws {
        let fixture = try await Self.fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (asker, baseURL) = Self.asker(fixture) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.answer))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await asker.ask(meetingID: fixture.meetingID, question: " \n ") == nil)
        #expect(await asker.ask(meetingID: UUID(), question: "Co?") == nil)
        #expect(calls.withLock { $0 } == 0)
        #expect(try await fixture.database.meeting(id: fixture.meetingID)?.questions.isEmpty == true)
    }

    @Test func aMeetingStillRecordingOrWithoutWordsIsNotSent() async throws {
        let recording = try await Self.fixture(status: .recording)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (asker, baseURL) = Self.asker(recording) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.answer))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let asked = try #require(await asker.ask(meetingID: recording.meetingID, question: "Co?"))
        #expect(asked.error == MeetingAsker.recordingMessage)

        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let empty = MeetingRecord(title: "Pusto", status: .completed)
        try await database.createMeeting(empty)
        let (emptyAsker, emptyURL) = Self.asker(Fixture(database: database, meetingID: empty.id)) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.answer))
        }
        defer { StubURLProtocol.unregister(emptyURL) }
        let none = try #require(await emptyAsker.ask(meetingID: empty.id, question: "Co?"))
        #expect(none.error == MeetingAsker.nothingToAskMessage)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func longQuestionsAreCut() async throws {
        let fixture = try await Self.fixture()
        let (asker, baseURL) = Self.asker(fixture) { _ in .json(Self.chat(Self.answer)) }
        defer { StubURLProtocol.unregister(baseURL) }
        let long = String(repeating: "a", count: MeetingAsker.maxQuestionLength + 50)
        let asked = try #require(await asker.ask(meetingID: fixture.meetingID, question: long))
        #expect(asked.question.count == MeetingAsker.maxQuestionLength)
    }

    // MARK: Runs

    @MainActor
    @Test func aRunShowsItsQuestionUntilItIsAnswered() async throws {
        let gate = AskGate()
        let runs = MeetingAskRuns { id, question in
            await gate.pass(id, question)
        }
        let id = UUID()
        #expect(runs.ask(meetingID: id, question: "   ") == nil)
        let task = try #require(runs.ask(meetingID: id, question: " Co ustaliliśmy? "))
        #expect(runs.isAsking(id))
        #expect(runs.pendingQuestion(id) == "Co ustaliliśmy?")
        #expect(!runs.isAsking(UUID()))
        // One question at a time per meeting.
        #expect(runs.ask(meetingID: id, question: "Drugie") == nil)

        await gate.open()
        await task.value
        #expect(!runs.isAsking(id))
        #expect(runs.pendingQuestion(id) == nil)
        #expect(runs.finishedCount == 1)
        #expect(await gate.questions == ["Co ustaliliśmy?"])
    }
}

/// Holds every ask until `open()`, and records the questions.
private actor AskGate {
    private(set) var questions: [String] = []
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass(_ id: UUID, _ question: String) async {
        questions.append(question)
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}
