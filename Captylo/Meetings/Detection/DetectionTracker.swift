import Foundation

/// Mic-in-use signal -> "a call started" / "a call ended", with hysteresis.
///
/// An app is in a call once it has held the mic in every poll for `startAfter` seconds (a voice
/// message or a quick test is not a call); the call ends when the app has not held it for
/// `endAfter` seconds (a muted participant or a short reconnect is not the end). Each started
/// app ends at most once; using the mic again after that is a new call. Apps are told apart by
/// name, so two helper processes of one app are one app.
struct DetectionTracker: Sendable {
    enum Event: Equatable, Sendable {
        case started(MeetingApp)
        case ended(MeetingApp)
    }

    private struct Entry: Sendable {
        let app: MeetingApp
        var firstSeen: Double
        var lastSeen: Double
        var started = false
    }

    let startAfter: Double
    let endAfter: Double
    private var entries: [String: Entry] = [:]

    init(startAfter: Double = 5, endAfter: Double = 45) {
        self.startAfter = startAfter
        self.endAfter = endAfter
    }

    /// One poll: the apps holding the mic at `time` (seconds on a monotonic clock).
    mutating func update(apps: [MeetingApp], at time: Double) -> [Event] {
        var events: [Event] = []
        let present = Set(apps.map(\.name))
        for app in apps {
            guard var entry = entries[app.name] else {
                entries[app.name] = Entry(app: app, firstSeen: time, lastSeen: time)
                continue
            }
            entry.lastSeen = time
            if !entry.started, time - entry.firstSeen >= startAfter {
                entry.started = true
                events.append(.started(entry.app))
            }
            entries[app.name] = entry
        }
        // Oldest call first, so two calls ending in one poll come out in a stable order.
        let absent = entries.values
            .filter { !present.contains($0.app.name) }
            .sorted { ($0.firstSeen, $0.app.name) < ($1.firstSeen, $1.app.name) }
        for entry in absent {
            if !entry.started {
                // Not held long enough to count: the next use starts the count again.
                entries[entry.app.name] = nil
            } else if time - entry.lastSeen >= endAfter {
                events.append(.ended(entry.app))
                entries[entry.app.name] = nil
            }
        }
        return events
    }
}
