import Foundation

/// A toast shortly before a calendar event with a call link: "Za 1 min: „Budżet Q4” (Meet).
/// Nagrać notatki?" (or "Zaczyna się: ..." once it has started) with "Nagraj", which opens
/// Spotkania and starts the recorder on that event. Checks every `checkInterval` while
/// "Kalendarz" and "Przypominaj przed spotkaniem" are on; never starts a recording by itself.
///
/// Quiet while a meeting records or starts, for events without a call link (in-person meetings
/// are started by hand) and more than `graceAfterStart` after the start (the Mac was asleep).
/// A call the detector offered within the last `detectorQuiet` silences its event for good: the
/// user already answered once about this call. One toast per event id per launch.
@MainActor
final class CalendarReminder {
    nonisolated static let checkInterval: Duration = .seconds(30)
    /// An event still gets its toast this long after its start.
    nonisolated static let graceAfterStart: TimeInterval = 60
    /// No toast for an event when the detector offered a call this recently.
    nonisolated static let detectorQuiet: TimeInterval = 2 * 60

    private let recorder: MeetingRecorder
    private let toasts: any ToastPresenting
    private let events: @MainActor () -> [CalendarEvent]
    private let isEnabled: @MainActor () -> Bool
    private let minutesBefore: @MainActor () -> Int
    private let lastDetectorOffer: @MainActor () -> Date?
    private let openMeetings: @MainActor () -> Void
    private let now: @MainActor () -> Date

    /// Event ids shown (or silenced by a detector offer) since launch.
    private var reminded: Set<String> = []
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - events: the calendar's upcoming events, empty while "Kalendarz" is off or has no access.
    ///   - isEnabled: `settings.meetingsCalendarReminder`.
    ///   - minutesBefore: `settings.meetingsCalendarReminderMinutes` (0 = at the start).
    ///   - lastDetectorOffer: `MeetingDetector.lastOfferAt`.
    ///   - openMeetings: brings the main window forward on Spotkania before the recorder starts.
    ///   - now: the clock, replaced in tests.
    init(
        recorder: MeetingRecorder,
        toasts: any ToastPresenting,
        events: @escaping @MainActor () -> [CalendarEvent],
        isEnabled: @escaping @MainActor () -> Bool,
        minutesBefore: @escaping @MainActor () -> Int,
        lastDetectorOffer: @escaping @MainActor () -> Date?,
        openMeetings: @escaping @MainActor () -> Void,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.toasts = toasts
        self.events = events
        self.isEnabled = isEnabled
        self.minutesBefore = minutesBefore
        self.lastDetectorOffer = lastDetectorOffer
        self.openMeetings = openMeetings
        self.now = now
    }

    // MARK: Lifecycle

    /// Starts the checks. Idempotent. Only from `startServices()`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One check (the loop's body; tests call it directly).
    func tick() {
        guard isEnabled() else { return }
        let upcoming = events()
        guard !upcoming.isEmpty else { return }
        // The meeting that records is most likely this one; the toast would only get in the way.
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        let at = now()
        let lead = TimeInterval(max(0, minutesBefore())) * 60
        let detectorOffered = lastDetectorOffer().map { abs(at.timeIntervalSince($0)) < Self.detectorQuiet } ?? false
        for event in upcoming where event.hasCallLink && !event.isAllDay && !reminded.contains(event.id) {
            let untilStart = event.start.timeIntervalSince(at)
            guard untilStart <= lead, untilStart >= -Self.graceAfterStart else { continue }
            reminded.insert(event.id)
            if detectorOffered {
                Log.calendar.info("Calendar reminder skipped: the detector offered a call just now")
                continue
            }
            show(event, at: at)
        }
    }

    // MARK: Toast

    private func show(_ event: CalendarEvent, at: Date) {
        Log.calendar.info("Calendar reminder \(Self.minutesLeft(until: event.start, now: at), privacy: .public) min before an event")
        toasts.showAction(message: Self.message(for: event, now: at), buttonTitle: String(localized: "Nagraj")) { [weak self] in
            self?.record(event)
        }
    }

    private func record(_ event: CalendarEvent) {
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        // Spotkania first: a meeting never records without its live bar on screen.
        openMeetings()
        let recorder = self.recorder
        Task { await recorder.start(event: event) }
    }

    /// "Za 2 min: „Budżet Q4” (Meet). Nagrać notatki?" before the start, "Zaczyna się: „Budżet
    /// Q4” (Meet). Nagrać notatki?" from the start on. An event without a title gets the
    /// recorder's default name.
    nonisolated static func message(for event: CalendarEvent, now: Date) -> String {
        let app = event.callApp ?? ""
        let title = event.title.isEmpty ? MeetingRecorder.defaultTitle(appName: event.callApp, date: event.start) : event.title
        let minutes = minutesLeft(until: event.start, now: now)
        if minutes > 0 {
            return String(localized: "Za \(minutes) min: „\(title)” (\(app)). Nagrać notatki?")
        }
        return String(localized: "Zaczyna się: „\(title)” (\(app)). Nagrać notatki?")
    }

    /// Whole minutes until `start`, rounded up; 0 once it has started.
    nonisolated static func minutesLeft(until start: Date, now: Date) -> Int {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 60).rounded(.up))
    }
}
