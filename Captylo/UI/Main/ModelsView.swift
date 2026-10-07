import AppKit
import SwiftUI

/// "Modele" in two tabs (`SettingsLevel`). "Podstawowe": the Captylo Pro card (`ProStatusCard`),
/// the speech engine (local model download, where the cloud audio goes, language), the "Tryby AI"
/// list (`AIModesPanel`) and AI cleanup (master switch, the model in use and where it runs, test
/// call). "Zaawansowane": the own keys, the cloud source ("Chmura Captylo" or the own key) and the
/// model list. With Pro the cloud and AI run on Captylo by default, even with own keys saved
/// (`AppSettings.sttCaptylo` / `aiCaptylo`, `CloudRouter`); "Podstawowe" always says which one runs,
/// so a hidden key never sends anything unseen.
@MainActor
struct ModelsView: View {
    static let elevenLabsKeysURL = URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    static let openRouterKeysURL = URL(string: "https://openrouter.ai/settings/keys")!

    @Environment(AppState.self) private var appState
    @State private var level: SettingsLevel = .basic
    /// Whether own keys are saved (read on appear, updated by the key fields).
    @State private var hasOwnCloudKey = false
    @State private var hasOwnAIKey = false

    var body: some View {
        ToolPage(subtitle: "Silnik, który zamienia mowę na tekst, i opcjonalne poprawianie przez AI.") {
            SettingsLevelPicker(level: $level)
        } content: {
            switch level {
            case .basic: basic
            case .advanced: advanced
            }
        }
        .onAppear {
            hasOwnCloudKey = Self.isSaved(appState.keyStore.get(KeyStore.Account.elevenLabs))
            hasOwnAIKey = Self.isSaved(appState.keyStore.get(KeyStore.Account.openRouter))
        }
    }

    private static func isSaved(_ key: String?) -> Bool {
        !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showAdvanced: () -> Void {
        { withAnimation(GlassMotion.spring) { level = .advanced } }
    }

    @ViewBuilder
    private var basic: some View {
        @Bindable var settings = appState.settings
        let isPro = appState.account.isPro

        ProStatusCard(account: appState.account)

        GlassPanel {
            GlassSectionHeader("Silnik mowy", systemImage: "waveform")
            GlassSegmentedPicker(selection: $settings.sttEngine, segments: [
                GlassSegment(STTEngine.local, "Lokalnie", systemImage: "cpu"),
                GlassSegment(STTEngine.elevenLabs, "Chmura", systemImage: "cloud"),
            ])
            .accessibilityLabel(Text("Silnik"))

            if settings.sttEngine == .local {
                LocalModelSection(store: appState.modelStore, detector: appState.speechDetectorStatus, showsCloudNote: false)
            } else {
                CloudSummary(
                    source: CloudSource(isPro: isPro, prefersCaptylo: settings.sttCaptylo, hasOwnKey: hasOwnCloudKey),
                    onChange: showAdvanced
                )
                // The cloud path still uses the local model for the fallback and the live
                // preview, so it stays manageable without switching engines.
                GlassRowSeparator()
                LocalModelSection(store: appState.modelStore, detector: appState.speechDetectorStatus, showsCloudNote: true)
            }
            if appState.modelStore.hasLegacyParakeet {
                GlassRowSeparator()
                LegacyParakeetRow(store: appState.modelStore)
            }

            GlassRowSeparator()
            LanguagePicker(language: $settings.language)
        }
        .animation(GlassMotion.spring, value: settings.sttEngine)

        AIModesPanel(settings: settings, tester: appState.modeTester)

        GlassPanel {
            GlassSectionHeader("Poprawianie przez AI", systemImage: "sparkles")
            GlassToggleRow("Poprawiaj transkrypcję przez AI", systemImage: "wand.and.stars", isOn: $settings.aiEnabled)
            GlassRowSeparator()
            AISummary(
                source: CloudSource(isPro: isPro, prefersCaptylo: settings.aiCaptylo, hasOwnKey: hasOwnAIKey),
                models: appState.openRouterModels,
                model: settings.aiModel,
                onChange: showAdvanced
            )
            TestButtonRow(enhancer: appState.enhancer, model: settings.aiModel)
        }
    }

    @ViewBuilder
    private var advanced: some View {
        @Bindable var settings = appState.settings
        let isPro = appState.account.isPro

        GlassPanel {
            GlassSectionHeader("Transkrypcja w chmurze", systemImage: "cloud")
            ToolCaption("Własne klucze są opcjonalne. Z kluczem nagrania i tekst idą z Twojego Maca prosto do dostawcy, a klucz zostaje w pęku kluczy macOS.")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            if isPro {
                // Pro: "Chmura Captylo" first; the own key only once one is saved.
                SourcePicker(captylo: $settings.sttCaptylo, hasOwnKey: hasOwnCloudKey, captyloName: String(localized: "Chmura Captylo"))
                GlassRowSeparator()
            }
            ElevenLabsSection(
                keyStore: appState.keyStore,
                client: appState.elevenLabs,
                settings: settings,
                isPro: isPro,
                onKeyPresence: { hasOwnCloudKey = $0 }
            )
            if settings.sttEngine == .local {
                ToolCaption("Teraz dyktujesz lokalnie. Chmurę włączysz w zakładce Podstawowe, w Silniku mowy.")
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }

        GlassPanel {
            GlassSectionHeader("Klucz i model AI", systemImage: "sparkles")
            OpenRouterKeySection(
                keyStore: appState.keyStore,
                enhancer: appState.enhancer,
                models: appState.openRouterModels,
                settings: settings,
                isPro: isPro,
                onKeyPresence: { hasOwnAIKey = $0 }
            )
            GlassRowSeparator()
            // Pro: Captylo AI first; the own key's models below it only while a key is saved.
            ModelPicker(
                models: appState.openRouterModels,
                selection: $settings.aiModel,
                captylo: isPro ? $settings.aiCaptylo : nil,
                showsModels: !isPro || hasOwnAIKey
            )
            TestButtonRow(enhancer: appState.enhancer, model: settings.aiModel)
        }
    }
}

// MARK: - Where the cloud and AI run

/// What runs a cloud service (transcription or AI) right now, the same rule as `CloudRouter`:
/// Pro with the Captylo choice (or without an own key) = Captylo, else the own key, else nothing.
struct CloudSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case captylo
        case ownKey
        case none
    }

    let kind: Kind

    init(isPro: Bool, prefersCaptylo: Bool, hasOwnKey: Bool) {
        if isPro, prefersCaptylo || !hasOwnKey {
            kind = .captylo
        } else if hasOwnKey {
            kind = .ownKey
        } else {
            kind = .none
        }
    }
}

/// "Podstawowe", cloud engine: where the recordings go, with "Zmień" / "Dodaj klucz" opening
/// "Zaawansowane".
@MainActor
private struct CloudSummary: View {
    let source: CloudSource
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(title: Text("Transkrypcja w chmurze"), subtitle: subtitle, systemImage: "cloud") {
                Button(source.kind == .none ? "Dodaj klucz" : "Zmień", action: onChange)
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            ToolCaption(caption)
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
    }

    private var subtitle: Text {
        switch source.kind {
        case .captylo: return Text("Chmura Captylo, w ramach Pro")
        case .ownKey: return Text("Twój klucz API chmury")
        case .none: return Text("Chmura działa w Pro albo z własnym kluczem.")
        }
    }

    private var caption: LocalizedStringKey {
        switch source.kind {
        case .captylo: return "Nagrania idą do transkrypcji przez Captylo. Gdy chmura nie odpowie, Captylo użyje modelu lokalnego, jeśli jest pobrany."
        case .ownKey: return "Nagrania idą z Twojego Maca prosto do dostawcy chmury. Gdy chmura nie odpowie, Captylo użyje modelu lokalnego, jeśli jest pobrany."
        case .none: return "Do tego czasu Captylo przepisuje nagrania na Macu, modelem lokalnym."
        }
    }
}

/// "Podstawowe", AI cleanup: the model in use and where the text goes, with "Zmień" /
/// "Dodaj klucz" opening "Zaawansowane".
@MainActor
private struct AISummary: View {
    let source: CloudSource
    let models: OpenRouterModels
    let model: String
    let onChange: () -> Void

    var body: some View {
        GlassRow(title: Text("Model"), subtitle: subtitle, systemImage: "brain") {
            Button(source.kind == .none ? "Dodaj klucz" : "Zmień", action: onChange)
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
        .task {
            await models.refresh()
        }
    }

    private var subtitle: Text {
        switch source.kind {
        case .captylo:
            return Text("\(Enhancer.relayModelName), nasz model w ramach Pro")
        case .ownKey:
            let name = models.models.first { $0.id == model }?.name ?? model
            return Text("\(name), przez Twój klucz API do AI")
        case .none:
            return Text("Poprawianie przez AI działa w Pro albo z własnym kluczem.")
        }
    }
}

/// "Zaawansowane", Pro: Captylo's own service first ("Chmura Captylo"), then the own key, which
/// can be picked only once one is saved below.
@MainActor
private struct SourcePicker: View {
    @Binding var captylo: Bool
    let hasOwnKey: Bool
    let captyloName: String

    private var usesCaptylo: Bool { captylo || !hasOwnKey }

    var body: some View {
        VStack(spacing: 2) {
            ModelRow(
                name: captyloName,
                detail: String(localized: "W ramach Pro, bez klucza"),
                detailIsID: false,
                trailing: String(localized: "w Pro"),
                symbol: "sparkles",
                isSelected: usesCaptylo
            ) {
                withAnimation(GlassMotion.selection) { captylo = true }
            }
            ModelRow(
                name: String(localized: "Własny klucz"),
                detail: hasOwnKey ? String(localized: "Prosto do dostawcy, z Twojego Maca") : String(localized: "Najpierw zapisz klucz poniżej"),
                detailIsID: false,
                trailing: "",
                symbol: nil,
                isSelected: !usesCaptylo
            ) {
                withAnimation(GlassMotion.selection) { captylo = false }
            }
            .disabled(!hasOwnKey)
            .opacity(hasOwnKey ? 1 : 0.5)
        }
        .padding(6)
        .glassSurface(.card, cornerRadius: GlassTokens.Radius.card, shadow: false)
        .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
    }
}

// MARK: - Local model

@MainActor
private struct LocalModelSection: View {
    let store: LocalModelStore
    /// The meeting voice detector that downloads with the model ("Wykrywanie mowy do spotkań").
    let detector: SpeechDetectorStatus
    /// On the cloud engine: explain why the local model still matters.
    let showsCloudNote: Bool

    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(title: Text("Model lokalny"), subtitle: subtitle, systemImage: "cpu") {
                trailing
            }
            if case .downloading(let progress) = store.status {
                ToolProgressTrack(value: progress)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.trailing, GlassTokens.Padding.rowHorizontal)
                    .padding(.bottom, 6)
            }
            if case .failed(let message) = store.status {
                ToolStatusLine(text: message, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
            if let deleteError {
                ToolStatusLine(text: deleteError, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
            SpeechDetectorStatusLine(status: detector)
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        .alert("Usunąć model lokalny?", isPresented: $confirmDelete) {
            Button("Usuń", role: .destructive) {
                Task {
                    do {
                        try await store.delete()
                        deleteError = nil
                    } catch {
                        deleteError = String(localized: "Nie udało się usunąć modelu: \(error.localizedDescription)")
                    }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Dyktowanie bez internetu i transkrypt spotkań na żywo przestaną działać, dopóki nie pobierzesz modelu ponownie (ok. 1,6 GB).")
        }
        .onAppear {
            store.refresh()
        }
    }

    private var subtitle: Text? {
        switch store.status {
        case .missing:
            if showsCloudNote {
                return Text("Potrzebny, gdy chmura nie odpowie, i do podglądu na żywo podczas nagrywania.")
            }
            return Text("Model nie jest pobrany (ok. 1,6 GB, działa bez internetu).")
        case .downloading(let progress):
            return Text("Pobieram model... \(Int((progress * 100).rounded()))%")
        case .optimizing:
            let text = Text("Optymalizuję model dla Twojego Maca (jednorazowo, do kilku minut)")
            guard let since = store.optimizingSince else { return text }
            // Counts up every second, so a long compile visibly moves on.
            return text + Text(verbatim: " · ") + Text(since, style: .timer).monospacedDigit()
        case .ready:
            return Text(verbatim: "Whisper large-v3 turbo")
        case .failed:
            return nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch store.status {
        case .missing:
            Button {
                Task { await store.download() }
            } label: {
                Label("Pobierz", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        case .downloading(let progress):
            GlassBadge(title: Text(verbatim: "\(Int((progress * 100).rounded()))%"), systemImage: "arrow.down", tone: .accent)
        case .optimizing:
            // One indicator: the compile has no progress to report, the elapsed time is in the subtitle.
            ProgressView().controlSize(.small)
        case .ready:
            HStack(spacing: 10) {
                GlassBadge("Gotowy", systemImage: "checkmark", tone: .success)
                Button {
                    confirmDelete = true
                } label: {
                    Label {
                        Text("Usuń")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(GlassColor.destructive)
                    }
                }
                // Neutral glass with a red icon: a working model must not be the loudest thing
                // on the page, and the alert above still confirms the deletion.
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .failed:
            Button("Spróbuj ponownie") {
                Task { await store.download() }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }
}

/// The Parakeet model of earlier versions, still on disk: offered for removal, never used.
@MainActor
private struct LegacyParakeetRow: View {
    let store: LocalModelStore

    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(
                title: Text("Poprzedni model lokalny"),
                subtitle: Text("Captylo go już nie używa. Zajmuje ok. 460 MB."),
                systemImage: "archivebox"
            ) {
                Button {
                    confirmDelete = true
                } label: {
                    Label {
                        Text("Usuń")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(GlassColor.destructive)
                    }
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            if let deleteError {
                ToolStatusLine(text: deleteError, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .alert("Usunąć poprzedni model?", isPresented: $confirmDelete) {
            Button("Usuń", role: .destructive) {
                do {
                    try store.deleteLegacyParakeet()
                    deleteError = nil
                } catch {
                    deleteError = String(localized: "Nie udało się usunąć modelu: \(error.localizedDescription)")
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Folder modelu jest współdzielony z poprzednią aplikacją do dyktowania. Po usunięciu ona również straci model i będzie musiała pobrać go ponownie.")
        }
    }
}

// MARK: - API key field

/// "Klucz API ..." label, the glass secure field with Zapisz / Sprawdź and, while a key is saved,
/// "Usuń klucz" (asks first, `removeMessage` says what happens without it), then the status line
/// and the link to the provider's key page. Shared by ElevenLabs and OpenRouter.
@MainActor
private struct APIKeyField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var key: String
    let status: (text: String, tone: InlineStatus.Tone)?
    let isChecking: Bool
    let linkTitle: LocalizedStringKey
    let linkURL: URL
    /// A key is saved in the Keychain (not only typed in the field).
    let isSaved: Bool
    let removeMessage: String
    let onSave: () -> Void
    let onVerify: () -> Void
    let onRemove: () -> Void

    @State private var confirmRemove = false

    private var isEmpty: Bool {
        key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: GlassTokens.Size.rowIcon))
                    .foregroundStyle(GlassColor.icon)
                    .frame(width: GlassTokens.Size.rowIconColumn)
                    .accessibilityHidden(true)
                Text(title)
                    .font(GlassFont.rowTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                Spacer()
                Link(destination: linkURL) {
                    HStack(spacing: 4) {
                        Text(linkTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                }
                .pointerStyleLinkIfAvailable()
            }
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            .padding(.top, 6)
            HStack(spacing: 8) {
                GlassSecureField(placeholder, text: $key)
                Button("Zapisz", action: onSave)
                    .disabled(isEmpty)
                Button {
                    onVerify()
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Sprawdź")
                    }
                }
                .disabled(isEmpty || isChecking)
                if isSaved {
                    Button {
                        confirmRemove = true
                    } label: {
                        Label {
                            Text("Usuń klucz")
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(GlassColor.destructive)
                        }
                    }
                    .disabled(isChecking)
                }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            if let status, !isChecking {
                ToolStatusLine(text: status.text, tone: status.tone)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .padding(.bottom, 4)
        .alert("Usunąć klucz?", isPresented: $confirmRemove) {
            Button("Usuń klucz", role: .destructive, action: onRemove)
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text(verbatim: removeMessage)
        }
    }
}

private extension View {
    /// Pointing-hand cursor on links (macOS 15+); plain on 14.
    @ViewBuilder
    func pointerStyleLinkIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

// MARK: - ElevenLabs

@MainActor
private struct ElevenLabsSection: View {
    let keyStore: KeyStore
    let client: ElevenLabsSTT
    let settings: AppSettings
    /// Pro sends the cloud through Captylo unless the own key is chosen above.
    let isPro: Bool
    /// Whether an own key is saved (on appear, after "Zapisz" and after "Usuń klucz").
    let onKeyPresence: (Bool) -> Void

    @State private var key = ""
    @State private var isSaved = false
    @State private var status: (text: String, tone: InlineStatus.Tone)?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            APIKeyField(
                title: "Klucz API chmury",
                placeholder: "xi-...",
                key: $key,
                status: status,
                isChecking: isChecking,
                linkTitle: "Skąd wziąć klucz",
                linkURL: ModelsView.elevenLabsKeysURL,
                isSaved: isSaved,
                removeMessage: isPro
                    ? String(localized: "Transkrypcja w chmurze przejdzie na Captylo w ramach Pro.")
                    : String(localized: "Bez klucza Captylo przepisze nagrania na Macu, dopóki nie dodasz klucza albo nie przejdziesz na Pro."),
                onSave: save,
                onVerify: verify,
                onRemove: remove
            )
            if isPro, isSaved {
                ToolCaption("Z własnym kluczem wybierzesz powyżej, czy chmura działa przez Captylo, czy przez Twój klucz.")
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .onAppear {
            key = keyStore.get(KeyStore.Account.elevenLabs) ?? ""
            isSaved = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            onKeyPresence(isSaved)
        }
    }

    private func save() {
        do {
            try keyStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: KeyStore.Account.elevenLabs)
            isSaved = true
            onKeyPresence(true)
            status = (String(localized: "Klucz zapisany w pęku kluczy."), .success)
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    private func remove() {
        do {
            try keyStore.delete(account: KeyStore.Account.elevenLabs)
            key = ""
            isSaved = false
            onKeyPresence(false)
            if isPro {
                settings.sttCaptylo = true
            }
            status = (isPro ? String(localized: "Klucz usunięty. Działa Chmura Captylo.") : String(localized: "Klucz usunięty."), .success)
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    private func verify() {
        isChecking = true
        let candidate = key
        let client = client
        Task {
            do {
                try await client.verify(key: candidate)
                status = (String(localized: "OK, klucz działa."), .success)
            } catch {
                status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
            }
            isChecking = false
        }
    }
}

// MARK: - Language

@MainActor
private struct LanguagePicker: View {
    @Binding var language: String

    struct Option: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// "Automatycznie" first, then the 25 offered languages named in the UI language.
    static let options: [Option] = {
        let locale = AppLocale.current
        let named = TranscriptionLanguages.codes.map { code -> Option in
            let raw = locale.localizedString(forLanguageCode: code) ?? code
            return Option(code: code, name: raw.prefix(1).uppercased() + raw.dropFirst())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [Option(code: TranscriptionLanguages.auto, name: String(localized: "Automatycznie"))] + named
    }()

    private var currentName: String {
        Self.options.first { $0.code == language }?.name ?? language
    }

    var body: some View {
        GlassRow("Język transkrypcji", systemImage: "globe") {
            GlassMenuValue(currentName) {
                Picker("Język transkrypcji", selection: $language) {
                    ForEach(Self.options) { option in
                        Text(verbatim: option.name).tag(option.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Język transkrypcji"))
            .accessibilityValue(Text(verbatim: currentName))
        }
    }
}

// MARK: - OpenRouter key

@MainActor
private struct OpenRouterKeySection: View {
    let keyStore: KeyStore
    let enhancer: Enhancer
    let models: OpenRouterModels
    let settings: AppSettings
    /// Pro runs the AI through Captylo when no own key is saved.
    let isPro: Bool
    /// Whether an own key is saved (on appear, after "Zapisz" and after "Usuń klucz").
    let onKeyPresence: (Bool) -> Void

    @State private var key = ""
    @State private var isSaved = false
    @State private var status: (text: String, tone: InlineStatus.Tone)?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            APIKeyField(
                title: "Klucz API do AI",
                placeholder: "sk-or-...",
                key: $key,
                status: status,
                isChecking: isChecking,
                linkTitle: "Skąd wziąć klucz",
                linkURL: ModelsView.openRouterKeysURL,
                isSaved: isSaved,
                removeMessage: isPro
                    ? String(localized: "Poprawianie przez AI przejdzie na Captylo AI w ramach Pro.")
                    : String(localized: "Bez klucza poprawianie przez AI nie zadziała, dopóki nie dodasz klucza albo nie przejdziesz na Pro."),
                onSave: save,
                onVerify: verify,
                onRemove: remove
            )
            if isPro, isSaved {
                ToolCaption("Z własnym kluczem wybierzesz poniżej inny model niż Captylo AI.")
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .onAppear {
            key = keyStore.get(KeyStore.Account.openRouter) ?? ""
            isSaved = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            onKeyPresence(isSaved)
        }
    }

    private func remove() {
        do {
            try keyStore.delete(account: KeyStore.Account.openRouter)
            key = ""
            isSaved = false
            onKeyPresence(false)
            if isPro {
                settings.aiCaptylo = true
            }
            status = (isPro ? String(localized: "Klucz usunięty. Działa Captylo AI.") : String(localized: "Klucz usunięty."), .success)
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    private func save() {
        do {
            try keyStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: KeyStore.Account.openRouter)
            isSaved = true
            onKeyPresence(true)
            status = (String(localized: "Klucz zapisany w pęku kluczy."), .success)
            // Gotcha 67: validate the chosen model id against the live list once a key is saved.
            let models = models
            let settings = settings
            Task {
                await models.refresh(force: true)
                if !models.models.isEmpty, !models.isKnown(id: settings.aiModel) {
                    status = (String(localized: "Klucz zapisany, ale model \(settings.aiModel) nie jest już dostępny. Wybierz inny."), .error)
                }
            }
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    private func verify() {
        isChecking = true
        let candidate = key
        let enhancer = enhancer
        Task {
            switch await enhancer.verifyKey(candidate) {
            case .success:
                status = (String(localized: "OK, klucz działa."), .success)
            case .failure(let error):
                status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
            }
            isChecking = false
        }
    }
}

// MARK: - Model picker

/// "Model": the search field and the list of the own key's models. In Pro (`captylo` set) the
/// list starts with Captylo AI, which `captylo` turns on; picking any other model turns it off.
/// Without an own key in Pro (`showsModels` false) only Captylo AI is listed.
@MainActor
private struct ModelPicker: View {
    let models: OpenRouterModels
    @Binding var selection: String
    var captylo: Binding<Bool>? = nil
    var showsModels = true

    @State private var query = ""

    private var results: [OpenRouterModel] {
        models.search(query)
    }

    private var usesCaptylo: Bool {
        captylo?.wrappedValue == true || (captylo != nil && !showsModels)
    }

    /// The chosen model by its display name ("GPT-4.1 Mini"), the raw id only while the list
    /// is not loaded yet; the ids stay in the list below.
    private var selectionName: String {
        if usesCaptylo { return Enhancer.relayModelName }
        return models.models.first { $0.id == selection }?.name ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassRow(
                title: Text("Model"),
                subtitle: Text(verbatim: selectionName),
                systemImage: "brain"
            ) {
                HStack(spacing: 8) {
                    if !usesCaptylo, !models.models.isEmpty, !models.isKnown(id: selection) {
                        GlassBadge("Model niedostępny", systemImage: "exclamationmark", tone: .danger)
                    }
                    if models.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 30, height: 30)
                    } else {
                        ToolIconButton("arrow.clockwise", label: Text("Odśwież listę modeli")) {
                            Task { await models.refresh(force: true) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if showsModels {
                    ToolSearchField("Szukaj modelu (np. gemini, haiku)", text: $query)
                    if let error = models.errorMessage {
                        ToolStatusLine(text: error, tone: .error)
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if let captylo {
                            ModelRow(
                                name: Enhancer.relayModelName,
                                detail: String(localized: "Nasz model, w ramach Pro, bez klucza"),
                                detailIsID: false,
                                trailing: String(localized: "w Pro"),
                                symbol: "sparkles",
                                isSelected: usesCaptylo
                            ) {
                                withAnimation(GlassMotion.selection) {
                                    captylo.wrappedValue = true
                                }
                            }
                        }
                        if showsModels {
                            if results.isEmpty {
                                Text(models.models.isEmpty ? "Lista modeli nie jest jeszcze pobrana." : "Brak modeli pasujących do zapytania.")
                                    .font(GlassFont.body)
                                    .foregroundStyle(GlassColor.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            ForEach(results) { model in
                                ModelRow(
                                    name: model.name,
                                    detail: model.id,
                                    detailIsID: true,
                                    trailing: models.displayPrice(for: model),
                                    symbol: OpenRouterModel.quickPickIDs.contains(model.id) ? "bolt.fill" : nil,
                                    isSelected: !usesCaptylo && model.id == selection
                                ) {
                                    withAnimation(GlassMotion.selection) {
                                        selection = model.id
                                        captylo?.wrappedValue = false
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: showsModels ? 250 : 70)
                .glassSurface(.card, cornerRadius: GlassTokens.Radius.card, shadow: false)
                if !showsModels {
                    ToolCaption("Inny model wybierzesz, gdy zapiszesz własny klucz API do AI.")
                }
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        .task {
            await models.refresh()
        }
    }
}

/// One choice of the model list: name, a second line (the model id in monospace, or a plain
/// note), the price or another short note on the right, an optional symbol after the name
/// (the bolt of a quick pick, the sparkles of Captylo AI).
@MainActor
private struct ModelRow: View {
    let name: String
    let detail: String
    let detailIsID: Bool
    let trailing: String
    let symbol: String?
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? GlassColor.toggle : GlassColor.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: name)
                            .font(GlassFont.ui(13, isSelected ? .semibold : .regular))
                            .foregroundStyle(GlassColor.textPrimary)
                            .lineLimit(1)
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 9))
                                .foregroundStyle(symbol == "bolt.fill" ? GlassColor.warning : GlassColor.toggle)
                                .accessibilityLabel(Text(symbol == "bolt.fill" ? "Polecany" : "Captylo AI"))
                        }
                    }
                    Text(verbatim: detail)
                        .font(detailIsID ? .system(size: 11, design: .monospaced) : GlassFont.ui(11))
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(verbatim: trailing)
                    .font(GlassFont.ui(12).monospacedDigit())
                    .foregroundStyle(GlassColor.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? GlassTokens.Opacity.control : (isHovered ? 0.06 : 0)))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(GlassColor.rim(top: 0.35, bottom: 0.06), lineWidth: 1)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Test

@MainActor
private struct TestButtonRow: View {
    let enhancer: Enhancer
    let model: String

    @State private var isTesting = false
    @State private var result: (text: String, tone: InlineStatus.Tone)?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                run()
            } label: {
                Label("Testuj", systemImage: "play.fill")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .disabled(isTesting)
            if isTesting {
                ProgressView().controlSize(.small)
            } else if let result {
                ToolStatusLine(text: result.text, tone: result.tone)
            }
            Spacer()
        }
        .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
    }

    private func run() {
        isTesting = true
        let enhancer = enhancer
        let model = model
        Task {
            switch await enhancer.test(model: model) {
            case .success(let ms):
                result = (String(localized: "OK, \(ms) ms"), .success)
            case .failure(let error):
                result = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
            }
            isTesting = false
        }
    }
}
