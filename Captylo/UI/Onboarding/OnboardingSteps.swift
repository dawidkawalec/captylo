import AppKit
import AVFoundation
import SwiftUI

// The five onboarding screens (brief 1.1) in the Dusk Glass language. Each one reads the live
// services through the model's `AppState`; navigation, the progress track and the glass panel
// around the middle steps live in `OnboardingView`.

// MARK: - Welcome

@MainActor
struct WelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            OnboardingWordmark()

            Text("Mów, a tekst pojawia się tam, gdzie piszesz.")
                .font(GlassFont.ui(18))
                .multilineTextAlignment(.center)
                // Straight on the wallpaper over the bright horizon: primary white plus a halo.
                .foregroundStyle(GlassColor.textPrimary)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .frame(maxWidth: 460)
                .padding(.top, 10)

            OnboardingWaveform()
                .padding(.top, 28)

            Button {
                model.advance()
            } label: {
                HStack(spacing: 10) {
                    Text("Zaczynamy")
                    Image(systemName: "arrow.right")
                        .accessibilityHidden(true)
                }
                .frame(minWidth: 168)
            }
            .buttonStyle(.glass(.accent, shape: .capsule))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 30)

            Text("Konfiguracja zajmie około minuty. Wszystko działa lokalnie na tym Macu.")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .padding(.top, 16)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Permissions

@MainActor
struct PermissionsStep: View {
    let model: OnboardingModel

    private var permissions: Permissions { model.appState.permissions }
    private var oldApps: OldAppDetector { model.appState.oldAppDetector }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                symbol: OnboardingStep.permissions.symbol,
                title: String(localized: "Dwa uprawnienia"),
                subtitle: String(localized: "macOS pyta o nie raz. Bez nich Captylo nie usłyszy Cię ani nie wklei tekstu.")
            )

            GlassRowSeparator()
                .padding(.top, 20)
                .padding(.bottom, 8)

            // One group: hairlines separate groups, not every row (mockup 03).
            VStack(alignment: .leading, spacing: 10) {
                microphoneRow
                accessibilityRow
                if oldApps.isOldAppRunning {
                    oldAppRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // Accessibility is polled by the watcher; the microphone state needs its own refresh.
            permissions.refresh()
            oldApps.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                permissions.refresh()
            }
        }
    }

    private var microphoneRow: some View {
        PermissionRow(
            symbol: "mic",
            title: String(localized: "Mikrofon"),
            explanation: String(localized: "Do nagrywania Twojego głosu. Dźwięk jest przetwarzany lokalnie, nic nie wychodzi z tego Maca bez Twojej zgody."),
            status: microphoneStatus
        ) {
            switch permissions.microphone {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Button("Zezwól") {
                    Task { await permissions.requestMicrophone() }
                }
            default:
                Button("Otwórz ustawienia") {
                    permissions.openMicrophoneSettings()
                }
            }
        }
    }

    private var microphoneStatus: PermissionStatus {
        switch permissions.microphone {
        case .authorized:
            return .granted
        case .notDetermined:
            return .required(hint: nil)
        case .denied:
            return PermissionStatus(
                chip: String(localized: "Odmówiono"),
                symbol: "xmark",
                tone: .danger,
                hint: String(localized: "Włącz w Ustawieniach systemowych > Prywatność > Mikrofon.")
            )
        case .restricted:
            return PermissionStatus(
                chip: String(localized: "Zablokowane"),
                symbol: "lock",
                tone: .danger,
                hint: String(localized: "Zablokowane przez ograniczenia systemu.")
            )
        @unknown default:
            return PermissionStatus(chip: String(localized: "Nieznany stan"), symbol: nil, tone: .neutral, hint: nil)
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(
            symbol: "hand.raised",
            title: String(localized: "Dostępność"),
            explanation: String(localized: "Do globalnego skrótu i wklejania tekstu tam, gdzie piszesz. Captylo nie czyta ekranu ani innych aplikacji."),
            status: accessibilityStatus
        ) {
            if !permissions.isAccessibilityTrusted {
                if permissions.suggestsRelaunch {
                    Button("Uruchom ponownie") {
                        permissions.relaunch()
                    }
                }
                Button("Zezwól") {
                    permissions.requestAccessibility()
                }
            }
        }
    }

    private var accessibilityStatus: PermissionStatus {
        if permissions.isAccessibilityTrusted {
            return .granted
        }
        if permissions.suggestsRelaunch {
            return .required(hint: String(localized: "Nadal brak dostępu. macOS często wymaga ponownego uruchomienia aplikacji po włączeniu."))
        }
        return .required(hint: String(localized: "Po kliknięciu włącz Captylo na liście w Ustawieniach systemowych."))
    }

    private var oldAppRow: some View {
        PermissionRow(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Stara wersja aplikacji"),
            explanation: String(localized: "Uruchomiona jest stara wersja (\(oldApps.oldAppName ?? String(localized: "poprzednia aplikacja"))). Obie używają tego samego skrótu, więc nagranie i wklejenie zdarzyłyby się dwa razy."),
            status: PermissionStatus(chip: String(localized: "Uruchomiona"), symbol: "exclamationmark", tone: .warning, hint: nil)
        ) {
            Button("Zamknij starą wersję") {
                oldApps.quitOldApps()
            }
        }
    }
}

/// State of one permission as the chip on the right of its row, plus an optional hint line.
private struct PermissionStatus {
    let chip: String
    let symbol: String?
    let tone: GlassBadge.Tone
    let hint: String?

    static var granted: PermissionStatus {
        PermissionStatus(chip: String(localized: "Przyznano"), symbol: "checkmark", tone: .success, hint: nil)
    }

    static func required(hint: String?) -> PermissionStatus {
        PermissionStatus(chip: String(localized: "Wymagane"), symbol: "exclamationmark", tone: .warning, hint: hint)
    }
}

/// One permission line as a Dusk Glass row: outline icon, title and explanation on the left, the
/// status chip and the small glass action buttons on the right, an optional hint underneath.
@MainActor
private struct PermissionRow<Actions: View>: View {
    let symbol: String
    let title: String
    let explanation: String
    let status: PermissionStatus
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassRow(title: Text(verbatim: title), subtitle: Text(verbatim: explanation), systemImage: symbol, iconBadge: true) {
                HStack(spacing: 10) {
                    GlassBadge(title: Text(verbatim: status.chip), systemImage: status.symbol, tone: status.tone)
                    actions
                        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
                .padding(.leading, 8)
            }
            if let hint = status.hint {
                Text(verbatim: hint)
                    .font(GlassFont.caption)
                    .foregroundStyle(status.tone == .danger ? GlassColor.destructive : GlassColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, OnboardingLayout.badgeRowTextInset)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Shared measurements of the step rows.
enum OnboardingLayout {
    /// Leading inset of text that lines up with a `GlassRow` title (row padding + icon column + gap).
    static let rowTextInset: CGFloat = GlassTokens.Padding.rowHorizontal + GlassTokens.Size.rowIconColumn + 12
    /// Same for rows whose icon sits in a `GlassIconBadge`.
    static let badgeRowTextInset: CGFloat = GlassTokens.Padding.rowHorizontal + GlassTokens.Size.rowBadge + 12
}

// MARK: - Model

@MainActor
struct ModelStep: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cloudExpanded = false
    @State private var apiKey = ""
    @State private var keyMessage: String?
    @State private var keyMessageIsError = false

    private var modelStore: LocalModelStore { model.appState.modelStore }
    private var keyStore: KeyStore { model.appState.keyStore }

    var body: some View {
        stepContent
            .onAppear {
                modelStore.refresh()
                cloudExpanded = model.settings.sttEngine == .elevenLabs
                if keyStore.get(KeyStore.Account.elevenLabs) != nil {
                    keyMessage = String(localized: "Klucz jest zapisany w pęku kluczy.")
                }
            }
    }

    private var stepContent: some View {
        @Bindable var settings = model.settings

        return VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                symbol: OnboardingStep.model.symbol,
                title: String(localized: "Model rozpoznawania mowy"),
                subtitle: String(localized: "Model lokalny działa w całości na Twoim Macu: bez internetu, bez wysyłania nagrań.")
            )

            GlassRowSeparator()
                .padding(.top, 20)
                .padding(.bottom, 8)

            localModelRow

            GlassRowSeparator()
                .padding(.vertical, 8)

            GlassRow("Język transkrypcji", systemImage: "globe") {
                GlassMenuValue(languageTitle(settings.language)) {
                    Picker("Język transkrypcji", selection: $settings.language) {
                        Text("Wykrywaj automatycznie").tag(TranscriptionLanguages.auto)
                        Divider()
                        ForEach(TranscriptionLanguages.codes, id: \.self) { code in
                            Text(verbatim: Self.languageName(code)).tag(code)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel(Text("Język transkrypcji"))
            }

            GlassRowSeparator()
                .padding(.vertical, 8)

            cloudSection(settings: settings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageTitle(_ code: String) -> String {
        code == TranscriptionLanguages.auto ? String(localized: "Wykrywaj automatycznie") : Self.languageName(code)
    }

    // MARK: Local model

    private var localModelRow: some View {
        HStack(alignment: .center, spacing: 12) {
            GlassIconBadge(systemImage: "waveform.badge.mic", size: GlassTokens.Size.rowBadge)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: "Whisper large-v3 turbo")
                        .font(GlassFont.rowTitle.weight(.semibold))
                        .foregroundStyle(GlassColor.textPrimary)
                    GlassBadge("Lokalnie", tone: .accent)
                    GlassBadge("ok. 1,6 GB")
                }
                statusView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusAction
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .padding(.vertical, 6)
        .frame(minHeight: GlassTokens.Size.rowMinHeight)
    }

    @ViewBuilder
    private var statusView: some View {
        switch modelStore.status {
        case .missing:
            Text("Model nie jest jeszcze pobrany. Pobranie zajmuje chwilę, potem działa bez internetu.")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                OnboardingProgressTrack(fraction: fraction, height: 5)
                    .frame(maxWidth: 320)
                Text("Pobieram model... \(Int((fraction * 100).rounded()))%")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        case .optimizing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Optymalizuję model dla Twojego Maca (jednorazowo, do kilku minut)")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
            }
        case .ready:
            // Green text on warm glass washes out: the state is a success badge, like elsewhere.
            VStack(alignment: .leading, spacing: 6) {
                GlassBadge("Model gotowy do pracy", systemImage: "checkmark", tone: .success)
                SpeechDetectorStatusLine(status: model.appState.speechDetectorStatus)
            }
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(GlassFont.caption)
            .foregroundStyle(GlassColor.destructive)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        switch modelStore.status {
        case .missing:
            Button {
                Task { await modelStore.download() }
            } label: {
                Label("Pobierz model", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        case .failed:
            Button {
                Task { await modelStore.download() }
            } label: {
                Label("Spróbuj ponownie", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        case .downloading, .optimizing, .ready:
            EmptyView()
        }
    }

    // MARK: Cloud

    private func cloudSection(settings: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : GlassMotion.spring) {
                    cloudExpanded.toggle()
                }
            } label: {
                GlassRow("Użyj chmury", systemImage: "cloud") {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GlassColor.textSecondary)
                        .rotationEffect(.degrees(cloudExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Użyj chmury"))
            .accessibilityValue(cloudExpanded ? Text("Rozwinięte") : Text("Zwinięte"))

            if cloudExpanded {
                cloudContent(settings: settings)
                    .padding(.leading, OnboardingLayout.rowTextInset)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    private func cloudContent(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("Transkrypcja w chmurze wysyła nagranie na serwer. Gdy chmura zawiedzie, Captylo wraca do modelu lokalnego.")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Masz Captylo Pro? Zalogujesz się w Ustawieniach po zakończeniu.")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                GlassSecureField("Klucz API chmury", text: $apiKey)
                Button("Zapisz klucz") {
                    saveKey()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let keyMessage {
                Text(verbatim: keyMessage)
                    .font(GlassFont.caption)
                    .foregroundStyle(keyMessageIsError ? GlassColor.destructive : GlassColor.textSecondary)
            }
            GlassToggleRow("Transkrybuj w chmurze zamiast lokalnie", isOn: Binding(
                get: { settings.sttEngine == .elevenLabs },
                set: { settings.sttEngine = $0 ? .elevenLabs : .local }
            ))
            // Pro reaches the cloud without a key (through Captylo).
            .disabled(keyStore.get(KeyStore.Account.elevenLabs) == nil && !model.appState.account.isPro)
        }
    }

    private func saveKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try keyStore.set(value, account: KeyStore.Account.elevenLabs)
            apiKey = ""
            keyMessage = String(localized: "Klucz zapisany w pęku kluczy.")
            keyMessageIsError = false
            model.settings.sttEngine = .elevenLabs
        } catch {
            keyMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            keyMessageIsError = true
        }
    }

    /// "Polski", "Angielski" etc. in the current UI locale; falls back to the ISO code.
    static func languageName(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty else {
            return code.uppercased()
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: - Shortcut

@MainActor
struct ShortcutStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                symbol: OnboardingStep.shortcut.symbol,
                title: String(localized: "Skrót do dyktowania"),
                subtitle: String(localized: "Jeden skrót, dwa sposoby użycia. Domyślnie prawy Option.")
            )

            GlassRowSeparator()
                .padding(.top, 20)
                .padding(.bottom, 8)

            GlassRow("Skrót nagrywania", systemImage: "keyboard")
            HotkeyRecorderView(settings: model.settings, tap: model.appState.hotkeyTap)
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .padding(.leading, OnboardingLayout.rowTextInset)
                .padding(.bottom, 8)

            GlassRowSeparator()
                .padding(.vertical, 8)

            GlassRow(title: Text("Przytrzymaj, mów i puść: tekst wkleja się po zwolnieniu klawisza."), systemImage: "hand.tap") {
                EmptyView()
            }
            GlassRow(title: Text("Naciśnij krótko: nagrywanie zostaje włączone, kolejne naciśnięcie je kończy."), systemImage: "hand.point.up.left") {
                EmptyView()
            }
            GlassRow(title: Text("Dwa razy Esc podczas nagrywania anuluje bez wklejania."), systemImage: "escape") {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Try it

@MainActor
struct TryItStep: View {
    let model: OnboardingModel

    @State private var text = ""
    @State private var succeeded = false
    @State private var copiedOnly = false
    @State private var pasteboardBaseline = NSPasteboard.general.changeCount

    private var controller: DictationController { model.appState.dictationController }
    private var accessibilityTrusted: Bool { model.appState.accessibility.isTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeader(
                symbol: OnboardingStep.tryIt.symbol,
                title: String(localized: "Wypróbuj"),
                subtitle: instruction
            )

            GlassCard(style: .inset, padding: 0) {
                PasteOnlyTextView(
                    text: $text,
                    placeholder: String(localized: "Tutaj pojawi się to, co powiesz. Pole nie przyjmuje pisania, tylko dyktowanie.")
                )
                .frame(maxWidth: .infinity)
                .frame(height: 124)
            }
            .overlay {
                RoundedRectangle(cornerRadius: GlassTokens.Radius.card, style: .continuous)
                    .strokeBorder(GlassColor.success.opacity(succeeded ? 0.75 : 0), lineWidth: 1.5)
                    .shadow(color: GlassColor.success.opacity(succeeded ? 0.45 : 0), radius: 8)
                    .allowsHitTesting(false)
            }

            statusLine

            modelWarning

            if !accessibilityTrusted {
                Label("Bez uprawnienia Dostępność skrót nie działa, a tekst trafi tylko do schowka. Wróć do kroku Uprawnienia.", systemImage: "hand.raised")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            pasteboardBaseline = NSPasteboard.general.changeCount
        }
        .onChange(of: text) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markSuccess(copiedOnly: false)
            }
        }
        .onChange(of: controller.phase) { old, new in
            // A take just finished: the paste lands a moment later, the clipboard holds it either way.
            guard old != .idle, new == .idle else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                checkClipboardFallback()
            }
        }
    }

    private var instruction: String {
        String(localized: "Przytrzymaj \(model.settings.hotkey.displayName) i powiedz coś. Puść klawisz, a tekst wklei się poniżej.")
    }

    /// The local engine selected but not usable yet: say so here instead of letting the hotkey fail.
    @ViewBuilder
    private var modelWarning: some View {
        switch ModelBanner(engine: model.settings.sttEngine, status: model.appState.modelStore.status) {
        case .missing:
            HStack(spacing: 12) {
                Label("Model lokalny nie jest pobrany, więc dyktowanie jeszcze nie zadziała.", systemImage: "arrow.down.circle")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Wróć do kroku Model") {
                    model.show(.model)
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .downloading(let percent):
            Label("Model wciąż się pobiera (\(percent)%). Dyktowanie zadziała, gdy pobieranie się skończy.", systemImage: "arrow.down.circle")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .monospacedDigit()
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if succeeded {
            Label(
                copiedOnly
                    ? String(localized: "Tekst jest w schowku. Naciśnij ⌘V, aby go wkleić.")
                    : String(localized: "Działa! Tak samo zadziała w każdej aplikacji."),
                systemImage: "checkmark.circle.fill"
            )
            .font(GlassFont.sectionTitle)
            .foregroundStyle(GlassColor.success)
            .transition(.opacity)
        } else {
            HStack(spacing: 10) {
                Label(phaseText, systemImage: phaseSymbol)
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                if controller.phase == .idle {
                    OnboardingKeycap(keyName: model.settings.hotkey.displayName)
                }
                if controller.phase == .recording {
                    OnboardingWaveform(barCount: 9, barWidth: 2.5, spacing: 3, maxHeight: 16)
                }
            }
            .transition(.opacity)
        }
    }

    private var phaseText: String {
        switch controller.phase {
        case .idle: return String(localized: "Czekam na skrót...")
        case .recording: return String(localized: "Słucham... mów swobodnie")
        case .paused: return String(localized: "Pauza")
        case .transcribing: return String(localized: "Transkrybuję...")
        case .enhancing: return String(localized: "Poprawiam z AI...")
        }
    }

    private var phaseSymbol: String {
        switch controller.phase {
        case .idle: return "keyboard"
        case .recording: return "waveform"
        case .paused: return "pause.circle"
        case .transcribing, .enhancing: return "ellipsis.circle"
        }
    }

    private func markSuccess(copiedOnly: Bool) {
        guard !succeeded else { return }
        withAnimation(.easeInOut(duration: VTMotion.onboardingStepDuration)) {
            succeeded = true
            self.copiedOnly = copiedOnly
        }
    }

    private func checkClipboardFallback() {
        guard !succeeded, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if NSPasteboard.general.changeCount != pasteboardBaseline {
            markSuccess(copiedOnly: true)
        }
    }
}
