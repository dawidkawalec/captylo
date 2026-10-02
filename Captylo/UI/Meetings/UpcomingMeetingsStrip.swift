import SwiftUI

/// "Nadchodzące" in Spotkania: up to `maxEvents` calendar events that have not ended yet, within
/// the next 12 h, soonest first (an event in progress first of all, marked "Trwa"). Each is a slim
/// glass card with the time, the title, the call service badge when the invite has a link, the
/// participants count (names in a tooltip) and "Nagraj", which starts the recorder on that event
/// (`onRecord`; nil shows the buttons disabled while a meeting records or starts).
@MainActor
struct UpcomingMeetingsStrip: View {
    nonisolated static let maxEvents = 3

    let events: [CalendarEvent]
    var now: Date = Date()
    var onRecord: ((CalendarEvent) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nadchodzące")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .glassTextShadow()
                .padding(.leading, 4)
            HStack(alignment: .top, spacing: 12) {
                // Recurring events share an id, so the card's identity is the whole event.
                ForEach(Self.visible(events, now: now), id: \.self) { event in
                    card(event)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Nadchodzące"))
    }

    private func card(_ event: CalendarEvent) -> some View {
        GlassCard(style: .inset, padding: 14, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: Self.time(event.start))
                    .font(GlassFont.ui(13, .medium).monospacedDigit())
                    .foregroundStyle(GlassColor.textSecondary)
                if Self.isInProgress(event, now: now) {
                    GlassBadge("Trwa", tone: .accent)
                }
                Spacer(minLength: 0)
                if let app = event.callApp {
                    GlassBadge(title: Text(verbatim: app), systemImage: "video")
                }
            }
            Text(verbatim: Self.title(of: event))
                .font(GlassFont.ui(14, .semibold))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                if !event.participants.isEmpty {
                    MeetingParticipantsLabel(participants: event.participants)
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    onRecord?(event)
                } label: {
                    Label("Nagraj", systemImage: "record.circle")
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                .disabled(onRecord == nil)
            }
        }
        .glassTextShadow()
    }

    // MARK: Helpers

    /// The events to show: not all-day, not over, starting within `MeetingCalendar.lookAhead`,
    /// soonest first, at most `maxEvents`.
    nonisolated static func visible(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        let horizon = now.addingTimeInterval(MeetingCalendar.lookAhead)
        return events
            .filter { !$0.isAllDay && $0.end > now && $0.start < horizon }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .prefix(maxEvents)
            .map { $0 }
    }

    nonisolated static func isInProgress(_ event: CalendarEvent, now: Date) -> Bool {
        event.start <= now
    }

    /// "14:00" in the app's locale.
    nonisolated static func time(_ date: Date, locale: Locale = AppLocale.current, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }

    /// The event's title, or the recorder's default name for an event without one.
    nonisolated static func title(of event: CalendarEvent) -> String {
        event.title.isEmpty ? MeetingRecorder.defaultTitle(appName: event.callApp, date: event.start) : event.title
    }
}
