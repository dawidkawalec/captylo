import SwiftUI

/// "Aktualizacje" in Ustawienia > Aplikacja: the version with its build number, "Sprawdź teraz"
/// (Sparkle's own windows) and Sparkle's automatic-check switch. Without a configured updater
/// (development builds, the design preview, until the public key is in place) only a line that
/// updates come with the public version, no controls.
@MainActor
struct UpdatesRow: View {
    let updater: AppUpdater

    var body: some View {
        if updater.isConfigured {
            @Bindable var updater = updater
            GlassRow(
                title: Text("Aktualizacje"),
                subtitle: Text(verbatim: updater.versionLine),
                systemImage: "arrow.down.circle"
            ) {
                Button("Sprawdź teraz") {
                    updater.checkNow()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(updater.isChecking)
            }
            GlassToggleRow(
                "Sprawdzaj automatycznie",
                systemImage: "clock.arrow.2.circlepath",
                isOn: $updater.automaticChecks
            )
        } else {
            GlassRow(
                title: Text("Aktualizacje"),
                subtitle: Text("Aktualizacje będą dostępne w wersji publicznej."),
                systemImage: "arrow.down.circle"
            ) {
                EmptyView()
            }
        }
    }
}
