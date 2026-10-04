import EventKit
import Foundation

/// The user's real calendars through EventKit. Reads run on a utility queue (a big calendar
/// takes hundreds of milliseconds) and only plain `CalendarEvent` values come back; `EKEvent`
/// objects never leave the queue. Nothing about an event is logged, only counts.
final class EventKitSource: CalendarEventSource, @unchecked Sendable {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "com.captylo.app.calendar", qos: .utility)

    func access() -> CalendarAccess {
        CalendarAccess.current()
    }

    /// `requestFullAccessToEvents` is the only prompt that gives read access on macOS 14.
    func requestAccess() async -> CalendarAccess {
        guard access() == .notDetermined else { return access() }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Log.calendar.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
        }
        let result = access()
        if result == .notDetermined {
            // What a missing calendars entitlement looks like under Hardened Runtime.
            Log.calendar.error("Calendar access request ended without a prompt")
        }
        return result
    }

    func events(from: Date, to: Date) async -> [CalendarEvent] {
        guard access().isGranted else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
                let events = store.events(matching: predicate)
                    .filter { !$0.isAllDay }
                    .compactMap(Self.calendarEvent)
                    .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                Log.calendar.debug("Calendar read: \(events.count) events in the window")
                continuation.resume(returning: events)
            }
        }
    }

    var changes: AsyncStream<Void> {
        AsyncStream { [self] continuation in
            nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: nil
            ) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    // MARK: Mapping

    private static func calendarEvent(_ event: EKEvent) -> CalendarEvent? {
        guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate else {
            return nil
        }
        return CalendarEvent(
            id: id,
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "",
            participants: participants(of: event),
            callApp: CallLinkDetector.app(url: event.url, location: event.location, notes: event.notes)
        )
    }

    /// Display names of the people invited: the organizer first, then the attendees in the
    /// invite's order, without the user, rooms and resources, duplicates, or empty names.
    private static func participants(of event: EKEvent) -> [String] {
        var names: [String] = []
        func add(_ participant: EKParticipant?) {
            guard let participant, !participant.isCurrentUser,
                  participant.participantType == .person || participant.participantType == .unknown,
                  let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !names.contains(name)
            else { return }
            names.append(name)
        }
        add(event.organizer)
        for attendee in event.attendees ?? [] {
            add(attendee)
        }
        return Array(names.prefix(CalendarEvent.maxParticipants))
    }
}
