import AVFoundation
import Foundation
import os
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
        await recorder.waitForPostProcessing()
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

    /// The live bar says the mic is missing while the meeting records; once it stops, `lastError`
    /// only ever means "the last start failed".
    @Test func aMicFailureShowsWhileRecordingAndClearsAtStop() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource()
        mic.failOnStart = true
        let recorder = MeetingRecorder(environment: environment(mic: mic, system: FakeAudioSource(), spy: MuteSpy(), db: db))
        await recorder.start()
        #expect(recorder.isRecording)
        #expect(recorder.lastError != nil)
        await recorder.stop()
        #expect(recorder.lastError == nil)
    }

    /// "Nagrywasz spotkanie. Poinformuj uczestników." comes back with every start until closed.
    @Test func everyStartShowsTheConsentReminderUntilDismissed() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db))
        #expect(!recorder.showsConsentReminder)
        await recorder.start()
        #expect(recorder.showsConsentReminder)
        recorder.dismissConsentReminder()
        #expect(!recorder.showsConsentReminder)
        await recorder.stop()
        await recorder.start()
        #expect(recorder.showsConsentReminder)
        await recorder.stop()
        #expect(!recorder.showsConsentReminder)
    }

    /// The headphones hint follows the default output while a meeting records, and goes away with it.
    @Test func builtInSpeakersAreReportedOnlyWhileRecording() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        var env = environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.outputUsesBuiltInSpeakers = { true }
        let recorder = MeetingRecorder(environment: env)
        #expect(!recorder.usesBuiltInSpeakers)
        await recorder.start()
        await waitUntil { recorder.usesBuiltInSpeakers }
        #expect(recorder.usesBuiltInSpeakers)
        await recorder.stop()
        #expect(!recorder.usesBuiltInSpeakers)
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

    /// A call app keeps its output running and plays exact zeros while the other side is quiet.
    /// The user speaking for 10 s is normal conversation: no tap rebuild, no "przerwa w nagraniu".
    @Test func tenSecondsOfTheUserSpeakingLeaveTheSystemTapAlone() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: mic, system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<10 {
            mic.push(Array(repeating: 0.2, count: 16_000))
            system.push(silence())
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.startCount == 1)
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
        #expect(try #require(try await db.meeting(id: id)).interruptions.isEmpty)
    }

    /// Half a minute of zeros rebuilds the tap quietly: when the other side speaks only later,
    /// it was just quiet and the meeting keeps no gap.
    @Test func aLongQuietStretchRebuildsTheTapWithoutAGap() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<29 { system.push(silence()) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(system.startCount == 1)
        system.push(silence())
        await waitUntil { system.startCount == 2 && system.isRunning }
        #expect(system.startCount == 2)

        for _ in 0..<5 { system.push(silence()) }
        system.push(speech())
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.startCount == 2)
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
        #expect(try #require(try await db.meeting(id: id)).interruptions.isEmpty)
    }

    /// The HAL zero-buffer bug mid-meeting: the rebuilt tap hears the other side at once, so the
    /// gap is kept on the meeting where the zeros began (the meeting's start here).
    @Test func aStallFixedByARebuildIsMarked() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<30 { system.push(silence()) }
        await waitUntil { system.startCount == 2 && system.isRunning }
        system.push(speech())
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
        await recorder.waitForPostProcessing()
        let meeting = try #require(try await db.meeting(id: id))
        #expect(meeting.interruptions == [0])
        #expect(meeting.status == .completed)
    }

    /// Review focus 3: the rebuilt tap still hears only zeros while the call plays. The tap is
    /// rebuilt again and the live bar warns instead of leaving "Rozmówcy" silently empty; the
    /// meeting ending in that state keeps the gap.
    @Test func aRebuildThatBringsNothingBackIsRetriedAndWarns() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<30 { system.push(silence()) }
        await waitUntil { system.startCount == 2 && system.isRunning }
        #expect(recorder.systemAudioIssue == nil)
        for _ in 0..<30 { system.push(silence()) }
        await waitUntil { system.startCount == 3 && system.isRunning && recorder.systemAudioIssue == .silent }
        #expect(system.startCount == 3)
        #expect(recorder.systemAudioIssue == .silent)
        await recorder.stop()
        #expect(try #require(try await db.meeting(id: id)).interruptions == [0])
    }

    @Test func audioAfterARetriedRebuildClearsTheWarning() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<30 { system.push(silence()) }
        await waitUntil { system.startCount == 2 && system.isRunning }
        for _ in 0..<30 { system.push(silence()) }
        await waitUntil { system.startCount == 3 && system.isRunning && recorder.systemAudioIssue == .silent }
        system.push(speech())
        await waitUntil { recorder.systemAudioIssue == nil }
        #expect(recorder.systemAudioIssue == nil)
        await recorder.stop()
        #expect(try #require(try await db.meeting(id: id)).interruptions == [0])
    }

    /// A rebuild that fails leaves no tap: the banner says so and the gap is kept.
    @Test func aFailedRebuildShowsUnavailableAndKeepsTheGap() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let system = FakeAudioSource()
        let recorder = MeetingRecorder(environment: environment(mic: FakeAudioSource(), system: system, spy: MuteSpy(), db: db, expecting: true))
        await recorder.start()
        let id = try #require(recorder.currentMeetingID)
        system.push(speech())
        for _ in 0..<29 { system.push(silence()) }
        system.failOnStart = true
        system.push(silence())
        await waitUntil { recorder.systemAudioIssue != nil }
        if case .unavailable = recorder.systemAudioIssue {} else { Issue.record("expected unavailable") }
        await recorder.stop()
        #expect(try #require(try await db.meeting(id: id)).interruptions == [0])
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
        await recorder.waitForPostProcessing()
        #expect(try await db.meeting(id: id)?.status == .completed)
    }

    // MARK: Speech model and VAD

    /// Without the speech model every pass would fail: the meeting would record audio and end
    /// with no transcript. The start is refused and Spotkania points to Modele instead.
    @Test func aMissingSpeechModelKeepsTheMeetingFromStarting() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource(), system = FakeAudioSource(), spy = MuteSpy()
        let ready = OSAllocatedUnfairLock(initialState: false)
        var env = environment(mic: mic, system: system, spy: spy, db: db)
        env.speechModelReady = { ready.withLock { $0 } }
        let recorder = MeetingRecorder(environment: env)
        await recorder.start()
        #expect(recorder.phase == .idle)
        #expect(recorder.needsSpeechModel)
        #expect(recorder.lastError == String(localized: "Brakuje modelu mowy. Pobierz go w zakładce Modele."))
        #expect(try await db.meetings(query: "", limit: 10).isEmpty)
        #expect(mic.startCount == 0)
        #expect(system.startCount == 0)
        #expect(spy.calls.isEmpty)

        ready.withLock { $0 = true }
        await recorder.start()
        #expect(recorder.isRecording)
        #expect(!recorder.needsSpeechModel)
        #expect(recorder.lastError == nil)
        await recorder.stop()
    }

    /// The VAD downloads on the first meeting; offline it cannot load and nothing becomes a
    /// line. The live bar says so while it records, and the warning goes with the stop.
    @Test func aSpeechDetectorThatCannotLoadIsShownWhileRecording() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource()
        var env = environment(mic: mic, system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.makeTranscriber = { id, language, save in
            MeetingTranscriber(meetingID: id, language: language, engine: CountingMeetingTranscriber(),
                               detectorFactory: { _ in throw ScriptedFailure() }, save: save)
        }
        let recorder = MeetingRecorder(environment: env)
        await recorder.start()
        #expect(recorder.transcriptionProblem == nil)
        mic.push(silence())
        await waitUntil { recorder.transcriptionProblem == .speechDetector }
        #expect(recorder.transcriptionProblem == .speechDetector)
        await recorder.stop()
        #expect(recorder.transcriptionProblem == nil)
    }

    // MARK: After the stop

    /// Speaker labels and AI notes can take minutes: the recorder is idle again as soon as the
    /// transcript is saved (a back-to-back call can be recorded), and the meeting reads
    /// "processing" until they are done.
    @Test func theRecorderIsIdleWhileThePostProcessorsRun() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let mic = FakeAudioSource()
        let gate = TestGate()
        let processor = GatedPostProcessor(gate: gate, database: db)
        var env = environment(mic: mic, system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.postProcessors = [processor]
        let recorder = MeetingRecorder(environment: env)
        await recorder.start(title: "Pierwsze")
        let id = try #require(recorder.currentMeetingID)
        mic.push(speech())
        await recorder.stop()
        #expect(recorder.phase == .idle)
        #expect(recorder.lastFinishedMeetingID == id)
        #expect(recorder.processedCount == 0)
        let stopped = try #require(try await db.meeting(id: id))
        #expect(stopped.status == .processing)
        #expect(stopped.duration > 0)
        #expect(try await db.segments(meetingID: id).count == 1)

        await recorder.start(title: "Drugie")
        #expect(recorder.isRecording)
        await recorder.stop()

        await gate.open()
        await recorder.waitForPostProcessing()
        #expect(recorder.processedCount == 2)
        #expect(try await db.meeting(id: id)?.status == .completed)
    }

    /// Two meetings stopped back to back are processed one after the other, in stop order.
    @Test func postProcessingRunsOneMeetingAtATime() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let gate = TestGate()
        let processor = GatedPostProcessor(gate: gate, database: db)
        var env = environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.postProcessors = [processor]
        let recorder = MeetingRecorder(environment: env)
        await recorder.start(title: "A")
        let first = try #require(recorder.currentMeetingID)
        await recorder.stop()
        await recorder.start(title: "B")
        let second = try #require(recorder.currentMeetingID)
        await recorder.stop()
        for _ in 0..<300 where await processor.events.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await processor.events == [.started(first)])
        #expect(try await db.meeting(id: second)?.status == .processing)

        await gate.open()
        await recorder.waitForPostProcessing()
        #expect(await processor.events == [.started(first), .finished(first), .started(second), .finished(second)])
        #expect(try await db.meeting(id: first)?.status == .completed)
        #expect(try await db.meeting(id: second)?.status == .completed)
    }

    // MARK: Title

    /// A title typed while the meeting records is what the AI notes see at the stop, so the
    /// template follows it ("Daily" picks Standup); the stop never writes the old title back.
    @Test func aTitleChangedWhileRecordingReachesThePostProcessors() async throws {
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let gate = TestGate()
        await gate.open()
        let processor = GatedPostProcessor(gate: gate, database: db)
        var env = environment(mic: FakeAudioSource(), system: FakeAudioSource(), spy: MuteSpy(), db: db)
        env.postProcessors = [processor]
        let recorder = MeetingRecorder(environment: env)
        await recorder.start(appName: "Zoom")
        let id = try #require(recorder.currentMeetingID)
        let initial = try #require(try await db.meeting(id: id)?.title)
        #expect(BuiltInMeetingTemplates.pick(forTitle: initial).id == BuiltInMeetingTemplates.general.id)
        try await db.modifyMeeting(id: id) { $0.title = "Daily zespołu" }
        await recorder.stop()
        await recorder.waitForPostProcessing()
        #expect(await processor.titles == ["Daily zespołu"])
        #expect(try await db.meeting(id: id)?.title == "Daily zespołu")
        #expect(BuiltInMeetingTemplates.pick(forTitle: "Daily zespołu").id == "standup")
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
