import Foundation
import os
import Testing
@testable import Captylo

/// "Zapytaj wszystkie spotkania": the question's terms, which meetings and lines go to the AI,
/// the prompt, the `[S1 12:34]` citations, `LibraryAsker` over the stubbed network and the
/// session list in `MeetingAskRuns`.
struct LibraryAskTests {
    private static let model = "openai/gpt-4.1-mini"

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

    private static func messages(_ data: Data) -> [String] {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
    }

    private static func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    // MARK: Terms

    @Test func stopwordsLeaveOnlyTheTopicWords() {
        #expect(LibraryAskRetrieval.terms("Kiedy wyślemy ofertę dla klienta?") == ["wyslem", "ofert", "klient"])
        #expect(LibraryAskRetrieval.terms("Co mówiła Anna o budżecie, który był ustalony?") == ["anna", "budzec", "ustalo"])
        #expect(LibraryAskRetrieval.terms("What did we decide about the budget?") == ["decid", "budge"])
        #expect(LibraryAskRetrieval.terms("Co to jest? Jak było?") == nil)
        #expect(LibraryAskRetrieval.terms("  ") == nil)
        #expect(LibraryAskRetrieval.stopwords.contains("ze"))
        #expect(LibraryAskRetrieval.stopwords.contains("ktora"))
    }

    // MARK: Selection

    private static func hit(_ meeting: UUID, _ rank: Double, kind: SearchHit.Kind = .segment) -> SearchHit {
        SearchHit(meetingID: meeting, segmentID: kind == .segment ? UUID() : nil, kind: kind, start: 0, track: kind == .segment ? .them : nil, rank: rank)
    }

    @Test func keepsTheEightMeetingsWithTheBestSumAndNewerOnTies() {
        let ids = (0..<10).map { _ in UUID() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var dates: [UUID: Date] = [:]
        for (offset, id) in ids.enumerated() {
            dates[id] = base.addingTimeInterval(Double(offset) * 3600)
        }
        var hits: [SearchHit] = []
        // Meeting 0: one strong hit (-5). Meeting 1: three weaker ones (-6 together).
        hits.append(Self.hit(ids[0], -5))
        hits += [Self.hit(ids[1], -2), Self.hit(ids[1], -2), Self.hit(ids[1], -2, kind: .title)]
        // Meetings 2...9: -1 each, a tie broken by the newer meeting.
        for id in ids[2...] {
            hits.append(Self.hit(id, -1))
        }
        // A hit of a meeting the store no longer has is ignored.
        hits.append(Self.hit(UUID(), -100))

        let picked = LibraryAskRetrieval.pickMeetings(hits, dates: dates, limit: 8)
        #expect(picked.count == 8)
        #expect(Array(picked.prefix(2)) == [ids[1], ids[0]])
        #expect(Array(picked.dropFirst(2)) == [ids[9], ids[8], ids[7], ids[6], ids[5], ids[4]])
        #expect(LibraryAskRetrieval.maxMeetings == 8)
    }

    @Test func excerptsTakeOneNeighborEachSideAndMergeAdjacentRuns() {
        let meeting = UUID()
        var segments = (0..<10).map {
            MeetingSegmentRecord(meetingID: meeting, track: .them, start: Double($0) * 10, end: Double($0) * 10 + 8, text: "linia \($0)")
        }
        // An echo line never counts as a neighbor.
        segments.insert(MeetingSegmentRecord(meetingID: meeting, track: .me, start: 71, end: 72, text: "echo", isEcho: true), at: 8)
        let byText = Dictionary(uniqueKeysWithValues: segments.map { ($0.text, $0.id) })

        let hits: Set<UUID> = [byText["linia 2"]!, byText["linia 4"]!, byText["linia 8"]!, byText["linia 0"]!]
        let runs = LibraryAskRetrieval.excerpts(hitSegmentIDs: hits, in: segments.shuffled())
        #expect(runs.map { $0.map(\.text) } == [
            ["linia 0", "linia 1", "linia 2", "linia 3", "linia 4", "linia 5"],
            ["linia 7", "linia 8", "linia 9"],
        ])
        #expect(LibraryAskRetrieval.excerpts(hitSegmentIDs: [], in: segments).isEmpty)
    }

    // MARK: Context over the index

    private struct Fixture {
        let database: Database
        let index: MeetingSearchIndex
    }

    private static func fixture() throws -> Fixture {
        let index = MeetingSearchIndex(url: nil)
        return Fixture(database: Database(modelContainer: try Store.makeInMemoryContainer(), searchIndex: index), index: index)
    }

    @discardableResult
    private static func addMeeting(
        _ fixture: Fixture, title: String, at createdAt: Date, lines: [String], summary: String? = nil, notes: String = ""
    ) async throws -> MeetingRecord {
        var meeting = MeetingRecord(createdAt: createdAt, title: title, status: .completed, duration: Double(lines.count) * 10)
        meeting.summary = summary
        meeting.notes = notes
        try await fixture.database.createMeeting(meeting)
        for (offset, line) in lines.enumerated() {
            try await fixture.database.appendSegment(MeetingSegmentRecord(
                meetingID: meeting.id, track: offset.isMultiple(of: 2) ? .me : .them,
                start: Double(offset) * 10, end: Double(offset) * 10 + 8, text: line
            ))
        }
        return meeting
    }

    private static func asker(
        _ fixture: Fixture,
        index: MeetingSearchIndex? = nil,
        key: String? = "sk-or-test",
        now: Date = Date(timeIntervalSince1970: 1_790_000_000),
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (LibraryAsker, URL) {
        let baseURL = StubURLProtocol.register(handler)
        let asker = LibraryAsker(
            database: fixture.database,
            index: index ?? fixture.index,
            client: OpenRouterClient(baseURL: baseURL),
            session: StubURLProtocol.makeSession(),
            key: { key },
            model: { Self.model },
            now: { now }
        )
        return (asker, baseURL)
    }

    @Test func contextPicksEightMeetingsAndTwelveHitLinesWithNeighbors() async throws {
        let fixture = try Self.fixture()
        let base = try Self.date("2026-09-01T09:00:00Z")
        // One meeting says "oferta" twenty times between other lines.
        var busy: [String] = []
        for number in 0..<20 {
            busy.append("Rozmowa o pogodzie numer \(number).")
            busy.append("Wyślę ofertę numer \(number) jutro.")
        }
        let busyMeeting = try await Self.addMeeting(fixture, title: "Długie spotkanie", at: base, lines: busy)
        for number in 0..<9 {
            try await Self.addMeeting(
                fixture, title: "Spotkanie \(number)", at: base.addingTimeInterval(Double(number + 1) * 86_400),
                lines: ["Dzień dobry.", "Oferta będzie w piątek.", "Do widzenia."]
            )
        }
        try await Self.addMeeting(fixture, title: "Bez związku", at: base, lines: ["Zupełnie inny temat."])
        let (asker, baseURL) = Self.asker(fixture) { _ in .json(Self.chat("x")) }
        defer { StubURLProtocol.unregister(baseURL) }

        let context = try await asker.context(question: "Kiedy wyślemy ofertę?")
        #expect(!context.notesOnly)
        #expect(context.sources.count == 8)
        #expect(!context.sources.contains { $0.meeting.title == "Bez związku" })
        let busySource = try #require(context.sources.first { $0.meeting.id == busyMeeting.id })
        let busyLines = busySource.excerpts.flatMap { $0 }
        let hitLines = busyLines.filter { $0.text.contains("ofert") }
        #expect(hitLines.count == LibraryAskRetrieval.segmentsPerMeeting)
        #expect(LibraryAskRetrieval.segmentsPerMeeting == 12)
        // Every hit line comes with the line before and after it; neighbors shared by two hits
        // merge the runs.
        #expect(busyLines.count <= 3 * 12)
        #expect(busyLines.count > hitLines.count)
        for run in busySource.excerpts {
            #expect(run == run.sorted { $0.start < $1.start })
        }
        let small = try #require(context.sources.first { $0.meeting.title == "Spotkanie 8" })
        #expect(small.excerpts.map { $0.map(\.text) } == [["Dzień dobry.", "Oferta będzie w piątek.", "Do widzenia."]])
    }

    @Test func notesHitsBringTheUserNotesAlong() async throws {
        let fixture = try Self.fixture()
        try await Self.addMeeting(fixture, title: "Planowanie", at: Date(), lines: ["Dzień dobry."], notes: "harmonogram wdrożenia do piątku")
        let (asker, baseURL) = Self.asker(fixture) { _ in .json(Self.chat("x")) }
        defer { StubURLProtocol.unregister(baseURL) }
        let context = try await asker.context(question: "Jaki jest harmonogram?")
        let source = try #require(context.sources.first)
        #expect(source.includesUserNotes)
        #expect(source.excerpts.isEmpty)
    }

    @Test func noHitAnswersWithoutCallingTheAI() async throws {
        let fixture = try Self.fixture()
        try await Self.addMeeting(fixture, title: "Budżet", at: Date(), lines: ["Mamy dwadzieścia tysięcy na reklamy."])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (asker, baseURL) = Self.asker(fixture) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat("x"))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let answer = try #require(await asker.ask(question: "Jaki kolor ma samochód prezesa?"))
        #expect(answer.answer == LibraryAsker.noHitsAnswer)
        #expect(answer.sources.isEmpty)
        #expect(answer.model == nil)
        #expect(answer.error == nil)
        #expect(!answer.notesOnly)
        // Only stopwords: nothing to look for either.
        let empty = try #require(await asker.ask(question: "Co to jest?"))
        #expect(empty.answer == LibraryAsker.noHitsAnswer)
        #expect(calls.withLock { $0 } == 0)
        #expect(await asker.ask(question: "   ") == nil)
    }

    @Test func anIndexStillBuildingFallsBackToTheNewestAINotes() async throws {
        let fixture = try Self.fixture()
        let base = try Self.date("2026-09-01T09:00:00Z")
        try await Self.addMeeting(fixture, title: "Bez notatek AI", at: base.addingTimeInterval(86_400 * 20), lines: ["Cześć."])
        for number in 0..<10 {
            try await Self.addMeeting(
                fixture, title: "Spotkanie \(number)", at: base.addingTimeInterval(Double(number) * 86_400),
                lines: ["Dzień dobry."], summary: "## Podsumowanie\n- Notatki spotkania \(number) [0:10]"
            )
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "LibraryAsk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file index nobody prepared yet is not ready.
        let building = MeetingSearchIndex(url: directory.appending(path: MeetingSearchIndex.fileName))
        #expect(!building.isReady)

        let seen = OSAllocatedUnfairLock(initialState: Data())
        let (asker, baseURL) = Self.asker(fixture, index: building) { request in
            let data = Self.rawBody(of: request)
            seen.withLock { $0 = data }
            return .json(Self.chat("- Notatki spotkania 9 [S1 0:10]"))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let answer = try #require(await asker.ask(question: "Co ustaliliśmy ostatnio?"))
        #expect(answer.notesOnly)
        #expect(answer.sources.map(\.title) == (2...9).reversed().map { "Spotkanie \($0)" })
        #expect(answer.answer == "- Notatki spotkania 9 [S1 0:10]")
        let user = try #require(Self.messages(seen.withLock { $0 }).last)
        #expect(user.contains("S1: Spotkanie 9"))
        #expect(user.contains("Notatki spotkania 9 [0:10]"))
        #expect(!user.contains("Bez notatek AI"))
        #expect(!user.contains("<excerpts>"))
    }

    // MARK: Prompt

    @Test func systemPromptGroundsTheAnswerInTheExcerpts() {
        let system = LibraryAskPrompt.system
        #expect(LibraryAskPrompt.notFound == "Nie znalazłem tego w spotkaniach.")
        #expect(system.contains(LibraryAskPrompt.notFound))
        #expect(system.contains(LibraryAskPrompt.notFoundEnglish))
        #expect(system.contains("[S1 12:34]"))
        #expect(system.contains("w języku pytania"))
        #expect(system.contains("Nie wymyślaj"))
        #expect(system.contains("ostatnio"))
        #expect(!system.contains("\u{2014}") && !system.contains("\u{2013}"))
    }

    @Test func userMessageNumbersTheMeetingsWithTheirDatesAndExcerpts() throws {
        let created = try Self.date("2026-10-02T12:00:00Z")
        var budget = MeetingRecord(createdAt: created, title: "Budżet Q4", status: .completed)
        budget.participants = ["Anna Kowalska", " ", "Piotr Nowak"]
        budget.speakerNames = ["1": "Anna"]
        budget.summary = String(repeating: "a", count: 700)
        budget.noteLines = [MeetingNoteLine(text: "budżet reklam", at: 65)]
        budget.notes = "budżet reklam"
        let first = [
            MeetingSegmentRecord(meetingID: budget.id, track: .me, start: 95, end: 104, text: "Ile na test?"),
            MeetingSegmentRecord(meetingID: budget.id, track: .them, start: 105, end: 117, text: "Pięć tysięcy.", speaker: "1"),
        ]
        let second = [MeetingSegmentRecord(meetingID: budget.id, track: .them, start: 3_725, end: 3_730, text: "Do zobaczenia.")]
        let standup = MeetingRecord(createdAt: created.addingTimeInterval(-86_400), title: "Standup", status: .completed)
        let context = LibraryAskContext(
            sources: [
                LibraryAskSource(meeting: budget, excerpts: [first, second], includesUserNotes: true),
                LibraryAskSource(meeting: standup, excerpts: [], includesUserNotes: false),
            ],
            notesOnly: false
        )
        let user = LibraryAskPrompt.user(context: context, question: "  Ile na test?  ", now: created.addingTimeInterval(3_600))
        #expect(user.hasPrefix("Dzisiaj: 2 października 2026"))
        #expect(user.contains("S1: Budżet Q4, 2 października 2026"))
        #expect(user.contains(", uczestnicy: Anna Kowalska, Piotr Nowak\n"))
        #expect(user.contains("<ai_notes>\n" + String(repeating: "a", count: LibraryAskRetrieval.notesPrefix) + "...\n</ai_notes>"))
        #expect(user.contains("<user_notes>\n[1:05] budżet reklam\n</user_notes>"))
        #expect(user.contains("<excerpts>\n[1:35] Ja: Ile na test?\n[1:45] Anna: Pięć tysięcy.\n...\n[1:02:05] Rozmówcy: Do zobaczenia.\n</excerpts>"))
        #expect(user.contains("S2: Standup, 1 października 2026"))
        #expect(!user.contains("S3:"))
        #expect(user.hasSuffix("<question>\nIle na test?\n</question>"))
        #expect(!user.contains("\u{2014}") && !user.contains("\u{2013}"))
    }

    // MARK: Citations

    @Test func citationsMapToTheNumberedMeetings() throws {
        let first = UUID()
        let second = UUID()
        let text = "Budżet 5 tys. [S1 1:45], wideo [S2 1:02:03]. Nieznane [S9 0:10], zwykłe [12:34], złe [S1 1:99], całe [S2], [s1 0:05], [S1, 2:00]"
        let citations = LibraryCitation.parse(text, meetings: [first, second])
        #expect(citations.map(\.meetingID) == [first, second, second, first])
        #expect(citations.map(\.seconds) == [105, 3_723, nil, 120])
        #expect(citations.map(\.number) == [1, 2, 2, 1])
        #expect(citations.map { String(text[$0.range]) } == ["[S1 1:45]", "[S2 1:02:03]", "[S2]", "[S1, 2:00]"])
        #expect(citations.map(\.label) == ["S1 1:45", "S2 1:02:03", "S2", "S1 2:00"])
        #expect(LibraryCitation.parse("[S1 1:45]", meetings: []).isEmpty)
    }

    /// A citation jumps to the line spoken at that second: the one spanning it, else the nearest.
    @Test func aCitedSecondFindsItsTranscriptLine() {
        let meeting = UUID()
        let me = MeetingSegmentRecord(meetingID: meeting, track: .me, start: 95.4, end: 104, text: "a")
        let them = MeetingSegmentRecord(meetingID: meeting, track: .them, start: 105.5, end: 117, text: "b")
        let echo = MeetingSegmentRecord(meetingID: meeting, track: .me, start: 105, end: 106, text: "c", isEcho: true)
        let segments = [me, them, echo]
        #expect(MeetingCitations.segment(at: 105, in: segments)?.id == them.id)
        #expect(MeetingCitations.segment(at: 95, in: segments)?.id == me.id)
        #expect(MeetingCitations.segment(at: 200, in: segments)?.id == them.id)
        #expect(MeetingCitations.segment(at: 10, in: []) == nil)
    }

    @Test func linesKeepTheTextAndPullTheCitationsOut() {
        let meeting = UUID()
        let lines = LibraryCitation.lines("Test LinkedIn [S1 1:45].\n\n- Budżet **5 tys.** [S1 1:45] [S1 2:00]\n* zwykłe [12:34] [S3 0:01]\n## Nagłówek", meetings: [meeting])
        #expect(lines.map(\.text) == ["Test LinkedIn.", "Budżet **5 tys.**", "zwykłe [12:34] [S3 0:01]", "Nagłówek"])
        #expect(lines.map(\.isBullet) == [false, true, true, false])
        #expect(lines.map { $0.citations.map(\.seconds) } == [[105], [105, 120], [], []])
    }

    // MARK: Asker

    @Test func asksWithTheExcerptsAndReturnsTheSources() async throws {
        let fixture = try Self.fixture()
        let created = try Self.date("2026-10-02T12:00:00Z")
        let budget = try await Self.addMeeting(
            fixture, title: "Budżet Q4", at: created,
            lines: ["Dzień dobry.", "Na test LinkedIn mamy pięć tysięcy.", "Dobrze."]
        )
        let seen = OSAllocatedUnfairLock(initialState: Data())
        let reply = "- Pięć tysięcy [S1 0:10]"
        let (asker, baseURL) = Self.asker(fixture, now: created.addingTimeInterval(7_200)) { request in
            let data = Self.rawBody(of: request)
            seen.withLock { $0 = data }
            return .json(Self.chat(reply))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let answer = try #require(await asker.ask(question: "Ile mamy na test LinkedIn?"))
        #expect(answer.question == "Ile mamy na test LinkedIn?")
        #expect(answer.answer == reply)
        #expect(answer.model == Self.model)
        #expect(answer.error == nil)
        #expect(answer.sources == [LibraryAnswer.Source(meetingID: budget.id, title: "Budżet Q4", createdAt: created)])
        #expect(answer.citations.map(\.meetingID) == [budget.id])

        let messages = Self.messages(seen.withLock { $0 })
        #expect(messages.first == LibraryAskPrompt.system)
        let user = try #require(messages.last)
        #expect(user.contains("S1: Budżet Q4"))
        #expect(user.contains("[0:10] Rozmówcy: Na test LinkedIn mamy pięć tysięcy."))
        // Nothing is stored on the meeting: the library answers live for the session only.
        let stored = try #require(try await fixture.database.meeting(id: budget.id))
        #expect(stored.questions.isEmpty)
    }

    @Test func aMissingOrRejectedKeyBecomesTheError() async throws {
        let fixture = try Self.fixture()
        try await Self.addMeeting(fixture, title: "Budżet", at: Date(), lines: ["Mamy dwadzieścia tysięcy na reklamy."])
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (noKey, firstURL) = Self.asker(fixture, key: nil) { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat("x"))
        }
        defer { StubURLProtocol.unregister(firstURL) }
        let missing = try #require(await noKey.ask(question: "Ile na reklamy?"))
        #expect(missing.answer == nil)
        #expect(missing.error == OpenRouterError.missingKeyMessage)
        #expect(missing.sources.count == 1)
        #expect(calls.withLock { $0 } == 0)

        let (rejected, secondURL) = Self.asker(fixture) { _ in .json("{}", status: 401) }
        defer { StubURLProtocol.unregister(secondURL) }
        let failed = try #require(await rejected.ask(question: "Ile na reklamy?"))
        #expect(failed.answer == nil)
        #expect(failed.error == OpenRouterError.unauthorized.errorDescription)
    }

    // MARK: Session

    @MainActor
    @Test func theSessionKeepsTheLastFiveAnswers() async throws {
        let runs = MeetingAskRuns(ask: { _, _ in }, askLibrary: { question in
            LibraryAnswer(question: question, answer: "Odpowiedź na " + question)
        })
        #expect(runs.askLibrary(question: "   ") == nil)
        for number in 1...6 {
            let task = try #require(runs.askLibrary(question: "Pytanie \(number)"))
            #expect(runs.libraryPending == "Pytanie \(number)")
            #expect(runs.askLibrary(question: "Drugie naraz") == nil)
            await task.value
            #expect(runs.libraryPending == nil)
        }
        #expect(runs.libraryAnswers.map(\.question) == (2...6).map { "Pytanie \($0)" })
        #expect(MeetingAskRuns.librarySessionLimit == 5)
    }
}
