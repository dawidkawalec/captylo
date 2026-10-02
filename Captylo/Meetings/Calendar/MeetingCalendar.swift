import Foundation
import Observation

/// The notetaker's view of the user's calendar: the permission state and the events from
/// `lookBehind` ago to `lookAhead` ahead, refreshed every `refreshInterval`, on every calendar
/// change and on demand. Reads happen only while "Kalendarz" is on and full access is granted;
/// with the setting off the cached events are not used either, so nothing from the calendar
/// reaches a recording the user did not ask to link. Calendar features are Free.
@MainActor
@Observable
final class MeetingCalendar {
    nonisolated static let lookBehind: TimeInterval = 15 * 60
    nonisolated static let lookAhead: TimeInterval = 12 * 60 * 60
    nonisolated static let refreshInterval: Duration = .seconds(5 * 60)

    private(set) var access: CalendarAccess
    /// Events in the window, sorted by start, all-day events left out. Empty while off.
    private(set) var upcoming: [CalendarEvent] = []
    /// When `upcoming` was last read; nil until the first read.
    private(set) var refreshedAt: Date?

    @ObservationIgnored private let source: any CalendarEventSource
    /// The "Kalendarz" setting, read on every use.
    @ObservationIgnored private let isOn: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var changeWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - source: the calendar; the app passes `EventKitSource`, tests and the design preview a fake.
    ///   - isOn: `settings.meetingsCalendar`.
    ///   - now: the clock, replaced in tests.
    init(
        source: any CalendarEventSource,
        isOn: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.source = source
        self.isOn = isOn
        self.now = now
        access = source.access()
    }

    /// The setting is on and the calendar can be read.
    var isEnabled: Bool { isOn() && access.isGranted }

    /// Shows the system prompt when the user has not decided yet, otherwise re-reads the
    /// permission (the user may have changed it in System Settings), then refreshes.
    func requestAccess() async {
        if access == .notDetermined {
            access = await source.requestAccess()
        } else {
            access = source.access()
        }
        Log.calendar.info("Calendar access: \(String(describing: self.access), privacy: .public)")
        await refresh()
    }

    /// Re-reads the permission and, when enabled, the events in the window.
    func refresh() async {
        access = source.access()
        guard isEnabled else {
            upcoming = []
            return
        }
        let at = now()
        let events = await source.events(from: at.addingTimeInterval(-Self.lookBehind), to: at.addingTimeInterval(Self.lookAhead))
        // Switched off while the read ran.
        guard isEnabled else {
            upcoming = []
            return
        }
        upcoming = events.filter { !$0.isAllDay }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        refreshedAt = at
    }

    /// The event a recording starting at `date` belongs to (`CalendarEventMatcher`), nil while off.
    func currentEvent(at date: Date = Date()) -> CalendarEvent? {
        guard isEnabled else { return nil }
        return CalendarEventMatcher.match(upcoming, at: date)
    }

    // MARK: Lifecycle

    /// Starts the refresh loop and the change watch. Idempotent. Only from `startServices()`:
    /// the design preview and the test host never reach the real calendar.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        let changes = source.changes
        changeWatch = Task { [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        changeWatch?.cancel()
        changeWatch = nil
    }
}
