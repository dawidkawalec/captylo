import Foundation
import Testing
@testable import Captylo

/// `CalendarReminder` over a fake clock, fake toasts and a recorder on fake audio: when the
/// toast fires, what it says, and every reason it stays quiet.
@MainActor
struct MeetingCalendarReminderTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    final class World {
        var now: Date
        var events: [CalendarEvent] = []
        var enabled = true
        var minutes = 1
        var lastDetectorOffer: Date?
        var openedMeetings = 0
        init(now: Date) { self.now = now }
    }

    private struct Rig {
        let world: World
        let toasts: DetectionToasts
        let recorder: MeetingRecorder
        let reminder: CalendarReminder
        let database: Database
    }

    private func rig() throws -> Rig {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        let folder = FileManager.default.temporaryDirectory.appending(path: "reminder-tests-\(UUID().uuidString)")
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
        let world = World(now: base)
        let toasts = DetectionToasts()
        let reminder = CalendarReminder(
            recorder: recorder,
            toasts: toasts,
            events: { world.events },
            isEnabled: { world.enabled },
            minutesBefore: { world.minutes },
            lastDetectorOffer: { world.lastDetectorOffer },
            openMeetings: { world.openedMeetings += 1 },
            now: { world.now }
        )
        return Rig(world: world, toasts: toasts, recorder: recorder, reminder: reminder, database: database)
    }

    private func event(_ id: String = "ev-1", title: String = "Budżet Q4", startsIn seconds: TimeInterval, callApp: String? = "Meet", participants: [String] = ["Anna Kowalska"]) -> CalendarEvent {
        let start = base.addingTimeInterval(seconds)
        return CalendarEvent(
            id: id, title: title, start: start, end: start.addingTimeInterval(30 * 60),
            isAllDay: false, calendarTitle: "Praca", participants: participants, callApp: callApp
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Firing

    @Test func firesOncePerEventInsideTheWindow() throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 55)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
        #expect(rig.toasts.shown.first?.message == String(localized: "Za 1 min: „Budżet Q4” (Meet). Nagrać notatki?"))
        #expect(rig.toasts.shown.first?.button == String(localized: "Nagraj"))

        // The same event on the next checks, before and after its start: nothing more.
        rig.reminder.tick()
        rig.world.now = base.addingTimeInterval(70)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
    }

    @Test func staysQuietBeforeTheWindowAndAfterTheGrace() throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 3 * 60)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)

        // The window opens one minute before the start.
        rig.world.now = base.addingTimeInterval(2 * 60 + 1)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)

        // Another event missed by a long sleep: more than a minute after its start, nothing.
        rig.world.events = [event("ev-2", startsIn: 60)]
        rig.world.now = base.addingTimeInterval(60 + CalendarReminder.graceAfterStart + 1)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
    }

    @Test func anEventAlreadyStartedReadsZaczynaSie() throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: -30)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.last?.message == String(localized: "Zaczyna się: „Budżet Q4” (Meet). Nagrać notatki?"))
    }

    @Test func theMinutesSettingSetsTheWindowAndTheText() throws {
        let rig = try rig()
        rig.world.minutes = 5
        rig.world.events = [event(startsIn: 4 * 60 + 30)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.last?.message == String(localized: "Za 5 min: „Budżet Q4” (Meet). Nagrać notatki?"))

        // "W chwili startu": nothing before the start, the toast once it has started.
        rig.world.minutes = 0
        rig.world.events = [event("ev-2", startsIn: 30)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
        rig.world.now = base.addingTimeInterval(31)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 2)
        #expect(rig.toasts.shown.last?.message == String(localized: "Zaczyna się: „Budżet Q4” (Meet). Nagrać notatki?"))
    }

    @Test func anEventWithoutATitleUsesTheDefaultMeetingName() throws {
        let rig = try rig()
        let untitled = event(title: "", startsIn: 30)
        rig.world.events = [untitled]
        rig.reminder.tick()
        let name = MeetingRecorder.defaultTitle(appName: "Meet", date: untitled.start)
        #expect(rig.toasts.shown.last?.message == String(localized: "Za 1 min: „\(name)” (Meet). Nagrać notatki?"))
    }

    // MARK: Skips

    @Test func eventsWithoutACallLinkGetNoReminder() throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 30, callApp: nil)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)
    }

    @Test func nothingWhileTheSwitchesAreOff() throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 30)]
        rig.world.enabled = false
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)

        // The calendar off: no events reach the reminder.
        rig.world.enabled = true
        rig.world.events = []
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)

        // Back on inside the window: the toast was never shown, so it shows now.
        rig.world.events = [event(startsIn: 30)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
    }

    @Test func nothingWhileAMeetingRecordsOrStarts() async throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 30)]
        await rig.recorder.start(title: "Inne")
        #expect(rig.recorder.isRecording)
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)
        await rig.recorder.stop()
        await waitUntil { rig.recorder.phase == .idle }

        // Still inside the window after the stop: the event was never offered, so it is now.
        rig.world.now = base.addingTimeInterval(40)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
    }

    @Test func aRecentDetectorOfferSilencesTheEventForGood() throws {
        let rig = try rig()
        rig.world.minutes = 5
        rig.world.events = [event(startsIn: 4 * 60)]
        rig.world.lastDetectorOffer = base.addingTimeInterval(-60)
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)

        // The offer is older than two minutes now, but the user already said no to this call.
        rig.world.now = base.addingTimeInterval(2 * 60)
        rig.reminder.tick()
        #expect(rig.toasts.shown.isEmpty)

        // An old offer does not touch a later event.
        rig.world.events = [event("ev-2", startsIn: 3 * 60)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 1)
    }

    @Test func twoEventsInTheWindowGetOneToastEach() throws {
        let rig = try rig()
        rig.world.minutes = 2
        rig.world.events = [event("a", title: "A", startsIn: 60), event("b", title: "B", startsIn: 90)]
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 2)
        rig.reminder.tick()
        #expect(rig.toasts.shown.count == 2)
    }

    // MARK: Button

    @Test func nagrajOpensSpotkaniaAndStartsWithTheEvent() async throws {
        let rig = try rig()
        let budget = event(startsIn: 30)
        rig.world.events = [budget]
        rig.reminder.tick()
        let toast = try #require(rig.toasts.shown.last)
        toast.action?()
        #expect(rig.world.openedMeetings == 1)
        await waitUntil { rig.recorder.isRecording }
        let id = try #require(rig.recorder.currentMeetingID)
        let meeting = try #require(try await rig.database.meeting(id: id))
        #expect(meeting.title == "Budżet Q4")
        #expect(meeting.calendarEventID == "ev-1")
        #expect(meeting.participants == ["Anna Kowalska"])
        #expect(meeting.appName == "Meet")
        await rig.recorder.stop()
        await waitUntil { rig.recorder.phase == .idle }
    }

    @Test func nagrajDoesNothingWhileAnotherMeetingRecords() async throws {
        let rig = try rig()
        rig.world.events = [event(startsIn: 30)]
        rig.reminder.tick()
        let toast = try #require(rig.toasts.shown.last)
        await rig.recorder.start(title: "Inne")
        let before = rig.recorder.currentMeetingID
        toast.action?()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.world.openedMeetings == 0)
        #expect(rig.recorder.currentMeetingID == before)
        await rig.recorder.stop()
        await waitUntil { rig.recorder.phase == .idle }
    }

    // MARK: Text helpers

    @Test func minutesLeftRoundUp() {
        #expect(CalendarReminder.minutesLeft(until: base.addingTimeInterval(1), now: base) == 1)
        #expect(CalendarReminder.minutesLeft(until: base.addingTimeInterval(60), now: base) == 1)
        #expect(CalendarReminder.minutesLeft(until: base.addingTimeInterval(61), now: base) == 2)
        #expect(CalendarReminder.minutesLeft(until: base.addingTimeInterval(270), now: base) == 5)
        #expect(CalendarReminder.minutesLeft(until: base, now: base) == 0)
        #expect(CalendarReminder.minutesLeft(until: base.addingTimeInterval(-10), now: base) == 0)
    }
}
