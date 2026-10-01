import SwiftUI

/// "Spotkania" in Ustawienia, right after "Nagrywanie": meeting detection, the consent reminder,
/// how long the track files stay ("Zachowuj nagrania spotkań"; transcripts and notes always
/// stay), the system audio check and, in debug builds only, "Tryb Pro (dev)", which stands in
/// for a licence until accounts exist.
@MainActor
struct MeetingsSettingsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        GlassPanel(spacing: 4) {
            GlassSectionHeader("Spotkania", systemImage: "person.2.wave.2")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.top, 2)
                .padding(.bottom, 4)
            GlassToggleRow(
                "Wykrywaj spotkania",
                subtitle: "Gdy aplikacja do rozmów zacznie używać mikrofonu, Captylo zapyta, czy nagrać spotkanie.",
                systemImage: "dot.radiowaves.left.and.right",
                isOn: $settings.meetingsAutoDetect
            )
            GlassToggleRow(
                "Przypominaj o poinformowaniu uczestników",
                subtitle: "Na początku nagrania pokazuje gotowe zdanie do skopiowania na czat.",
                systemImage: "megaphone",
                isOn: $settings.meetingsConsentReminder
            )
            GlassRowSeparator()
                .padding(.vertical, 6)
            GlassRow(
                "Zachowuj nagrania spotkań",
                subtitle: "Dotyczy tylko plików audio; transkrypcje i notatki zostają.",
                systemImage: "trash"
            ) {
                GlassSegmentedPicker(selection: $settings.meetingAudioRetention, title: { $0.title })
                    .accessibilityLabel(Text("Zachowuj nagrania spotkań"))
            }
            GlassRowSeparator()
                .padding(.vertical, 6)
            SystemAudioCheckRow(
                recorder: appState.meetingRecorder,
                isDesignPreview: appState.isDesignPreview
            )
            #if DEBUG
            GlassRowSeparator()
                .padding(.vertical, 6)
            GlassToggleRow(
                "Tryb Pro (dev)",
                subtitle: "Tylko w wersji deweloperskiej: włącza notatki AI i rozpoznawanie mówców bez konta.",
                systemImage: "hammer",
                isOn: $settings.devPro
            )
            #endif
        }
    }
}

// MARK: - System audio check

/// "Dostęp do dźwięku systemu" with "Sprawdź": listens to the system audio tap for two seconds
/// (`SystemAudioCheck`) and says "Działa", "Brak dostępu" (with the way to System Settings) or
/// asks to play something first. Off while a meeting records: that tap already reports trouble
/// in the live bar.
@MainActor
private struct SystemAudioCheckRow: View {
    let recorder: MeetingRecorder
    let isDesignPreview: Bool

    private enum Phase: Equatable {
        case idle
        case checking
        case done(SystemAudioCheck.Outcome)
    }

    @State private var phase: Phase = .idle

    private var recorderBusy: Bool { recorder.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassRow(
                "Dostęp do dźwięku systemu",
                subtitle: "Tak Captylo słyszy rozmówców. Puść coś (np. film) i sprawdź.",
                systemImage: "hifispeaker"
            ) {
                HStack(spacing: 10) {
                    badge
                    Button("Sprawdź") {
                        check()
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .disabled(phase == .checking || recorderBusy)
                    .accessibilityLabel(Text("Sprawdź dostęp do dźwięku systemu"))
                }
            }
            status
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                .padding(.bottom, 4)
        }
        .onAppear {
            // `CAPTYLO_PREVIEW_AUDIO_CHECK`: the design preview shows a result without a tap.
            if isDesignPreview, phase == .idle, let outcome = DesignPreviewData.audioCheckOutcome() {
                phase = .done(outcome)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textPrimary)
        case .done(.works):
            GlassBadge("Działa", systemImage: "checkmark", tone: .success)
        case .done(.noAccess):
            GlassBadge("Brak dostępu", systemImage: "speaker.slash", tone: .warning)
        case .idle, .done(.nothingPlaying), .done(.failed):
            EmptyView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            if recorderBusy {
                ToolStatusLine(text: String(localized: "Sprawdzisz po zakończeniu nagrywania spotkania."))
            }
        case .checking:
            ToolStatusLine(text: String(localized: "Słucham dźwięku systemu przez 2 sekundy..."))
        case .done(.works):
            ToolStatusLine(text: String(localized: "Captylo słyszy dźwięk innych aplikacji."), tone: .success)
        case .done(.noAccess):
            HStack(spacing: 10) {
                ToolStatusLine(
                    text: String(localized: "Coś gra, a Captylo słyszy ciszę. Zezwól na nagrywanie dźwięku systemu i sprawdź ponownie."),
                    tone: .error
                )
                Button("Otwórz Ustawienia systemowe") {
                    SystemAudioPermission.openSettings()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .done(.nothingPlaying):
            ToolStatusLine(text: String(localized: "Puść coś na chwilę (np. film) i sprawdź ponownie."))
        case .done(.failed(let message)):
            ToolStatusLine(text: message, tone: .error)
        }
    }

    private func check() {
        guard phase != .checking, !recorderBusy, !isDesignPreview else { return }
        phase = .checking
        Task {
            let outcome = await SystemAudioCheck.run(
                source: SystemAudioTap(),
                expectingAudio: { CoreAudioProcesses.anyOtherProcessPlaying() }
            )
            phase = .done(outcome)
        }
    }
}
