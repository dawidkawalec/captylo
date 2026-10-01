import SwiftUI

/// Shown once per recording start while "Przypominaj o poinformowaniu uczestników" is on:
/// "Nagrywasz spotkanie. Poinformuj uczestników." with "Skopiuj informację" (the Polish and
/// English sentence of `MeetingConsent.disclosure`), "Nie pokazuj więcej" (turns the reminder
/// off) and a close button. A raised card with the Tide tint: it sits on the details panel.
@MainActor
struct MeetingConsentCard: View {
    let onCopy: () -> Void
    let onNeverShow: () -> Void
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GlassIconBadge(systemImage: "person.2.wave.2", size: 30, tint: GlassColor.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Nagrywasz spotkanie. Poinformuj uczestników.")
                    .font(GlassFont.bodyMedium)
                    .foregroundStyle(GlassColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        onCopy()
                        copied = true
                    } label: {
                        if copied {
                            Label("Skopiowano", systemImage: "checkmark")
                        } else {
                            Label("Skopiuj informację", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .help(Text(verbatim: MeetingConsent.disclosure))
                    Button("Nie pokazuj więcej", action: onNeverShow)
                        .buttonStyle(.plain)
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolIconButton("xmark", label: Text("Zamknij"), size: 26, action: onDismiss)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.raised, cornerRadius: GlassTokens.Radius.card, tint: GlassColor.accent, shadow: false)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
