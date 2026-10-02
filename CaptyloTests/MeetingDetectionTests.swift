import Foundation
import Testing
@testable import Captylo

struct MeetingDetectionTests {
    private let zoom = MeetingApp(name: "Zoom", isBrowser: false)

    @Test func catalogKnowsCallAppsAndBrowsers() {
        #expect(MeetingAppCatalog.app(forBundleID: "us.zoom.xos") == zoom)
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.helper")?.isBrowser == true)
        #expect(MeetingAppCatalog.app(forBundleID: "com.spotify.client") == nil)
    }

    /// Electron apps and browsers take the mic from a helper process with its own bundle ID.
    @Test func catalogMatchesHelpersOnlyAtADotBoundary() {
        #expect(MeetingAppCatalog.app(forBundleID: "com.tinyspeck.slackmacgap.helper")?.name == "Slack")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2")?.name == "Teams")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams")?.name == "Teams")
        #expect(MeetingAppCatalog.app(forBundleID: "us.zoom.xosx") == nil)
        #expect(MeetingAppCatalog.app(forBundleID: "") == nil)
        #expect(MeetingAppCatalog.app(forBundleID: "com.apple.WebKit.GPU") == MeetingApp(name: "Safari", isBrowser: true))
        #expect(MeetingAppCatalog.app(forBundleID: "company.thebrowser.browser.helper")?.isBrowser == true)
    }

    /// Helpers (renderers, GPU, networking) quit all the time during a call: only the app's own
    /// bundle ID means the app is gone.
    @Test func onlyTheAppItselfCountsAsAMainApp() {
        #expect(MeetingAppCatalog.isMainApp(bundleID: "us.zoom.xos"))
        #expect(MeetingAppCatalog.isMainApp(bundleID: "com.microsoft.teams2"))
        #expect(MeetingAppCatalog.isMainApp(bundleID: "com.microsoft.teams"))
        #expect(MeetingAppCatalog.isMainApp(bundleID: "com.google.Chrome"))
        #expect(MeetingAppCatalog.isMainApp(bundleID: "com.apple.Safari"))
        #expect(MeetingAppCatalog.isMainApp(bundleID: "COMPANY.THEBROWSER.BROWSER"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "com.google.Chrome.helper.renderer"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "com.microsoft.teams2.helper"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "company.thebrowser.browser.helper"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "com.apple.WebKit.Networking"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "com.apple.WebKit"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: "com.spotify.client"))
        #expect(!MeetingAppCatalog.isMainApp(bundleID: ""))
    }

    /// A process that is not there has no windows and no tabs: nothing is known, the browser
    /// keeps counting.
    @Test func noWindowsToReadMeansNothingIsKnown() {
        #expect(BrowserCallWindows.check(owner: "com.captylo.no-such-browser", fallbackPID: pid_t.max) == .unknown)
    }

    @Test func browserWindowsAreReadFromTheBrowserItself() {
        #expect(MeetingAppCatalog.windowOwner(forBundleID: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(MeetingAppCatalog.windowOwner(forBundleID: "com.apple.WebKit.GPU") == "com.apple.Safari")
        #expect(MeetingAppCatalog.windowOwner(forBundleID: "us.zoom.xos") == nil)
    }

    @Test func callTitlesNameTheService() {
        #expect(MeetingAppCatalog.isCallTitle("Meet - abc-defg-hij"))
        #expect(MeetingAppCatalog.isCallTitle("Spotkanie | Microsoft Teams"))
        #expect(MeetingAppCatalog.isCallTitle("Jitsi Meet"))
        #expect(MeetingAppCatalog.isCallTitle("whereby - pokój"))
        #expect(!MeetingAppCatalog.isCallTitle("YouTube"))
        #expect(!MeetingAppCatalog.isCallTitle(""))
    }

    /// Reads this Mac: must answer without hanging, one entry per app (helpers merged). Which
    /// calls run depends on the machine.
    @Test func liveScanAnswersWithOneEntryPerApp() async {
        let scan = await MeetingDetector.liveScan(keeping: [])
        #expect(scan.apps.count == Set(scan.apps.map(\.name)).count)
        // Nothing is kept, so no kept browser can be missing its call window.
        #expect(scan.browsersWithoutCallWindow.isEmpty)
    }

    @Test func startsAfterFiveSecondsOfMicUseAndEndsAfterFortyFive() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        #expect(tracker.update(apps: [zoom], at: 0).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 4).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 6) == [.started(zoom)])
        #expect(tracker.update(apps: [zoom], at: 60).isEmpty)
        #expect(tracker.update(apps: [], at: 62).isEmpty)
        #expect(tracker.update(apps: [], at: 100).isEmpty)
        #expect(tracker.update(apps: [], at: 108) == [.ended(zoom)])
        #expect(tracker.update(apps: [], at: 200).isEmpty)
    }

    @Test func shortMicUseNeverStarts() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        #expect(tracker.update(apps: [], at: 3).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 4).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 8.5).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 9) == [.started(zoom)])
    }

    @Test func briefDropDuringACallDoesNotEndIt() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        _ = tracker.update(apps: [zoom], at: 6)
        #expect(tracker.update(apps: [], at: 20).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 30).isEmpty)
        #expect(tracker.update(apps: [], at: 70).isEmpty)
        #expect(tracker.update(apps: [], at: 116) == [.ended(zoom)])
    }

    @Test func twoAppsAreTrackedApart() {
        let meet = MeetingApp(name: "Chrome", isBrowser: true)
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        #expect(tracker.update(apps: [zoom, meet], at: 5) == [.started(zoom)])
        #expect(tracker.update(apps: [meet], at: 10) == [.started(meet)])
        #expect(tracker.update(apps: [], at: 55) == [.ended(zoom), .ended(meet)])
    }

    /// The process is gone: nothing can hold the mic, so the call ends without the 45 s wait.
    @Test func aQuitAppEndsItsCallAtOnce() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        #expect(tracker.update(apps: [zoom], at: 6) == [.started(zoom)])
        #expect(tracker.update(apps: [], at: 8, quit: ["Zoom"]) == [.ended(zoom)])
        // Ended once: the wait that would have ended it reports nothing more.
        #expect(tracker.update(apps: [], at: 60).isEmpty)
        // Relaunched and back in a call: a new call with its own 5 s.
        _ = tracker.update(apps: [zoom], at: 62)
        #expect(tracker.update(apps: [zoom], at: 68) == [.started(zoom)])
    }

    @Test func aQuitBeforeTheCallCountedIsNoEvent() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        #expect(tracker.update(apps: [], at: 2, quit: ["Zoom"]).isEmpty)
        #expect(tracker.update(apps: [], at: 50, quit: ["Teams"]).isEmpty)
        _ = tracker.update(apps: [zoom], at: 52)
        #expect(tracker.update(apps: [zoom], at: 55).isEmpty)
        #expect(tracker.update(apps: [zoom], at: 57) == [.started(zoom)])
    }

    /// A poll can shorten the wait (the recording's calendar event is long over): it applies to
    /// that poll only.
    @Test func aShorterEndWaitAppliesToThePollThatAsksForIt() {
        var tracker = DetectionTracker(startAfter: 5, endAfter: 45)
        _ = tracker.update(apps: [zoom], at: 0)
        _ = tracker.update(apps: [zoom], at: 6)
        #expect(tracker.update(apps: [zoom], at: 10).isEmpty)
        #expect(tracker.update(apps: [], at: 20, endAfter: 15).isEmpty)
        #expect(tracker.update(apps: [], at: 24).isEmpty)
        #expect(tracker.update(apps: [], at: 26, endAfter: 15) == [.ended(zoom)])
        #expect(tracker.update(apps: [], at: 100).isEmpty)
    }
}

// MARK: - Detector

/// What the fake world reports to the detector: apps in a call, the clock, the switch.
@MainActor
final class DetectionWorld {
    var apps: [MeetingApp] = []
    /// Browsers among `apps` that hold the mic without a call window (kept only because they
    /// are already in a call).
    var browsersWithoutCallWindow: Set<String> = []
    var now: Double = 0
    var enabled = true
    var openedMeetings = 0
    /// The calendar event matching "now", as `MeetingCalendar.currentEvent()` would answer.
    var event: CalendarEvent?
    /// The `keeping` set of every scan.
    var scans: [Set<String>] = []
}

@MainActor
final class DetectionToasts: ToastPresenting {
    struct Shown {
        let message: String
        let button: String?
        let lifetime: TimeInterval?
        let action: (@MainActor () -> Void)?
    }

    var shown: [Shown] = []

    func showInfo(_ message: String) {
        shown.append(Shown(message: message, button: nil, lifetime: nil, action: nil))
    }

    func showError(_ message: String) {
        shown.append(Shown(message: message, button: nil, lifetime: nil, action: nil))
    }

    func showAction(message: String, buttonTitle: String, action: @escaping @MainActor () -> Void) {
        shown.append(Shown(message: message, button: buttonTitle, lifetime: nil, action: action))
    }

    func showAction(message: String, buttonTitle: String, lifetime: TimeInterval, action: @escaping @MainActor () -> Void) {
        shown.append(Shown(message: message, button: buttonTitle, lifetime: lifetime, action: action))
    }
}

@MainActor
struct MeetingDetectorFlowTests {
    private let zoom = MeetingApp(name: "Zoom", isBrowser: false)
    private let chrome = MeetingApp(name: "Chrome", isBrowser: true)

    private struct Rig {
        let world: DetectionWorld
        let toasts: DetectionToasts
        let recorder: MeetingRecorder
        let detector: MeetingDetector
        let database: Database
    }

    private func rig(
        stopDelay: Duration = .milliseconds(40),
        engine: any MeetingSpeechTranscribing = CountingMeetingTranscriber(),
        mic: FakeAudioSource = FakeAudioSource()
    ) throws -> Rig {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let folder = FileManager.default.temporaryDirectory.appending(path: "detection-tests-\(UUID().uuidString)")
        let recorder = MeetingRecorder(environment: MeetingEnvironment(
            makeMic: { mic },
            makeSystem: { FakeAudioSource() },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: engine,
                                   detectorFactory: { _ in ScriptedSpeechDetector(startAt: 0, endAt: 3) },
                                   save: save,
                                   config: .init(maxSamples: 224_000, minSamples: 1_000, preRollSamples: 0, partialEverySamples: 1_000_000))
            },
            database: database,
            trackURL: { id, track in folder.appending(path: "\(id.uuidString)/\(track.fileName)") },
            expectingSystemAudio: { false },
            language: { "pl" },
            setMuteSuppressed: { _ in },
            postProcessors: []
        ))
        let world = DetectionWorld()
        let toasts = DetectionToasts()
        let detector = MeetingDetector(
            recorder: recorder,
            toasts: toasts,
            isEnabled: { world.enabled },
            openMeetings: { world.openedMeetings += 1 },
            scan: { keeping in
                world.scans.append(keeping)
                return CallScan(apps: world.apps, browsersWithoutCallWindow: world.browsersWithoutCallWindow)
            },
            clock: { world.now },
            currentEvent: { world.event },
            stopDelay: stopDelay
        )
        return Rig(world: world, toasts: toasts, recorder: recorder, detector: detector, database: database)
    }

    /// One poll at `time` with `apps` in a call.
    private func poll(_ rig: Rig, _ apps: [MeetingApp], at time: Double) async {
        rig.world.apps = apps
        rig.world.now = time
        await rig.detector.tick()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func recordPrompt(_ app: String) -> String {
        String(localized: "Wygląda na spotkanie w \(app). Nagrać notatki?")
    }

    private func stopPrompt(_ app: String) -> String {
        String(localized: "Spotkanie w \(app) zakończone? Kończę notatki za 15 s.")
    }

    /// Joins a Zoom call at 0..6 s and presses "Nagraj" on the prompt.
    private func recordZoomCall(_ rig: Rig) async throws {
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        let prompt = try #require(rig.toasts.shown.last)
        prompt.action?()
        await waitUntil { rig.recorder.isRecording }
        #expect(rig.recorder.isRecording)
    }

    @Test func aCallAsksOnceAndRecordStartsTheMeetingOnScreen() async throws {
        let rig = try rig()
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 2)
        #expect(rig.toasts.shown.isEmpty)
        #expect(rig.detector.lastOfferAt == nil)
        await poll(rig, [zoom], at: 6)
        #expect(rig.toasts.shown.map(\.message) == [recordPrompt("Zoom")])
        #expect(rig.toasts.shown.first?.button == String(localized: "Nagraj"))
        let offeredAt = try #require(rig.detector.lastOfferAt)
        #expect(abs(offeredAt.timeIntervalSinceNow) < 5)
        await poll(rig, [zoom], at: 8)
        #expect(rig.toasts.shown.count == 1)
        #expect(!rig.recorder.isRecording)

        rig.toasts.shown[0].action?()
        await waitUntil { rig.recorder.isRecording }
        #expect(rig.world.openedMeetings == 1)
        let id = try #require(rig.recorder.currentMeetingID)
        #expect(try await rig.database.meeting(id: id)?.appName == "Zoom")
        await rig.recorder.stop()
    }

    @Test func theEndOfTheCallAsksAndStopsAfterTheDelay() async throws {
        let rig = try rig()
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 20)
        #expect(rig.toasts.shown.count == 1)
        await poll(rig, [], at: 56)
        let prompt = try #require(rig.toasts.shown.last)
        #expect(prompt.message == stopPrompt("Zoom"))
        #expect(prompt.button == String(localized: "Nagrywaj dalej"))
        // The button stays reachable for the whole countdown (15 s in the app, 40 ms here).
        #expect(prompt.lifetime == 0.04)
        #expect(rig.recorder.isRecording)
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
        #expect(rig.recorder.lastFinishedMeetingID != nil)
    }

    @Test func keepRecordingCancelsTheStop() async throws {
        let rig = try rig()
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 56)
        try #require(rig.toasts.shown.count == 2)
        rig.toasts.shown[1].action?()
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.recorder.isRecording)
        // Each call ends once: no second prompt for the same Zoom call.
        await poll(rig, [], at: 120)
        #expect(rig.toasts.shown.count == 2)
        await rig.recorder.stop()
    }

    @Test func aStoppedRecordingIsNeverStoppedAgain() async throws {
        let rig = try rig(stopDelay: .milliseconds(80))
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 56)
        await rig.recorder.stop()
        await rig.recorder.start(title: "Nowe")
        let second = try #require(rig.recorder.currentMeetingID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.recorder.currentMeetingID == second)
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    @Test func noPromptsAndNoScansWhenDetectionIsOff() async throws {
        let rig = try rig()
        rig.world.enabled = false
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 10)
        #expect(rig.toasts.shown.isEmpty)
        #expect(rig.world.scans.isEmpty)
        // Turned on mid-call: the five seconds count from the first poll after the switch.
        rig.world.enabled = true
        await poll(rig, [zoom], at: 12)
        #expect(rig.toasts.shown.isEmpty)
        await poll(rig, [zoom], at: 17)
        #expect(rig.toasts.shown.map(\.message) == [recordPrompt("Zoom")])
    }

    /// Back-to-back calls: the next call starts while the last meeting still finishes. It is
    /// asked about once the recorder is idle again, and only once.
    @Test func aCallThatStartsWhileTheLastMeetingFinishesIsAskedAboutOnceIdle() async throws {
        let gate = TestGate()
        let mic = FakeAudioSource()
        let rig = try rig(engine: GatedMeetingTranscriber(gate: gate), mic: mic)
        await rig.recorder.start(title: "Poprzednie")
        // An utterance whose pass waits for the gate: the stop stays in "finishing".
        mic.push(Array(repeating: 0.2, count: 4_096 * 5))
        let stopping = Task { await rig.recorder.stop() }
        await waitUntil { rig.recorder.currentMeetingID != nil && !rig.recorder.isRecording }
        try #require(rig.recorder.currentMeetingID != nil && !rig.recorder.isRecording)
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        #expect(rig.toasts.shown.isEmpty)

        await gate.open()
        await stopping.value
        #expect(rig.recorder.phase == .idle)
        await poll(rig, [zoom], at: 8)
        #expect(rig.toasts.shown.map(\.message) == [recordPrompt("Zoom")])
        await poll(rig, [zoom], at: 10)
        #expect(rig.toasts.shown.count == 1)
    }

    /// A call that started and ended while the last meeting finished is not asked about.
    @Test func aCallThatEndedWhileTheLastMeetingFinishedIsNotAskedAbout() async throws {
        let gate = TestGate()
        let mic = FakeAudioSource()
        let rig = try rig(engine: GatedMeetingTranscriber(gate: gate), mic: mic)
        await rig.recorder.start(title: "Poprzednie")
        mic.push(Array(repeating: 0.2, count: 4_096 * 5))
        let stopping = Task { await rig.recorder.stop() }
        await waitUntil { rig.recorder.currentMeetingID != nil && !rig.recorder.isRecording }
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        await poll(rig, [], at: 8)
        await poll(rig, [], at: 54)
        await gate.open()
        await stopping.value
        await poll(rig, [], at: 56)
        #expect(rig.toasts.shown.isEmpty)
    }

    @Test func noRecordPromptWhileAMeetingRecords() async throws {
        let rig = try rig()
        await rig.recorder.start(title: "Na żywo")
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        #expect(rig.toasts.shown.isEmpty)
        await rig.recorder.stop()
    }

    /// A call that was over before a manual recording began must not end that recording.
    @Test func aCallThatEndedBeforeTheRecordingNeverStopsIt() async throws {
        let rig = try rig()
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        await poll(rig, [], at: 12)
        await rig.recorder.start(title: "Po rozmowie")
        await poll(rig, [], at: 14)
        await poll(rig, [], at: 60)
        #expect(rig.toasts.shown.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    /// A call joined after a manual start is part of that meeting: its end asks to stop.
    @Test func aCallJoinedDuringARecordingAsksToStopAtItsEnd() async throws {
        let rig = try rig()
        await rig.recorder.start(title: "Najpierw nagrywanie")
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        await poll(rig, [], at: 52)
        #expect(rig.toasts.shown.map(\.message) == [stopPrompt("Zoom")])
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// The Meet tab can lose focus mid-call (the window title changes): a browser already in a
    /// call keeps counting without the title check.
    @Test func browsersInACallAreKeptWithoutTheTitle() async throws {
        let rig = try rig()
        await poll(rig, [chrome], at: 0)
        #expect(rig.world.scans.last == [])
        await poll(rig, [chrome], at: 6)
        await poll(rig, [chrome], at: 8)
        #expect(rig.world.scans.last == ["Chrome"])
    }

    @Test func anotherCallStillRunningKeepsTheMeetingGoing() async throws {
        let rig = try rig()
        try await recordZoomCall(rig)
        await poll(rig, [zoom, chrome], at: 8)
        await poll(rig, [zoom, chrome], at: 14)
        await poll(rig, [chrome], at: 20)
        await poll(rig, [chrome], at: 66)
        #expect(rig.toasts.shown.count == 1)
        await poll(rig, [], at: 70)
        await poll(rig, [], at: 116)
        #expect(rig.toasts.shown.last?.message == stopPrompt("Chrome"))
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// A call that starts during a calendar event: the offer names the event, and "Nagraj"
    /// links the recording to it (title, id, participants) under the detected app's name.
    @Test func aCallDuringACalendarEventNamesItAndLinksTheRecording() async throws {
        let rig = try rig()
        let start = Date().addingTimeInterval(-3 * 60)
        rig.world.event = CalendarEvent(
            id: "ev-7", title: "Budżet Q4", start: start, end: start.addingTimeInterval(30 * 60),
            isAllDay: false, calendarTitle: "Praca", participants: ["Anna Kowalska", "Piotr Nowak"], callApp: "Meet"
        )
        await poll(rig, [zoom], at: 0)
        await poll(rig, [zoom], at: 6)
        let prompt = try #require(rig.toasts.shown.last)
        #expect(prompt.message == String(localized: "Wygląda na spotkanie „Budżet Q4” w Zoom. Nagrać notatki?"))
        #expect(prompt.button == String(localized: "Nagraj"))
        // The calendar reminder reads this to stay quiet about the same call.
        let offeredAt = try #require(rig.detector.lastOfferAt)
        #expect(abs(offeredAt.timeIntervalSinceNow) < 5)
        // The event is the one shown, even when the calendar matches another by the click.
        rig.world.event = nil
        prompt.action?()
        await waitUntil { rig.recorder.isRecording }
        let id = try #require(rig.recorder.currentMeetingID)
        let meeting = try #require(try await rig.database.meeting(id: id))
        #expect(meeting.title == "Budżet Q4")
        #expect(meeting.calendarEventID == "ev-7")
        #expect(meeting.participants == ["Anna Kowalska", "Piotr Nowak"])
        #expect(meeting.appName == "Zoom")
        await rig.recorder.stop()
    }

    @Test func micUseAgainDuringTheCountdownKeepsRecording() async throws {
        let rig = try rig(stopDelay: .milliseconds(150))
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 56)
        await poll(rig, [zoom], at: 58)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    // MARK: Call end

    /// The call app quit: its process holds no mic, so the stop is offered at the next poll
    /// instead of 45 s later.
    @Test func aQuitCallAppAsksToStopAtOnce() async throws {
        let rig = try rig()
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        rig.detector.appDidQuit(bundleID: "us.zoom.xos")
        await poll(rig, [], at: 12)
        #expect(rig.toasts.shown.map(\.message) == [recordPrompt("Zoom"), stopPrompt("Zoom")])
        #expect(rig.toasts.shown.last?.button == String(localized: "Nagrywaj dalej"))
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// A quit of an app that is not in a call (or not a call app) changes nothing.
    @Test func aQuitOfAnotherAppIsIgnored() async throws {
        let rig = try rig()
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        rig.detector.appDidQuit(bundleID: "com.google.Chrome")
        rig.detector.appDidQuit(bundleID: "com.spotify.client")
        await poll(rig, [zoom], at: 12)
        await poll(rig, [], at: 14)
        #expect(rig.toasts.shown.count == 1)
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    /// Records a Meet call in Chrome (0..6 s) and presses "Nagraj".
    private func recordChromeCall(_ rig: Rig) async throws {
        await poll(rig, [chrome], at: 0)
        await poll(rig, [chrome], at: 6)
        let prompt = try #require(rig.toasts.shown.last)
        prompt.action?()
        await waitUntil { rig.recorder.isRecording }
        #expect(rig.recorder.isRecording)
    }

    /// A browser renderer quits whenever a tab closes: the call in another tab goes on, the
    /// browser stays kept. Only the browser itself quitting ends the call.
    @Test func aHelperQuitDuringABrowserCallChangesNothing() async throws {
        let rig = try rig()
        try await recordChromeCall(rig)
        await poll(rig, [chrome], at: 10)
        rig.detector.appDidQuit(bundleID: "com.google.Chrome.helper.renderer")
        rig.detector.appDidQuit(bundleID: "com.google.Chrome.helper")
        await poll(rig, [chrome], at: 12)
        #expect(rig.world.scans.last == ["Chrome"])
        await poll(rig, [chrome], at: 14)
        #expect(rig.toasts.shown.count == 1)
        #expect(!rig.detector.isStopPending)
        rig.detector.appDidQuit(bundleID: "com.google.Chrome")
        await poll(rig, [], at: 16)
        #expect(rig.toasts.shown.last?.message == stopPrompt("Chrome"))
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// Teams and Safari helpers come and go during a call too.
    @Test func aHelperQuitDuringANativeCallChangesNothing() async throws {
        let teams = MeetingApp(name: "Teams", isBrowser: false)
        let rig = try rig()
        await poll(rig, [teams], at: 0)
        await poll(rig, [teams], at: 6)
        let prompt = try #require(rig.toasts.shown.last)
        prompt.action?()
        await waitUntil { rig.recorder.isRecording }
        await poll(rig, [teams], at: 10)
        rig.detector.appDidQuit(bundleID: "com.microsoft.teams2.helper")
        rig.detector.appDidQuit(bundleID: "com.apple.WebKit.Networking")
        await poll(rig, [teams], at: 12)
        await poll(rig, [teams], at: 14)
        #expect(rig.toasts.shown.count == 1)
        #expect(!rig.detector.isStopPending)
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    /// The user left Meet but another tab keeps the mic: after 30 s with no call window and no
    /// call tab (the tab strip was read) the browser no longer counts, and the usual 45 s end
    /// the call.
    @Test func aBrowserHoldingTheMicWithoutACallWindowIsDroppedAfterThirtySeconds() async throws {
        let rig = try rig()
        try await recordChromeCall(rig)
        await poll(rig, [chrome], at: 10)
        rig.world.browsersWithoutCallWindow = ["Chrome"]
        await poll(rig, [chrome], at: 12)
        await poll(rig, [chrome], at: 30)
        // 28 s without the window: still the call (the last mic use that counts).
        await poll(rig, [chrome], at: 40)
        #expect(rig.toasts.shown.count == 1)
        // 32 s without it: the browser is dropped, and the usual 45 s run from 40.
        await poll(rig, [chrome], at: 44)
        await poll(rig, [chrome], at: 80)
        #expect(rig.toasts.shown.count == 1)
        await poll(rig, [chrome], at: 86)
        #expect(rig.toasts.shown.last?.message == stopPrompt("Chrome"))
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// Back on the Meet tab before 30 s: the count starts over; a shorter absence never ends.
    @Test func aCallWindowComingBackResetsTheBrowserIdleCount() async throws {
        let rig = try rig()
        try await recordChromeCall(rig)
        rig.world.browsersWithoutCallWindow = ["Chrome"]
        await poll(rig, [chrome], at: 10)
        await poll(rig, [chrome], at: 30)
        rig.world.browsersWithoutCallWindow = []
        await poll(rig, [chrome], at: 32)
        rig.world.browsersWithoutCallWindow = ["Chrome"]
        await poll(rig, [chrome], at: 40)
        await poll(rig, [chrome], at: 60)
        await poll(rig, [chrome], at: 68)
        // Back on Meet each time before 30 s: never dropped, nothing ends.
        rig.world.browsersWithoutCallWindow = []
        await poll(rig, [chrome], at: 69)
        await poll(rig, [chrome], at: 120)
        #expect(rig.toasts.shown.count == 1)
        #expect(rig.recorder.isRecording)
        await rig.recorder.stop()
    }

    private func overrunEvent(endedMinutesAgo: Double) -> CalendarEvent {
        let end = Date().addingTimeInterval(-endedMinutesAgo * 60)
        return CalendarEvent(
            id: "ev-9", title: "Budżet Q4", start: end.addingTimeInterval(-30 * 60), end: end,
            isAllDay: false, calendarTitle: "Praca", participants: ["Anna Kowalska"], callApp: "Zoom"
        )
    }

    /// The recording's calendar event ended more than 5 min ago: the call ends after 15 s without
    /// the mic (not 45) and the toast names the event.
    @Test func aRecordingWhoseEventIsLongOverEndsAfterFifteenSeconds() async throws {
        let rig = try rig()
        rig.world.event = overrunEvent(endedMinutesAgo: 10)
        try await recordZoomCall(rig)
        #expect(rig.recorder.linkedEvent?.id == "ev-9")
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 20)
        #expect(rig.toasts.shown.count == 1)
        await poll(rig, [], at: 27)
        let prompt = try #require(rig.toasts.shown.last)
        #expect(prompt.message == String(localized: "„Budżet Q4” już się skończyło? Kończę notatki za 15 s."))
        #expect(prompt.button == String(localized: "Nagrywaj dalej"))
        #expect(prompt.lifetime == 0.04)
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// An event over for less than 5 min changes nothing: meetings run late.
    @Test func anEventJustOverKeepsTheFullWait() async throws {
        let rig = try rig()
        rig.world.event = overrunEvent(endedMinutesAgo: 2)
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 27)
        await poll(rig, [], at: 40)
        #expect(rig.toasts.shown.count == 1)
        await poll(rig, [], at: 56)
        #expect(rig.toasts.shown.last?.message == stopPrompt("Zoom"))
        await waitUntil { rig.recorder.phase == .idle }
        #expect(rig.recorder.phase == .idle)
    }

    /// "Nagrywaj dalej" on the calendar toast keeps recording like on the app toast.
    @Test func keepRecordingCancelsTheCalendarStop() async throws {
        let rig = try rig()
        rig.world.event = overrunEvent(endedMinutesAgo: 10)
        try await recordZoomCall(rig)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 27)
        try #require(rig.toasts.shown.count == 2)
        rig.toasts.shown[1].action?()
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.recorder.isRecording)
        #expect(!rig.detector.isStopPending)
        await rig.recorder.stop()
    }

    /// A manual stop during the countdown is final: the countdown is dropped and the next
    /// recording is never touched by it.
    @Test func aManualStopDuringTheCountdownIsFinal() async throws {
        let rig = try rig(stopDelay: .milliseconds(200))
        try await recordZoomCall(rig)
        let first = try #require(rig.recorder.currentMeetingID)
        await poll(rig, [zoom], at: 10)
        await poll(rig, [], at: 56)
        try #require(rig.detector.isStopPending)
        await rig.recorder.stop()
        await rig.recorder.start(title: "Nowe")
        let second = try #require(rig.recorder.currentMeetingID)
        await poll(rig, [], at: 58)
        #expect(!rig.detector.isStopPending)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.recorder.currentMeetingID == second)
        #expect(rig.recorder.isRecording)
        #expect(rig.recorder.lastFinishedMeetingID == first)
        #expect(rig.toasts.shown.count == 2)
        await rig.recorder.stop()
    }
}
