import AppKit
import SwiftUI

/// "Ustawienia": grouped Dusk Glass panels of rows and blue switches (mockup 03) in two tabs
/// (`SettingsLevel`). "Podstawowe": the Captylo account first (`AccountSettingsPanel`, the target
/// of `openAccount()`, which switches back to this tab), the shortcut recorder as a glass keycap,
/// the window background, microphone and recording toggles, meetings (`MeetingsSettingsPanel`),
/// history and learning (privacy stays one click away), login item, updates (`UpdatesRow`).
/// "Zaawansowane": the tone sliders, system mute, the rest of meetings, pasting, learning
/// details, onboarding reset. The version footer closes both.
@MainActor
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var level: SettingsLevel = .basic

    var body: some View {
        ToolPage {
            SettingsLevelPicker(level: $level)
        } content: {
            switch level {
            case .basic: basic
            case .advanced: advanced
            }
            VersionFooter(versionLine: appState.updater.versionLine)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .onAppear {
            appState.launchAtLogin.refresh()
            appState.audioDevices.refresh()
            showAnchoredTab()
        }
        .onChange(of: appState.windowPresenter.settingsAnchor) {
            showAnchoredTab()
        }
    }

    /// The anchored panels (`SettingsAnchor`) live in "Podstawowe".
    private func showAnchoredTab() {
        if appState.windowPresenter.settingsAnchor != nil {
            level = .basic
        }
    }

    @ViewBuilder
    private var basic: some View {
        @Bindable var settings = appState.settings

        // The reader only needs the anchored panel; its proxy scrolls the page's scroll view.
        ScrollViewReader { proxy in
            AccountSettingsPanel(account: appState.account)
                .id(SettingsAnchor.account)
                .onAppear {
                    scrollToAnchor(proxy)
                }
                .onChange(of: appState.windowPresenter.settingsAnchor) {
                    scrollToAnchor(proxy)
                }
        }

        GlassPanel(spacing: 14) {
            sectionHeader("Skrót", systemImage: "keyboard")
            VStack(alignment: .leading, spacing: 12) {
                HotkeyRecorderView(settings: settings, tap: appState.hotkeyTap)
                ToolCaption("Krótkie naciśnięcie włącza dyktowanie do następnego naciśnięcia. Przytrzymanie nagrywa tak długo, jak trzymasz klawisz. Esc dwa razy anuluje.")
            }
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            .padding(.bottom, 4)
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Wygląd", systemImage: "paintpalette")
            GlassRow("Tło okna", subtitle: "Ciemny i Jasny to ruchomy gradient w kolorach marki, Zmierzch to żywe jezioro o zachodzie słońca, a Gradient to spokojne niebo.", systemImage: "macwindow.on.rectangle") {
                GlassSegmentedPicker(
                    selection: $settings.windowBackground,
                    segments: WindowBackgroundStyle.pickerOrder.map {
                        GlassSegment($0, $0.title, systemImage: $0.systemImage)
                    }
                )
                .accessibilityLabel(Text("Tło okna"))
            }
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Nagrywanie", systemImage: "waveform")
            MicrophoneRow(devices: appState.audioDevices)
            if appState.audioDevices.isLidClosed {
                ToolStatusLine(text: String(localized: "Pokrywa jest zamknięta: wbudowany mikrofon jest pomijany."))
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.bottom, 6)
            }
            GlassRowSeparator()
                .padding(.vertical, 6)
            GlassToggleRow("Dźwięki", systemImage: "speaker.wave.2", isOn: $settings.sounds)
            GlassToggleRow("Podgląd na żywo", systemImage: "text.bubble", isOn: $settings.livePreview)
        }

        MeetingsSettingsPanel(level: .basic)

        // History and learning decide what stays on this Mac, so they never hide in "Zaawansowane".
        GlassPanel(spacing: 4) {
            sectionHeader("Historia", systemImage: "clock")
            GlassToggleRow("Zapisuj historię", systemImage: "clock.arrow.circlepath", isOn: $settings.saveHistory)
            RetentionRow(days: $settings.audioRetentionDays)
                .disabled(!settings.saveHistory)
                .opacity(settings.saveHistory ? 1 : 0.5)
            GlassRowSeparator()
                .padding(.vertical, 6)
            sectionHeader("Nauka", systemImage: "brain")
            GlassToggleRow(
                "Ucz się z moich poprawek",
                subtitle: "Gdy przeliterujesz słowo na głos albo poprawisz wklejony tekst, Captylo zapamięta poprawną wersję. Wszystko zostaje na tym Macu, a nauczone słowa zobaczysz i cofniesz w Słowniku.",
                systemImage: "sparkles",
                isOn: $settings.learningEnabled
            )
            GlassToggleRow(
                "Popraw zaznaczony tekst: \(GlobalShortcut.correction.display)",
                subtitle: "Zaznacz źle rozpoznane słowo w dowolnej aplikacji, naciśnij skrót i wpisz poprawną wersję. Captylo podmieni tekst i od razu się tego nauczy. Działa też z menu prawego przycisku: Usługi > Popraw w Captylo.",
                systemImage: "pencil.and.scribble",
                isOn: $settings.learningFixShortcut
            )
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Aplikacja", systemImage: "macwindow")
            AppLanguageRow(appState: appState)
            GlassToggleRow("Ukryj ikonę w Docku", systemImage: "dock.rectangle", isOn: $settings.menuBarOnly)
            LaunchAtLoginRow(launchAtLogin: appState.launchAtLogin)
            GlassRowSeparator()
                .padding(.vertical, 6)
            UpdatesRow(updater: appState.updater)
        }
    }

    @ViewBuilder
    private var advanced: some View {
        @Bindable var settings = appState.settings

        GlassPanel(spacing: 4) {
            sectionHeader("Wygląd", systemImage: "paintpalette")
            ToneSliderRow(
                title: "Przyciemnienie tła",
                subtitle: "Ciemniejsze tło za panelami. Domyślnie 10%.",
                systemImage: "circle.lefthalf.filled",
                value: $settings.backgroundDim,
                range: WindowTone.backgroundDimRange
            )
            ToneSliderRow(
                title: "Przydymienie paneli",
                subtitle: "Ciemniejsze szkło paneli i paska bocznego. Domyślnie 20%.",
                systemImage: "square.stack",
                value: $settings.panelSmoke,
                range: WindowTone.panelSmokeRange
            )
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Nagrywanie", systemImage: "waveform")
            GlassToggleRow("Wycisz system podczas nagrywania", systemImage: "speaker.slash", isOn: $settings.muteWhileRecording)
        }

        MeetingsSettingsPanel(level: .advanced)

        GlassPanel(spacing: 4) {
            sectionHeader("Wklejanie", systemImage: "text.cursor")
            GlassToggleRow("Przywracaj schowek", systemImage: "doc.on.clipboard", isOn: $settings.restoreClipboard)
            GlassToggleRow("Spacja po wklejeniu", systemImage: "space", isOn: $settings.trailingSpace)
            GlassToggleRow("Akapity", systemImage: "text.alignleft", isOn: $settings.paragraphs)
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Nauka", systemImage: "brain")
            Group {
                GlassToggleRow("Pokazuj powiadomienia o nauce", systemImage: "bell", isOn: $settings.learningNotifications)
                GlassRowSeparator()
                    .padding(.vertical, 6)
                ExcludedAppsRow(settings: settings)
            }
            .disabled(!settings.learningEnabled)
            .opacity(settings.learningEnabled ? 1 : 0.5)
            if !settings.learningEnabled {
                ToolStatusLine(text: String(localized: "Nauka jest wyłączona w zakładce Podstawowe."))
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.bottom, 4)
            }
        }

        GlassPanel(spacing: 4) {
            sectionHeader("Aplikacja", systemImage: "macwindow")
            OnboardingResetRow(settings: settings)
        }
    }

    /// `openAccount()` (deep links, "Zobacz Pro"): scrolls to the panel once, then forgets it.
    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = appState.windowPresenter.settingsAnchor else { return }
        appState.windowPresenter.settingsAnchor = nil
        withAnimation(GlassMotion.spring) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    /// Section title of a panel: semibold white with a line icon, like "Transkrypcja na żywo" in
    /// mockup 03 (not the small uppercase label of a system grouped form).
    private func sectionHeader(_ key: LocalizedStringKey, systemImage: String) -> some View {
        GlassSectionHeader(key, systemImage: systemImage)
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }
}

// MARK: - Microphone

@MainActor
private struct MicrophoneRow: View {
    let devices: AudioDevices

    /// A saved device that is not plugged in right now still needs a tag, or the picker goes blank.
    private var missingSelection: AudioInputSelection? {
        let selection = devices.selection
        guard case .device(let uid, _) = selection, !devices.inputs.contains(where: { $0.uid == uid }) else { return nil }
        return selection
    }

    private var selectionName: String {
        switch devices.selection {
        case .systemDefault:
            return String(localized: "Domyślny systemowy")
        case .device(let uid, _):
            return devices.inputs.first { $0.uid == uid }?.name ?? String(localized: "Zapisany mikrofon (niepodłączony)")
        }
    }

    private var subtitle: Text? {
        devices.resolveInput().map { Text("Teraz nagrywa: \($0.name)") }
    }

    var body: some View {
        GlassRow(title: Text("Mikrofon"), subtitle: subtitle, systemImage: "mic") {
            GlassMenuValue(selectionName) {
                Picker("Mikrofon", selection: Binding(
                    get: { devices.selection },
                    set: { devices.selection = $0 }
                )) {
                    Text("Domyślny systemowy").tag(AudioInputSelection.systemDefault)
                    ForEach(devices.inputs) { input in
                        Text(verbatim: input.name).tag(AudioInputSelection.device(uid: input.uid, modelUID: input.modelUID))
                    }
                    if let missingSelection {
                        Text("Zapisany mikrofon (niepodłączony)").tag(missingSelection)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Mikrofon"))
            .accessibilityValue(Text(verbatim: selectionName))
        }
    }
}

// MARK: - Retention

@MainActor
/// "Przyciemnienie tła" / "Przydymienie paneli": a glass slider in whole percent with the value
/// next to it. Windows follow live (`\.windowTone`).
private struct ToneSliderRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        GlassRow(title, subtitle: subtitle, systemImage: systemImage) {
            HStack(spacing: 10) {
                GlassSlider(value: $value, range: range)
                    .frame(width: 160)
                    .accessibilityLabel(Text(title))
                Text(verbatim: "\(value)%")
                    .font(GlassFont.body.monospacedDigit())
                    .foregroundStyle(GlassColor.textSecondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct RetentionRow: View {
    static let options: [Int] = [0, 7, 14, 30, 90]

    @Binding var days: Int

    private func label(_ value: Int) -> String {
        value == 0 ? String(localized: "Nigdy") : String(localized: "\(value) dniach")
    }

    var body: some View {
        GlassRow(
            title: Text("Usuwaj nagrania po"),
            subtitle: Text("Dotyczy tylko plików audio; teksty i statystyki zostają."),
            systemImage: "trash"
        ) {
            GlassMenuValue(label(days)) {
                Picker("Usuwaj nagrania po", selection: $days) {
                    ForEach(Self.options, id: \.self) { value in
                        Text(verbatim: label(value)).tag(value)
                    }
                    if !Self.options.contains(days) {
                        Text(verbatim: label(days)).tag(days)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Usuwaj nagrania po"))
            .accessibilityValue(Text(verbatim: label(days)))
        }
    }
}

// MARK: - Learning exclusions

/// Apps whose fields self-learning never reads back, picked as .app bundles. Password managers
/// and terminals are always excluded (`EditWatcher.excludedBundleIDs`) and are not listed.
@MainActor
private struct ExcludedAppsRow: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassRow("Wykluczone aplikacje", subtitle: "Captylo nie czyta tu poprawek. Menedżery haseł, terminale i pola haseł są wykluczone zawsze.", systemImage: "hand.raised") {
                Button {
                    pickApp()
                } label: {
                    Label("Dodaj aplikację", systemImage: "plus")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            if !settings.learningExcludedApps.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(settings.learningExcludedApps, id: \.self) { bundleID in
                        ToolChip(text: Self.name(of: bundleID)) {
                            settings.learningExcludedApps.removeAll { $0 == bundleID }
                        }
                    }
                }
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                .padding(.bottom, 4)
            }
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Wyklucz")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var list = settings.learningExcludedApps
        for id in ids where !list.contains(id) {
            list.append(id)
        }
        settings.learningExcludedApps = list
    }

    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - App language

/// "Język aplikacji" (`AppLanguage`): saved at once, shown after a relaunch. The relaunch waits
/// while a dictation or a meeting records, so switching never cuts one off.
@MainActor
private struct AppLanguageRow: View {
    let appState: AppState
    @State private var choice = AppLanguage.preference()

    private var isRecording: Bool { appState.isRecordingAnything }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassRow(title: Text("Język aplikacji"), systemImage: "character.bubble") {
                GlassMenuValue(choice.title()) {
                    Picker("Język aplikacji", selection: $choice) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.title()).tag(language)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel(Text("Język aplikacji"))
                .accessibilityValue(Text(verbatim: choice.title()))
            }
            .onChange(of: choice) {
                AppLanguage.setPreference(choice)
            }
            if choice.needsRelaunch() {
                HStack(spacing: 10) {
                    ToolStatusLine(text: isRecording
                        ? String(localized: "Nowy język po ponownym uruchomieniu. Najpierw zakończ nagrywanie.")
                        : String(localized: "Nowy język pojawi się po ponownym uruchomieniu Captylo."))
                    Button("Uruchom ponownie") {
                        appState.relaunchForLanguage()
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .disabled(isRecording)
                }
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
    }
}

// MARK: - Login item

@MainActor
private struct LaunchAtLoginRow: View {
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassToggleRow(
                title: Text("Uruchamiaj przy logowaniu"),
                systemImage: "power",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .disabled(launchAtLogin.isUnavailable)
            Group {
                if launchAtLogin.isUnavailable {
                    ToolStatusLine(text: String(localized: "Przenieś Captylo do folderu Programy, aby włączyć tę opcję."))
                } else if launchAtLogin.requiresApproval {
                    HStack(spacing: 10) {
                        ToolStatusLine(text: String(localized: "macOS czeka na Twoją zgodę w Ustawieniach systemowych > Ogólne > Logowanie."))
                        Button("Otwórz") {
                            launchAtLogin.openSystemSettings()
                        }
                        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    }
                } else if let error = launchAtLogin.lastError {
                    ToolStatusLine(text: error, tone: .error)
                }
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
    }
}

// MARK: - Onboarding

@MainActor
private struct OnboardingResetRow: View {
    @Bindable var settings: AppSettings

    var body: some View {
        GlassRow(
            title: Text("Uruchom wprowadzenie ponownie"),
            subtitle: Text("Wprowadzenie pokaże się przy następnym uruchomieniu."),
            systemImage: "arrow.counterclockwise"
        ) {
            if settings.onboardingDone {
                Button("Uruchom") {
                    settings.onboardingStep = AppSettings.defaultOnboardingStep
                    settings.onboardingDone = false
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .accessibilityLabel(Text("Uruchom wprowadzenie ponownie"))
            } else {
                GlassBadge("Zaplanowane", systemImage: "checkmark", tone: .success)
            }
        }
    }
}

// MARK: - Footer

@MainActor
private struct VersionFooter: View {
    /// "Wersja 1.0.0 (142)" (`AppUpdaterConfiguration.versionLine`).
    let versionLine: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Captylo")
                    .font(GlassFont.ui(13, .semibold))
                    .foregroundStyle(GlassColor.textPrimary)
                Text(verbatim: versionLine)
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
            }
            Spacer(minLength: 16)
            Text("Dane: \(AppPaths.dataDirectory.path(percentEncoded: false))")
                .font(GlassFont.ui(11))
                .foregroundStyle(GlassColor.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
    }
}
