import AppKit
import SwiftUI

/// "Modele": speech engine (local model download / ElevenLabs key, language), the "Tryby AI" list
/// (`AIModesPanel`) and AI cleanup (master switch, OpenRouter key, model picker, test call), as
/// three Dusk Glass panels.
@MainActor
struct ModelsView: View {
    static let elevenLabsKeysURL = URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    static let openRouterKeysURL = URL(string: "https://openrouter.ai/settings/keys")!

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        ToolPage(subtitle: "Silnik, który zamienia mowę na tekst, i opcjonalne poprawianie przez AI.") {
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
                    ElevenLabsSection(keyStore: appState.keyStore, client: appState.elevenLabs)
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

            // The modes come before the tall OpenRouter panel (its model list runs past the
            // window), so the owner reaches them without scrolling two screens.
            AIModesPanel(settings: settings, tester: appState.modeTester)

            GlassPanel {
                GlassSectionHeader("Poprawianie przez AI", systemImage: "sparkles")
                GlassToggleRow("Poprawiaj transkrypcję przez AI", systemImage: "wand.and.stars", isOn: $settings.aiEnabled)
                GlassRowSeparator()
                OpenRouterKeySection(keyStore: appState.keyStore, enhancer: appState.enhancer, models: appState.openRouterModels, settings: settings)
                GlassRowSeparator()
                ModelPicker(models: appState.openRouterModels, selection: $settings.aiModel)
                TestButtonRow(enhancer: appState.enhancer, model: settings.aiModel)
            }
        }
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
            return Text("Optymalizuję model dla Twojego Maca (jednorazowo, do kilku minut)")
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                ToolProgressTrack(value: nil)
                    .frame(width: 90)
            }
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

/// "Klucz API ..." label, the glass secure field with Zapisz / Sprawdź, then the status line and
/// the link to the provider's key page. Shared by ElevenLabs and OpenRouter.
@MainActor
private struct APIKeyField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var key: String
    let status: (text: String, tone: InlineStatus.Tone)?
    let isChecking: Bool
    let linkTitle: LocalizedStringKey
    let linkURL: URL
    let onSave: () -> Void
    let onVerify: () -> Void

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
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            if let status, !isChecking {
                ToolStatusLine(text: status.text, tone: status.tone)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .padding(.bottom, 4)
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

    @State private var key = ""
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
                onSave: save,
                onVerify: verify
            )
            ToolCaption("Nagrania są wysyłane do transkrypcji w chmurze. Gdy chmura nie odpowie, Captylo użyje modelu lokalnego, jeśli jest pobrany.")
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        .onAppear {
            key = keyStore.get(KeyStore.Account.elevenLabs) ?? ""
        }
    }

    private func save() {
        do {
            try keyStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: KeyStore.Account.elevenLabs)
            status = (String(localized: "Klucz zapisany w pęku kluczy."), .success)
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

    @State private var key = ""
    @State private var status: (text: String, tone: InlineStatus.Tone)?
    @State private var isChecking = false

    var body: some View {
        APIKeyField(
            title: "Klucz API do AI",
            placeholder: "sk-or-...",
            key: $key,
            status: status,
            isChecking: isChecking,
            linkTitle: "Skąd wziąć klucz",
            linkURL: ModelsView.openRouterKeysURL,
            onSave: save,
            onVerify: verify
        )
        .onAppear {
            key = keyStore.get(KeyStore.Account.openRouter) ?? ""
        }
    }

    private func save() {
        do {
            try keyStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: KeyStore.Account.openRouter)
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

@MainActor
private struct ModelPicker: View {
    let models: OpenRouterModels
    @Binding var selection: String

    @State private var query = ""

    private var results: [OpenRouterModel] {
        models.search(query)
    }

    /// The chosen model by its display name ("GPT-4.1 Mini"), the raw id only while the list
    /// is not loaded yet; the ids stay in the list below.
    private var selectionName: String {
        models.models.first { $0.id == selection }?.name ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassRow(
                title: Text("Model"),
                subtitle: Text(verbatim: selectionName),
                systemImage: "brain"
            ) {
                HStack(spacing: 8) {
                    if !models.models.isEmpty, !models.isKnown(id: selection) {
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
                ToolSearchField("Szukaj modelu (np. gemini, haiku)", text: $query)
                if let error = models.errorMessage {
                    ToolStatusLine(text: error, tone: .error)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if results.isEmpty {
                            Text(models.models.isEmpty ? "Lista modeli nie jest jeszcze pobrana." : "Brak modeli pasujących do zapytania.")
                                .font(GlassFont.body)
                                .foregroundStyle(GlassColor.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        ForEach(results) { model in
                            ModelRow(
                                model: model,
                                price: models.displayPrice(for: model),
                                isQuickPick: OpenRouterModel.quickPickIDs.contains(model.id),
                                isSelected: model.id == selection
                            ) {
                                withAnimation(GlassMotion.selection) {
                                    selection = model.id
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 250)
                .glassSurface(.card, cornerRadius: GlassTokens.Radius.card, shadow: false)
            }
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        .task {
            await models.refresh()
        }
    }
}

@MainActor
private struct ModelRow: View {
    let model: OpenRouterModel
    let price: String
    let isQuickPick: Bool
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
                        Text(verbatim: model.name)
                            .font(GlassFont.ui(13, isSelected ? .semibold : .regular))
                            .foregroundStyle(GlassColor.textPrimary)
                            .lineLimit(1)
                        if isQuickPick {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(GlassColor.warning)
                                .accessibilityLabel(Text("Polecany"))
                        }
                    }
                    Text(verbatim: model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(verbatim: price)
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
