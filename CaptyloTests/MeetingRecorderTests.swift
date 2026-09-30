import AVFoundation
import Foundation
import Testing
@testable import Captylo

@MainActor
struct MeetingRecorderTests {
    private func environment(mic: FakeAudioSource, system: FakeAudioSource, spy: MuteSpy, db: Database, expecting: Bool = false) -> MeetingEnvironment {
        let folder = FileManager.default.temporaryDirectory.appending(path: "meeting-tests-\(UUID().uuidString)")
        return MeetingEnvironment(
            makeMic: { mic },
            makeSystem: { system },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: CountingMeetingTranscriber(),
                                   detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
                                   save: save,
                                   config: .init(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 1_000_000))
            },
            database: db,
            trackURL: { id, track in folder.appending(path: "\(id.uuidString)/\(track.fileName)") },
            expectingSystemAudio: { expecting },
            language: { "pl" },
            setMuteSuppressed: { spy.calls.append($0) },
            postProcessors: []
        )
    }

    private func speech() -> [Float] { Array(repeating: 0.2, count: 4_096 * 5) }

    private func silence(seconds: Int = 1) -> [Float] { Array(repeating: 0, count: 16_000 * seconds) }

    /// Main-actor hops from the source threads land a moment later.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startStopCreatesACompletedMeetingWithSegmentsAndFiles() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource(), spy = MuteSpy()
        let env = environment(mic: mic, system: system, spy: spy, db: db)
        let recorder = MeetingRecorder(environment: env)
        await recorder.start(title: "Test")
        let id = try #require(recorder.currentMeetingID)
        #expect(recorder.isRecording)
        #expect(try await db.meeting(id: id)?.status == .recording)
        mic.push(speech())
        system.push(speech())
        await recorder.stop()
        #expect(recorder.phase == .idle)
        let meeting = try #require(try await db.meeting(id: id))
        #expect(meeting.status == .completed)
        #expect(meeting.title == "Test")
        #expect(try await db.segments(meetingID: id).count == 2)
        #expect(FileManager.default.fileExists(atPath: env.trackURL(id, .me).path))
        #expect(FileManager.default.fileExists(atPath: env.trackURL(id, .them).path))
        #expect(recorder.lastFinishedMeetingID == id)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
        #expect(recorder.liveSegments.count == 2)
    }

    @Test func dictationDoesNotStopMeetingAndMuteIsSuppressed() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let spy = MuteSpy()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: spy, db: db))
        await recorder.start()
        #expect(spy.calls == [true])
        await recorder.stop()
        #expect(spy.calls == [true, false])
    }

    /// Review focus 2 against the real `SystemMute`: the mute a dictation take schedules while a
    /// meeting records never fires, and the meeting keeps recording.
    @Test func aDictationMuteNeverFiresWhileAMeetingRecords() async throws {
        let suite = "com.captylo.app.tests.meeting-mute.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.muteWhileRecording = true
        let mute = SystemMute(settings: settings, defaults: defaults)
        // Only reached when the suppression is broken: never leave the test machine muted.
        defer { mute.restore() }
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        var env = environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.setMuteSuppressed = { mute.isSuppressed = $0 }
        let recorder = MeetingRecorder(environment: env)
        await recorder.start()
        #expect(mute.isSuppressed)

        mute.muteIfEnabled(after: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!mute.isMutedByUs)
        #expect(mute.marker == nil)
        #expect(recorder.isRecording)

        await recorder.stop()
        #expect(!mute.isSuppressed)
    }

    @Test func systemAudioFailureStillRecordsTheMic() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource()
        system.failOnStart = true
        let recorder = MeetingRecorder(environment: environment(mic: mic, system: system, spy: MuteSpy(), db: db))
        await recorder.start()
        #expect(recorder.isRecording)
        if case .unavailable = recorder.systemAudioIssue {} else { Issue.record("expected unavailable") }
        mic.push(speech())
        let id = try #require(recorder.currentMeetingID)
        await recorder.stop()
        #expect(try await db.segments(meetingID: id).map(\.track) == [.me])
    }

    @Test func bothSourcesFailingLeavesNothingBehind() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource(), spy = MuteSpy()
        mic.failOnStart = true
        system.failOnStart = true
        let env = environment(mic: mic, system: system, spy: spy, db: db)
        let recorder = MeetingRecorder(environment: env)
        await recorder.start()
        #expect(recorder.phase == .idle)
        #expect(recorder.lastError != nil)
        #expect(try await db.meetings(query: "", limit: 10).isEmpty)
        #expect(spy.calls == [true, false])
        let meetingsFolder = env.trackURL(UUID(), .me).deletingLastPathComponent().deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: meetingsFolder.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func zerosOnTheSystemTrackWhileAppsPlayShowNoAccess() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        for _ in 0..<5 { system.push(silence()) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.systemAudioIssue == .noAccess)
        await recorder.stop()
    }

    /// A call app that plays exact zeros before anyone speaks looks like a denied grant; the
    /// banner must go once the other side is heard.
    @Test func noAccessGoesAwayOnceTheSystemTrackHearsAudio() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        for _ in 0..<5 { system.push(silence()) }
        await waitUntil { recorder.systemAudioIssue == .noAccess }
        #expect(recorder.systemAudioIssue == .noAccess)
        system.push(speech())
        await waitUntil { recorder.systemAudioIssue == nil }
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
    }

    /// The HAL zero-buffer bug mid-meeting: the tap is rebuilt and the gap is kept on the meeting.
    @Test func aStalledSystemTrackIsRebuiltAndMarked() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<7 { system.push(silence()) }
        await waitUntil { system.startCount == 2 }
        #expect(system.startCount == 2)
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
        let meeting = try #require(try await db.meeting(id: id))
        #expect(meeting.interruptions.count == 1)
        #expect(meeting.status == .completed)
    }

    /// A call app keeps its output running and plays exact zeros while the other side is quiet
    /// (the user presents for minutes). That is one silent run: the tap is rebuilt once, not every
    /// `stallAfter` seconds, and the one gap is marked where the silence began. Real audio from
    /// the other side lets the next silent run rebuild again.
    @Test func aLongSilenceRebuildsTheSystemTapOnce() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<20 { system.push(silence()) }
        await waitUntil { system.startCount >= 2 && system.isRunning }
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.startCount == 2)

        // The rebuilt tap keeps getting the call's zeros: still the same run.
        for _ in 0..<13 { system.push(silence()) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.startCount == 2)

        system.push(speech())
        for _ in 0..<7 { system.push(silence()) }
        await waitUntil { system.startCount == 3 && system.isRunning }
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.startCount == 3)
        #expect(recorder.systemAudioIssue == nil)

        await recorder.stop()
        let meeting = try #require(try await db.meeting(id: id))
        #expect(meeting.interruptions.count == 2)
        // The silence began `stallAfter` (6 s) before the stall was detected, at the meeting's start here.
        #expect(meeting.interruptions.first == 0)
    }

    @Test func secondStartWhileRecordingIsIgnored() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: mic, system: FakeAudioSource(), spy: MuteSpy(), db: db))
        await recorder.start()
        let first = recorder.currentMeetingID
        await recorder.start()
        #expect(recorder.currentMeetingID == first)
        #expect(mic.startCount == 1)
        await recorder.stop()
    }

    /// A double click on "Nagraj spotkanie": the second start arrives while the first still waits
    /// for the database and must not open a second meeting.
    @Test func overlappingStartsOpenOneMeeting() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: mic, system: FakeAudioSource(), spy: MuteSpy(), db: db))
        async let first: Void = recorder.start()
        async let second: Void = recorder.start()
        _ = await (first, second)
        #expect(mic.startCount == 1)
        #expect(try await db.meetings(query: "", limit: 10).count == 1)
        await recorder.stop()
    }

    /// Review focus 1: a quit mid-meeting leaves finalized, readable tracks and the row still
    /// "recording", which the next launch turns into "Przerwane".
    @Test func quitMidMeetingKeepsReadableTracksForTheNextLaunch() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource()
        let env = environment(mic: mic, system: system, spy: MuteSpy(), db: db)
        let recorder = MeetingRecorder(environment: env)
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        mic.push(speech())
        system.push(speech())
        recorder.abortForTermination()
        #expect(recorder.phase == .idle)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
        let file = try AVAudioFile(forReading: env.trackURL(id, .me))
        #expect(file.length == Int64(speech().count))
        #expect(try await db.meeting(id: id)?.status == .recording)

        let next = MeetingRecorder(environment: env)
        next.recoverInterruptedMeetings()
        await next.start()
        #expect(try await db.meeting(id: id)?.status == .interrupted)
        await next.stop()
    }

    @Test func launchRecoveryNeverMarksAMeetingStartedRightAfterIt() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let old = MeetingRecord(createdAt: Date(timeIntervalSinceNow: -3_600), title: "Wczoraj")
        try await db.createMeeting(old)
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db))
        recorder.recoverInterruptedMeetings()
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        #expect(try await db.meeting(id: old.id)?.status == .interrupted)
        #expect(try await db.meeting(id: id)?.status == .recording)
        await recorder.stop()
        #expect(try await db.meeting(id: id)?.status == .completed)
    }

    @Test func liveTranscriptHidesMicEchoWhicheverTrackArrivesFirst() {
        let id = UUID()
        let them = MeetingSegmentRecord(meetingID: id, track: .them, start: 1, end: 4, text: "Omówmy budżet na przyszły kwartał")
        let echo = MeetingSegmentRecord(meetingID: id, track: .me, start: 1.2, end: 4.1, text: "omówmy budżet na przyszły kwartał")
        let reply = MeetingSegmentRecord(meetingID: id, track: .me, start: 4.5, end: 5, text: "Tak, jasne")

        var live = MeetingRecorder.liveTranscript(adding: them, to: [])
        live = MeetingRecorder.liveTranscript(adding: echo, to: live)
        #expect(live.map(\.id) == [them.id])

        var late = MeetingRecorder.liveTranscript(adding: echo, to: [])
        #expect(late.map(\.id) == [echo.id])
        late = MeetingRecorder.liveTranscript(adding: them, to: late)
        #expect(late.map(\.id) == [them.id])
        late = MeetingRecorder.liveTranscript(adding: reply, to: late)
        #expect(late.map(\.id) == [them.id, reply.id])
    }

    @Test func liveTranscriptStaysInTimeOrder() {
        let id = UUID()
        let them = MeetingSegmentRecord(meetingID: id, track: .them, start: 5, end: 7, text: "Dzień dobry wszystkim")
        let me = MeetingSegmentRecord(meetingID: id, track: .me, start: 2, end: 3, text: "Cześć")
        let later = MeetingSegmentRecord(meetingID: id, track: .me, start: 9, end: 10, text: "Zaczynamy")
        var live = MeetingRecorder.liveTranscript(adding: them, to: [])
        live = MeetingRecorder.liveTranscript(adding: me, to: live)
        live = MeetingRecorder.liveTranscript(adding: later, to: live)
        #expect(live.map(\.id) == [me.id, them.id, later.id])
    }

    @Test func defaultTitleNamesTheApp() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(MeetingRecorder.defaultTitle(appName: "Zoom", date: date).hasPrefix("Spotkanie w Zoom, "))
        #expect(MeetingRecorder.defaultTitle(appName: nil, date: date).hasPrefix("Spotkanie, "))
    }
}
