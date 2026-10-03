import SwiftUI

/// "Spotkania" in Ustawienia, right after "Nagrywanie": meeting detection, the consent reminder,
/// the calendar ("Kalendarz" and "Przypominaj przed spotkaniem", Free), how long the track files
/// stay ("Zachowuj nagrania spotkań"; transcripts and notes always stay), "Dostęp dla asystentów
/// AI (MCP)" (`MCPSettingsRow`, Free, off by default), the system audio check,
/// "Redukcja echa (eksperymentalna)" (voice processing on the mic, read at the next meeting start)
/// and, in debug builds only, "Tryb Pro (dev)", which stands in for a licence until accounts exist.
@MainActor
struct MeetingsSettingsPanel: View {
    @Environment(AppState.self) private var appState

    /// Why the calendar cannot be read in this access state, with the way to System Settings
    /// next to it; nil when it can (or the system prompt is still to come).
    nonisolated static func calendarStatusText(for access: CalendarAccess) -> String? {
        switch access {
        case .fullAccess, .notDetermined:
            return nil
        case .denied, .restricted:
            return String(localized: "Brak dostępu do kalendarza. Zezwól w Ustawieniach systemowych.")
        case .writeOnly:
            return String(localized: "Captylo ma tylko dostęp do zapisu. Włącz pełny dostęp.")
        }
    }

    /// The "Przypominaj przed spotkaniem" segments: "W chwili startu", "1 min", "2 min", "5 min".
    nonisolated static func reminderMinutesTitle(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "W chwili startu") : String(localized: "\(minutes) min")
    }

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
            GlassToggleRow(
                "Skrót \(GlobalShortcut.meeting.display)",
                subtitle: "Zaczyna i kończy nagrywanie spotkania z każdej aplikacji.",
                systemImage: "command",
                isOn: $settings.meetingsShortcut
            )
            CalendarSettings(settings: settings, calendar: appState.meetingCalendar)
            GlassRowSeparator()
                .padding(.vertical, 6)
            MeetingTranscriptSettings(settings: settings, models: appState.openRouterModels, isPro: appState.proAccess.isPro)
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
            MCPSettingsRow(settings: settings)
            GlassRowSeparator()
                .padding(.vertical, 6)
            SystemAudioCheckRow(
                recorder: appState.meetingRecorder,
                isDesignPreview: appState.isDesignPreview
            )
            GlassToggleRow(
                "Redukcja echa (eksperymentalna)",
                subtitle: "Próbuje usunąć z Twojego mikrofonu to, co słychać z głośników. Zmiana działa od następnego spotkania; z niektórymi słuchawkami Bluetooth się nie włącza.",
                systemImage: "waveform.badge.minus",
                isOn: $settings.meetingsVoiceProcessing
            )
            #if DEBUG
            GlassRowSeparator()
                .padding(.vertical, 6)
            GlassToggleRow(
                "Tryb Pro (dev)",
                subtitle: "Tylko w wersji deweloperskiej: włącza bez konta notatki AI, rozpoznawanie mówców, transkrypt z chmury i poprawki AI.",
                systemImage: "hammer",
                isOn: $settings.devPro
            )
            #endif
        }
    }
}

// MARK: - Calendar

/// "Kalendarz" (names the meeting after the event, keeps the participants, reminds before a
/// call) and "Przypominaj przed spotkaniem" with the minutes picker. Turning the calendar on
/// asks for full access when the user has not decided yet; a denied, restricted or write-only
/// grant is explained under the row with "Otwórz Ustawienia systemowe". The reminder row is off
/// while the calendar is. Free: it only reads the user's own calendar.
@MainActor
private struct CalendarSettings: View {
    @Bindable var settings: AppSettings
    let calendar: MeetingCalendar

    var body: some View {
        GlassToggleRow(
            "Kalendarz",
            subtitle: "Nazywa spotkanie po wydarzeniu, zapisuje uczestników i przypomina o nagraniu.",
            systemImage: "calendar",
            isOn: calendarSwitch
        )
        if settings.meetingsCalendar, let text = MeetingsSettingsPanel.calendarStatusText(for: calendar.access) {
            HStack(alignment: .center, spacing: 10) {
                ToolStatusLine(text: text, tone: .error)
                Button("Otwórz Ustawienia systemowe") {
                    CalendarAccess.openSettings()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .fixedSize()
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            .padding(.bottom, 4)
        } else if settings.meetingsCalendar, calendar.access.isGranted {
            HStack(alignment: .center, spacing: 10) {
                ToolStatusLine(text: String(localized: "Captylo widzi kalendarze z aplikacji Kalendarz. Google lub Outlooka dodasz w Kontach internetowych macOS."))
                Button("Konta internetowe") {
                    CalendarAccess.openInternetAccounts()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .fixedSize()
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            .padding(.bottom, 4)
        }
        GlassRow(
            "Przypominaj przed spotkaniem",
            subtitle: "Pokazuje „Nagraj” przed wydarzeniem z linkiem do rozmowy.",
            systemImage: "bell"
        ) {
            HStack(spacing: 12) {
                GlassSegmentedPicker(
                    selection: $settings.meetingsCalendarReminderMinutes,
                    segments: AppSettings.calendarReminderMinuteOptions.map {
                        GlassSegment($0, title: Text(verbatim: MeetingsSettingsPanel.reminderMinutesTitle($0)))
                    }
                )
                .disabled(!settings.meetingsCalendarReminder)
                .accessibilityLabel(Text("Przypominaj przed spotkaniem"))
                Toggle(isOn: $settings.meetingsCalendarReminder) {
                    Text("Przypominaj przed spotkaniem")
                }
                .toggleStyle(.glassSwitch)
                .labelsHidden()
            }
        }
        .disabled(!settings.meetingsCalendar)
        .opacity(settings.meetingsCalendar ? 1 : 0.55)
    }

    /// The switch itself. On: asks for access (the system prompt, the first time) or re-reads
    /// it, then reads the events. Off: only a refresh, which clears the events; never a prompt.
    private var calendarSwitch: Binding<Bool> {
        Binding(
            get: { settings.meetingsCalendar },
            set: { isOn in
                settings.meetingsCalendar = isOn
                let calendar = self.calendar
                Task {
                    if isOn {
                        await calendar.requestAccess()
                    } else {
                        await calendar.refresh()
                    }
                }
            }
        )
    }
}

// MARK: - Transcript after the meeting

/// Pro: "Dokładniejszy transkrypt z chmury", "Poprawiaj transkrypt przez AI" and "Model AI do
/// spotkań" (the fixes and the AI notes; "Jak w Modelach" by default, quick picks below). In Free
/// the switches are off and say it is Pro.
@MainActor
private struct MeetingTranscriptSettings: View {
    @Bindable var settings: AppSettings
    let models: OpenRouterModels
    let isPro: Bool

    var body: some View {
        GlassToggleRow(
            "Dokładniejszy transkrypt z chmury",
            subtitle: "Po spotkaniu wysyła nagranie do chmury i zastępuje nim transkrypt z Maca. Potrzebny klucz chmury w Modelach.",
            systemImage: "cloud",
            isOn: proBinding($settings.meetingsCloudTranscript)
        )
        .disabled(!isPro)
        GlassToggleRow(
            "Poprawiaj transkrypt przez AI",
            subtitle: "Po spotkaniu AI poprawia źle rozpoznane słowa, nazwy i interpunkcję. Niczego nie skraca, a oryginał da się przywrócić.",
            systemImage: "wand.and.stars",
            isOn: proBinding($settings.meetingsAICorrection)
        )
        .disabled(!isPro)
        GlassRow(
            title: Text("Model AI do spotkań"),
            subtitle: Text(verbatim: selectionTitle),
            systemImage: "brain"
        ) {
            Menu {
                Button {
                    settings.meetingsAIModel = ""
                } label: {
                    choiceLabel(Text("Jak w Modelach (\(name(of: settings.aiModel)))"), selected: settings.meetingsAIModel.isEmpty)
                }
                Divider()
                ForEach(choices, id: \.self) { id in
                    Button {
                        settings.meetingsAIModel = id
                    } label: {
                        choiceLabel(Text(verbatim: name(of: id)), selected: settings.meetingsAIModel == id)
                    }
                }
            } label: {
                MeetingMenuLabel(title: Text("Zmień"), systemImage: "slider.horizontal.3")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Model AI do spotkań"))
        }
        .task {
            await models.refresh()
        }
        if !isPro {
            ToolStatusLine(text: String(localized: "Transkrypt z chmury i poprawki AI są w Captylo Pro."))
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                .padding(.bottom, 4)
        }
    }

    /// The cheapest quick pick first (long transcripts), then the rest, plus a custom choice.
    private var choices: [String] {
        var ids = [Self.cheapModelID] + OpenRouterModel.quickPickIDs.filter { $0 != Self.cheapModelID }
        if !settings.meetingsAIModel.isEmpty, !ids.contains(settings.meetingsAIModel) {
            ids.append(settings.meetingsAIModel)
        }
        return ids
    }

    static let cheapModelID = "google/gemini-2.5-flash-lite"

    private var selectionTitle: String {
        settings.meetingsAIModel.isEmpty
            ? String(localized: "Jak w Modelach (\(name(of: settings.aiModel)))")
            : name(of: settings.meetingsAIModel)
    }

    private func name(of id: String) -> String {
        models.models.first { $0.id == id }?.name ?? id
    }

    private func choiceLabel(_ title: Text, selected: Bool) -> some View {
        Label {
            title
        } icon: {
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    /// Free shows the switch off whatever is stored.
    private func proBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { isPro && binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
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
