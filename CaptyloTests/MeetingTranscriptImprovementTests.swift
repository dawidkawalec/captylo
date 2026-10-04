import AVFoundation
import Foundation
import os
import Testing
@testable import Captylo

/// After a meeting: the cloud transcript that replaces the live one and the AI fixes of the
/// transcript, from the pure pieces to the processors over an in-memory store.
struct MeetingTranscriptImprovementTests {
    // MARK: Helpers

    private static func word(_ text: String, _ start: Double, _ end: Double) -> ElevenLabsSTT.Word {
        ElevenLabsSTT.Word(text: text, start: start, end: end)
    }

    private static func database() throws -> Database {
        Database(modelContainer: try Store.makeInMemoryContainer())
    }

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A real 16 kHz track file of `seconds` (a quiet tone, so it is not all zeros).
    private static func writeTrack(_ url: URL, seconds: Double) throws {
        let writer = try TrackFileWriter(url: url)
        let count = Int(seconds * 16_000)
        writer.append((0..<count).map { Float(sin(Double($0) / 9)) * 0.2 })
        writer.close()
    }

    private static func body(of request: URLRequest) -> Data {
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

    /// The user message of a chat request.
    private static func userMessage(of request: URLRequest) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body(of: request))) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.last?["content"] as? String ?? ""
    }

    private static func chat(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"choices":[{"message":{"content":"\#(escaped)"},"finish_reason":"stop"}]}"#
    }

    // MARK: Cloud segments

    @Test func cloudWordsBreakAtPausesAndKeepTheirTimes() {
        let id = UUID()
        let words = [
            Self.word("Dzień", 0.5, 0.8), Self.word("dobry.", 0.85, 1.2),
            Self.word("Zaczynamy?", 3.0, 3.6),
        ]
        let segments = CloudTranscriptSegments.build(words, meetingID: id, track: .them)
        #expect(segments.map(\.text) == ["Dzień dobry.", "Zaczynamy?"])
        #expect(segments.map(\.start) == [0.5, 3.0])
        #expect(segments.map(\.end) == [1.2, 3.6])
        #expect(segments.allSatisfy { $0.track == .them && $0.meetingID == id })
        #expect(segments[0].words == [MeetingWord(text: "Dzień", start: 0.5, end: 0.8), MeetingWord(text: "dobry.", start: 0.85, end: 1.2)])
    }

    @Test func longSpeechEndsAtASentenceAfterTheSoftLimitAndAlwaysAtTheHardOne() {
        // One word every 0.5 s without a pause: a sentence ends at 15 s, none after it.
        var words: [ElevenLabsSTT.Word] = []
        for index in 0..<80 {
            let start = Double(index) * 0.5
            let text = index == 30 ? "koniec." : "słowo"
            words.append(Self.word(text, start, start + 0.4))
        }
        let segments = CloudTranscriptSegments.build(words, meetingID: UUID(), track: .me)
        #expect(segments[0].text.hasSuffix("koniec."))
        #expect(segments.allSatisfy { $0.end - $0.start <= CloudTranscriptSegments.hardLimit })
        #expect(segments.flatMap(\.words).count == 80)
    }

    @Test func scribeWordsKeepOnlyWordsWithTimes() throws {
        let json = #"""
        {"text":"Dzień dobry","words":[
          {"text":"Dzień","start":0.1,"end":0.4,"type":"word"},
          {"text":" ","start":0.4,"end":0.5,"type":"spacing"},
          {"text":"(śmiech)","start":0.5,"end":0.9,"type":"audio_event"},
          {"text":"dobry","start":0.9,"end":1.3,"type":"word"},
          {"text":"bez czasu","type":"word"}
        ]}
        """#
        let words = try ElevenLabsSTT.parseWords(Data(json.utf8))
        #expect(words == [Self.word("Dzień", 0.1, 0.4), Self.word("dobry", 0.9, 1.3)])
        #expect(try ElevenLabsSTT.parseWords(Data(#"{"text":""}"#.utf8)).isEmpty)
    }

    @Test func meetingUploadsAskForWordTimesInTheirOwnFormat() {
        let request = STTRequest(wav: Data([1, 2, 3]), fileName: "them.m4a", model: "scribe_v2", audioSeconds: 60)
        let (_, meeting) = ElevenLabsSTT.makeUpload(request, credential: .ownKey("k"), options: .init(mimeType: "audio/mp4", timestamps: "word"))
        let text = String(decoding: meeting, as: UTF8.self)
        #expect(text.contains("Content-Type: audio/mp4"))
        #expect(text.contains("name=\"timestamps_granularity\"\r\n\r\nword"))
        let (_, dictation) = ElevenLabsSTT.makeUpload(request, credential: .ownKey("k"))
        let dictationText = String(decoding: dictation, as: UTF8.self)
        #expect(dictationText.contains("Content-Type: audio/wav"))
        #expect(dictationText.contains("name=\"timestamps_granularity\"\r\n\r\nnone"))
    }

    @Test func tracksAreEncodedForUploadWithTheirLength() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "me.caf")
        try Self.writeTrack(source, seconds: 3)
        let encoded = try TrackUploadEncoder.encode(source, into: folder.appending(path: "out"))
        #expect(abs(encoded.seconds - 3) < 0.01)
        #expect(["audio/mp4", "audio/wav"].contains(encoded.mimeType))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: encoded.url.path(percentEncoded: false))[.size] as? Int)
        #expect(size > 0)
        let reread = try AVAudioFile(forReading: encoded.url)
        #expect(reread.length > 0)
    }

    // MARK: Cloud processor

    private struct CloudFixture {
        let database: Database
        let meetingID: UUID
        let folder: URL

        func url(_ track: MeetingTrack) -> URL { folder.appending(path: track.fileName) }
    }

    /// Live lines on both tracks, track files of 4 s each.
    private static func cloudFixture() async throws -> CloudFixture {
        let database = try database()
        let meeting = MeetingRecord(title: "Oferta")
        try await database.createMeeting(meeting)
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0.2, end: 1.5, text: "dam znaciannie"))
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 2, end: 3.5, text: "wyśle oferte jutro"))
        let folder = Self.folder()
        for track in MeetingTrack.allCases {
            try writeTrack(folder.appending(path: track.fileName), seconds: 4)
        }
        return CloudFixture(database: database, meetingID: meeting.id, folder: folder)
    }

    private static func cloud(_ fixture: CloudFixture, transcribe: @escaping MeetingCloudTranscription.Transcribe) -> MeetingCloudTranscription {
        MeetingCloudTranscription(
            database: fixture.database,
            isEnabled: { true },
            trackURL: { _, track in fixture.url(track) },
            language: { "pl" },
            vocabulary: { ["Anna"] },
            transcribe: transcribe,
            workFolder: fixture.folder.appending(path: "upload")
        )
    }

    @Test func theCloudTranscriptReplacesBothTracksAndMarksEcho() async throws {
        let fixture = try await Self.cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let requests = OSAllocatedUnfairLock<[STTRequest]>(initialState: [])
        let processor = Self.cloud(fixture) { request, mimeType in
            requests.withLock { $0.append(request) }
            #expect(["audio/mp4", "audio/wav"].contains(mimeType))
            if request.fileName.hasPrefix("me") {
                // Without headphones: the mic also heard the other side.
                return [Self.word("Dam", 0.2, 0.5), Self.word("znać", 0.5, 0.8), Self.word("Annie.", 0.8, 1.4),
                        Self.word("Wyślę", 2.5, 2.9), Self.word("ofertę", 2.9, 3.2), Self.word("jutro.", 3.2, 3.6)]
            }
            return [Self.word("Wyślę", 2, 2.4), Self.word("ofertę", 2.4, 2.8), Self.word("jutro.", 2.8, 3.3)]
        }
        #expect(await processor.run(meetingID: fixture.meetingID))

        let sent = requests.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.language == "pl" && $0.vocabulary == ["Anna"] && $0.model == "scribe_v2" })
        let segments = try await fixture.database.segments(meetingID: fixture.meetingID)
        #expect(segments.filter { !$0.isEcho }.map(\.text) == ["Dam znać Annie.", "Wyślę ofertę jutro."])
        #expect(segments.contains { $0.track == .me && $0.isEcho && $0.text == "Wyślę ofertę jutro." })
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.transcriptModel == "scribe_v2")
        #expect(meeting.transcriptError == nil)
        #expect(try await fixture.database.meetings(query: "znać Annie", limit: 5).map(\.id) == [fixture.meetingID])
        // The encoded uploads are gone.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: fixture.folder.appending(path: "upload").path(percentEncoded: false))) ?? []
        #expect(left.isEmpty)
    }

    @Test func aFailedOrEmptyCloudTrackKeepsTheLiveLines() async throws {
        let fixture = try await Self.cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let processor = Self.cloud(fixture) { request, _ in
            if request.fileName.hasPrefix("me") { throw STTError.unauthorized }
            return []
        }
        #expect(await processor.run(meetingID: fixture.meetingID) == false)
        let segments = try await fixture.database.segments(meetingID: fixture.meetingID)
        #expect(segments.map(\.text) == ["dam znaciannie", "wyśle oferte jutro"])
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.transcriptModel == nil)
        #expect(meeting.transcriptError?.contains(STTError.unauthorized.localizedDescription) == true)
    }

    @Test func theCloudPassIsSkippedWhenOffOrWithoutAudio() async throws {
        let fixture = try await Self.cloudFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var processor = Self.cloud(fixture) { _, _ in
            calls.withLock { $0 += 1 }
            return []
        }
        processor = MeetingCloudTranscription(
            database: processor.database, isEnabled: { false }, trackURL: processor.trackURL,
            language: processor.language, vocabulary: processor.vocabulary, transcribe: processor.transcribe
        )
        await processor.process(meetingID: fixture.meetingID)
        try await fixture.database.setMeetingAudioRemoved(ids: [fixture.meetingID])
        #expect(await processor.run(meetingID: fixture.meetingID) == false)
        #expect(calls.withLock { $0 } == 0)
    }

    // MARK: Correction prompt

    @Test func correctionBatchesSkipEchoAndRespectTheLimits() {
        let id = UUID()
        var segments = (0..<170).map { index in
            MeetingSegmentRecord(meetingID: id, track: .me, start: Double(index), end: Double(index) + 0.5, text: "linia \(index)")
        }
        segments.append(MeetingSegmentRecord(meetingID: id, track: .me, start: 500, end: 501, text: "echo", isEcho: true))
        segments.append(MeetingSegmentRecord(meetingID: id, track: .me, start: 502, end: 503, text: "   "))
        let batches = MeetingCorrectionPrompt.batches(segments.shuffled())
        #expect(batches.map(\.count) == [80, 80, 10])
        #expect(batches.flatMap { $0 }.map(\.start) == (0..<170).map(Double.init))

        let long = (0..<5).map { index in
            MeetingSegmentRecord(meetingID: id, track: .them, start: Double(index), end: Double(index) + 1, text: String(repeating: "a", count: 3_000))
        }
        #expect(MeetingCorrectionPrompt.batches(long).map(\.count) == [2, 2, 1])
    }

    @Test func correctionPromptNumbersTheLinesWithTheGlossary() {
        let id = UUID()
        let batch = [
            MeetingSegmentRecord(meetingID: id, track: .me, start: 0, end: 1, text: "dam znaciannie"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 2, end: 3, text: "dwie\nlinie"),
        ]
        let user = MeetingCorrectionPrompt.user(title: "Oferta", glossary: ["Anna", " ", "Captylo"], batch: batch)
        #expect(user.contains("Tytuł spotkania: Oferta"))
        #expect(user.contains("Słownik (pisownia nazw i terminów): Anna, Captylo"))
        #expect(user.hasSuffix("Transkrypt:\n1|dam znaciannie\n2|dwie linie"))
        #expect(!MeetingCorrectionPrompt.user(title: "X", glossary: [], batch: batch).contains("Słownik"))
    }

    @Test func correctionAnswersAreParsedLineByLine() {
        let reply = "```\n1|Dam znać Annie.\n 2 | Wyślę ofertę jutro. \nkomentarz modelu\n2|druga wersja\n3|\nx|nie liczba\n```"
        #expect(MeetingCorrectionPrompt.parse(reply) == [1: "Dam znać Annie.", 2: "Wyślę ofertę jutro."])
    }

    @Test func aFixThatShortensOrAddsTooMuchIsRefused() {
        #expect(MeetingCorrectionPrompt.accepts("Dam znać Annie.", for: "dam znaciannie"))
        #expect(MeetingCorrectionPrompt.accepts("Wyślę ofertę jutro rano.", for: "wyśle oferte jutro rano"))
        // A summary of a long line.
        let long = "no to słuchajcie ja bym proponował żebyśmy wdrożenie przesunęli na piątek bo testy jeszcze trwają i nie zdążymy"
        #expect(!MeetingCorrectionPrompt.accepts("Wdrożenie w piątek.", for: long))
        // An added sentence.
        #expect(!MeetingCorrectionPrompt.accepts("Tak. Zgadzam się w pełni z tym, co powiedziała Anna, i dodam jeszcze jedno.", for: "tak"))
        #expect(!MeetingCorrectionPrompt.accepts("", for: "tak"))
    }

    @Test func fixedLinesKeepTheirFirstTextAndGetWordTimes() {
        let id = UUID()
        let same = MeetingSegmentRecord(
            meetingID: id, track: .me, start: 1, end: 2, text: "wyśle oferte",
            words: [MeetingWord(text: "wyśle", start: 1, end: 1.4), MeetingWord(text: "oferte", start: 1.5, end: 2)]
        )
        var fixedBefore = MeetingSegmentRecord(meetingID: id, track: .them, start: 3, end: 5, text: "dam znać annie",
                                               words: [MeetingWord(text: "dam", start: 3, end: 3.5), MeetingWord(text: "znaciannie", start: 3.6, end: 5)])
        fixedBefore.originalText = "dam znaciannie"
        let untouched = MeetingSegmentRecord(meetingID: id, track: .me, start: 6, end: 7, text: "Tak.")
        let changes = MeetingCorrectionPrompt.changes(
            in: [same, fixedBefore, untouched],
            reply: "1|Wyślę ofertę\n2|Dam znać Annie.\n3|Tak."
        )
        #expect(changes.map(\.id) == [same.id, fixedBefore.id])
        #expect(changes[0].text == "Wyślę ofertę")
        #expect(changes[0].originalText == "wyśle oferte")
        #expect(changes[0].words == [MeetingWord(text: "Wyślę", start: 1, end: 1.4), MeetingWord(text: "ofertę", start: 1.5, end: 2)])
        // A second fix keeps the text from before the first one.
        #expect(changes[1].originalText == "dam znaciannie")
        #expect(changes[1].words.map(\.text) == ["Dam", "znać", "Annie."])
        #expect(changes[1].words.first?.start == 3)
        #expect(abs((changes[1].words.last?.end ?? 0) - 5) < 0.0001)
    }

    // MARK: Correction processor

    private static func correctionFixture() async throws -> (Database, UUID) {
        let database = try database()
        var meeting = MeetingRecord(title: "Oferta", speakerNames: ["1": "Anna"])
        meeting.participants = ["Piotr Nowak", "Anna"]
        try await database.createMeeting(meeting)
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 1.5, text: "dam znaciannie"))
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 2, end: 3.5, text: "wyśle oferte jutro", speaker: "1"))
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 2.1, end: 3.4, text: "wyśle oferte jutro", isEcho: true))
        return (database, meeting.id)
    }

    /// The Pro relay with `key` as the session; nil = no Pro session.
    private static func corrector(_ handler: @escaping StubURLProtocol.Handler, key: String? = "session-token") -> MeetingTranscriptCorrector {
        let client = OpenRouterClient(baseURL: StubURLProtocol.register(handler))
        return MeetingTranscriptCorrector(
            session: StubURLProtocol.makeSession(),
            route: { key.map { AIRoute(client: client, key: $0, model: nil) } }
        )
    }

    @Test func theAIFixIsStoredAndCanBeRestored() async throws {
        let (database, id) = try await Self.correctionFixture()
        let seen = OSAllocatedUnfairLock(initialState: "")
        let corrector = Self.corrector { request in
            let user = Self.userMessage(of: request)
            seen.withLock { $0 = user }
            return .json(Self.chat("1|Dam znać Annie.\n2|Wyślę ofertę jutro."))
        }
        let processor = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { true }, vocabulary: { ["Captylo"] })
        #expect(await processor.run(meetingID: id))

        let prompt = seen.withLock { $0 }
        // Dictionary, then the names typed on the meeting, then the calendar's participants, once each.
        #expect(prompt.contains("Słownik (pisownia nazw i terminów): Captylo, Anna, Piotr Nowak\n"))
        #expect(!prompt.contains("3|"))
        let segments = try await database.segments(meetingID: id)
        #expect(segments.filter { !$0.isEcho }.map(\.text) == ["Dam znać Annie.", "Wyślę ofertę jutro."])
        #expect(segments.filter { !$0.isEcho }.map(\.originalText) == ["dam znaciannie", "wyśle oferte jutro"])
        #expect(segments.first { $0.isEcho }?.text == "wyśle oferte jutro")
        #expect(try await database.meeting(id: id)?.transcriptAIModel == Enhancer.relayModelPlaceholder)
        #expect(try await database.meetings(query: "ofertę", limit: 5).map(\.id) == [id])

        #expect(try await database.restoreOriginalTranscript(meetingID: id) == 2)
        let restored = try await database.segments(meetingID: id)
        #expect(restored.filter { !$0.isEcho }.map(\.text) == ["dam znaciannie", "wyśle oferte jutro"])
        #expect(restored.allSatisfy { $0.originalText == nil })
        #expect(try await database.meeting(id: id)?.transcriptAIModel == nil)
    }

    @Test func aFailedAIFixKeepsTheTextAndSaysWhy() async throws {
        let (database, id) = try await Self.correctionFixture()
        let processor = MeetingCorrectionProcessor(
            database: database,
            corrector: Self.corrector { _ in .json("{}", status: 401) },
            isEnabled: { true },
            vocabulary: { [] }
        )
        #expect(await processor.run(meetingID: id) == false)
        #expect(try await database.segments(meetingID: id).map(\.text).contains("dam znaciannie"))
        let error = try #require(try await database.meeting(id: id)?.transcriptError)
        #expect(error.hasPrefix(MeetingCorrectionProcessor.errorPrefix))

        let noKey = MeetingCorrectionProcessor(
            database: database,
            corrector: Self.corrector({ _ in .json(Self.chat("1|x")) }, key: nil),
            isEnabled: { true },
            vocabulary: { [] }
        )
        #expect(await noKey.run(meetingID: id) == false)
        #expect(try await database.meeting(id: id)?.transcriptError == MeetingCorrectionProcessor.errorPrefix + (MeetingSummaryError.noKey.errorDescription ?? ""))
    }

    @Test func theAIFixAfterAMeetingFollowsItsSwitch() async throws {
        let (database, id) = try await Self.correctionFixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let corrector = Self.corrector { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat("1|Dam znać Annie."))
        }
        let off = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { false }, vocabulary: { [] })
        await off.process(meetingID: id)
        #expect(calls.withLock { $0 } == 0)
        let on = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { true }, vocabulary: { [] })
        await on.process(meetingID: id)
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: Runs

    @MainActor
    @Test func transcriptRunsAllowOneRunPerMeeting() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let runs = MeetingTranscriptRuns { _, _ in
            for await _ in gate.stream { break }
        }
        let id = UUID()
        let task = try #require(runs.start(.aiFix, meetingID: id))
        #expect(runs.kind(id) == .aiFix)
        #expect(runs.start(.cloud, meetingID: id) == nil)
        gate.continuation.yield()
        await task.value
        #expect(runs.kind(id) == nil)
        #expect(runs.finishedCount == 1)
    }
}
