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
        let apps = await MeetingDetector.liveScan(keeping: [])
        #expect(apps.count == Set(apps.map(\.name)).count)
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
}

// MARK: - Detector

/// What the fake world reports to the detector: apps in a call, the clock, the switch.
@MainActor
final class DetectionWorld {
    var apps: [MeetingApp] = []
    var now: Double = 0
    var enabled = true
    var openedMeetings = 0
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

    private func rig(stopDelay: Duration = .milliseconds(40)) throws -> Rig {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let folder = FileManager.default.temporaryDirectory.appending(path: "detection-tests-\(UUID().uuidString)")
        let recorder = MeetingRecorder(environment: MeetingEnvironment(
            makeMic: { FakeAudioSource() },
            makeSystem: { FakeAudioSource() },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: CountingMeetingTranscriber(),
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
                return world.apps
            },
            clock: { world.now },
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
        await poll(rig, [zoom], at: 6)
        #expect(rig.toasts.shown.map(\.message) == [recordPrompt("Zoom")])
        #expect(rig.toasts.shown.first?.button == String(localized: "Nagraj"))
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
}
