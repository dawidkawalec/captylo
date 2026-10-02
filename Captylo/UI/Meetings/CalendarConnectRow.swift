import SwiftUI

/// Makes the calendar findable from Spotkania (the switch alone sits deep in Ustawienia and is off
/// by default). Calendar off and not dismissed, or on while macOS has not answered yet: "Połącz
/// kalendarz" with "Połącz" (turns it on and asks for access) and "Nie teraz" (turns it off).
/// Calendar on without full access: why the events are missing, with "Otwórz Ustawienia
/// systemowe". Nothing while the calendar works.
@MainActor
struct CalendarConnectRow: View {
    enum Kind: Equatable {
        case connect
        case noAccess(String)
    }

    let kind: Kind
    var onConnect: () -> Void = {}
    var onDismiss: () -> Void = {}

    /// What the row shows, or nil for no row.
    nonisolated static func kind(isOn: Bool, dismissed: Bool, access: CalendarAccess) -> Kind? {
        if !isOn {
            return dismissed ? nil : .connect
        }
        // On, but the prompt never came back with an answer: keep "Połącz" so it can be retried
        // instead of hiding the row while nothing is connected.
        if access == .notDetermined {
            return .connect
        }
        return MeetingsSettingsPanel.calendarStatusText(for: access).map(Kind.noAccess)
    }

    var body: some View {
        GlassCard(style: .inset, padding: 12, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GlassColor.accent)
                    .accessibilityHidden(true)
                text
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
        }
    }

    @ViewBuilder
    private var text: some View {
        switch kind {
        case .connect:
            Text("Połącz kalendarz: spotkania dostaną tytuły i uczestników z wydarzeń, a przed rozmową przypomnę o nagraniu.")
        case .noAccess(let message):
            Text(verbatim: message)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch kind {
        case .connect:
            HStack(spacing: 8) {
                Button("Nie teraz", action: onDismiss)
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                Button("Połącz", action: onConnect)
                    .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            }
            .fixedSize()
        case .noAccess:
            Button("Otwórz Ustawienia systemowe") {
                CalendarAccess.openSettings()
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .fixedSize()
        }
    }
}
