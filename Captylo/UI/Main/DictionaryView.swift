import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Słownik": vocabulary chips, replacement rules and filler words on glass panels, plus JSON
/// import / export as glass buttons next to the page title.
@MainActor
struct DictionaryView: View {
    @Environment(AppState.self) private var appState

    @State private var vocabularyInput = ""
    @State private var vocabularyError: String?
    @State private var fillerInput = ""
    @State private var transferMessage: (text: String, tone: InlineStatus.Tone)?

    private var dictionary: DictionaryStore { appState.dictionary }

    var body: some View {
        ToolPage(subtitle: "Słowa i reguły, dzięki którym Captylo pisze Twoje nazwy poprawnie.") {
            transferButtons
        } content: {
            if let transferMessage {
                ToolStatusLine(text: transferMessage.text, tone: transferMessage.tone)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if let backup = dictionary.corruptBackupURL {
                corruptNotice(backup)
            }
            if let saveError = dictionary.saveError {
                saveErrorNotice(saveError)
            }
            vocabularyPanel
            LearnedPanel(learning: appState.learning, isEnabled: appState.settings.learningEnabled)
            ObservedPanel(learning: appState.learning, isEnabled: appState.settings.learningEnabled)
            StylePanel(learning: appState.learning, aiEnabled: appState.settings.aiEnabled)
            ReplacementsPanel(dictionary: dictionary)
            fillersPanel
        }
    }

    // MARK: Corrupt file notice

    private func corruptNotice(_ backup: URL) -> some View {
        ToolNoticePanel(
            title: Text("Nie udało się odczytać słownika"),
            message: Text("Plik słownika był uszkodzony, więc Captylo zaczęło od domyślnego. Oryginał zachowano jako \(backup.lastPathComponent). Po poprawieniu możesz go wczytać przyciskiem Importuj JSON.")
        ) {
            Button("Pokaż w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([backup])
            }
            Button("Zamknij") {
                dictionary.dismissCorruptBackupNotice()
            }
        }
    }

    // MARK: Save failure notice

    /// Stays until a save succeeds: the changes would otherwise be lost on the next launch.
    private func saveErrorNotice(_ message: String) -> some View {
        ToolNoticePanel(title: Text("Słownik nie jest zapisany"), message: Text(verbatim: message)) {
            Button("Spróbuj ponownie") {
                dictionary.retrySave()
            }
        }
    }

    // MARK: Vocabulary

    private var vocabularyPanel: some View {
        GlassPanel {
            GlassSectionHeader("Słownictwo", systemImage: "character.book.closed") {
                GlassBadge(title: Text(verbatim: "\(dictionary.data.vocabulary.count)"))
            }
            ToolCaption("Nazwy własne, marki i żargon. Te słowa podpowiadają silnikowi w chmurze i poprawianiu przez AI. Model lokalny ich nie widzi: dla niego dodaj regułę w sekcji Zamiany.")
            if dictionary.data.vocabulary.isEmpty {
                emptyLine("Brak słów. Dodaj pierwsze poniżej.")
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(dictionary.data.vocabulary, id: \.self) { word in
                        ToolChip(text: word) {
                            dictionary.removeVocabulary(word)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            GlassRowSeparator()
            HStack(spacing: 10) {
                TextField("Dodaj słowa oddzielone przecinkami", text: $vocabularyInput)
                    .textFieldStyle(.glass)
                    .onSubmit(addVocabulary)
                Button(action: addVocabulary) {
                    Label("Dodaj", systemImage: "plus")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(vocabularyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let vocabularyError {
                ToolStatusLine(text: vocabularyError, tone: .error)
            }
        }
    }

    private func addVocabulary() {
        vocabularyError = dictionary.addVocabulary(vocabularyInput)
        if vocabularyError == nil {
            vocabularyInput = ""
        }
    }

    // MARK: Fillers

    private var fillersPanel: some View {
        GlassPanel {
            GlassSectionHeader("Wypełniacze", systemImage: "scissors") {
                GlassBadge(title: Text(verbatim: "\(dictionary.data.fillerWords.count)"))
            }
            ToolCaption("Dźwięki usuwane z transkrypcji (\"yyy\", \"hmm\"). Prawdziwe słowa zostawiamy w spokoju.")
            if dictionary.data.fillerWords.isEmpty {
                emptyLine("Lista jest pusta, wypełniacze nie są usuwane.")
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(dictionary.data.fillerWords, id: \.self) { word in
                        ToolChip(text: word) {
                            dictionary.setFillers(dictionary.data.fillerWords.filter { $0 != word })
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            GlassRowSeparator()
            HStack(spacing: 10) {
                TextField("Dodaj wypełniacz", text: $fillerInput)
                    .textFieldStyle(.glass)
                    .onSubmit(addFiller)
                Button(action: addFiller) {
                    Label("Dodaj", systemImage: "plus")
                }
                .disabled(fillerInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    dictionary.setFillers(DictionaryData.defaultFillerWords)
                } label: {
                    Label("Przywróć domyślne", systemImage: "arrow.uturn.backward")
                }
                .disabled(dictionary.data.fillerWords == DictionaryData.defaultFillerWords)
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }

    private func addFiller() {
        let words = fillerInput
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        dictionary.setFillers(dictionary.data.fillerWords + words)
        fillerInput = ""
    }

    private func emptyLine(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(GlassFont.body)
            .foregroundStyle(GlassColor.textTertiary)
            .padding(.vertical, 4)
    }

    // MARK: Import / export

    private var transferButtons: some View {
        HStack(spacing: 8) {
            Button {
                importJSON()
            } label: {
                Label("Importuj JSON", systemImage: "square.and.arrow.down")
            }
            Button {
                exportJSON()
            } label: {
                Label("Eksportuj JSON", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Wybierz plik słownika (JSON)")
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let added = try dictionary.importJSON(from: url)
                transferMessage = (String(localized: "Zaimportowano \(added) nowych pozycji."), .success)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                transferMessage = (message, .error)
            }
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Captylo-slownik.json"
        panel.canCreateDirectories = true
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try dictionary.exportJSON(to: url)
                transferMessage = (String(localized: "Zapisano \(url.lastPathComponent)."), .success)
            } catch {
                transferMessage = (String(localized: "Nie udało się zapisać pliku: \(error.localizedDescription)"), .error)
            }
        }
    }
}

// MARK: - Replacements

@MainActor
private struct ReplacementsPanel: View {
    /// Width of the actions column, shared by the header, the rows and the add line.
    static let actionsWidth: CGFloat = 96

    let dictionary: DictionaryStore

    @State private var newTriggers = ""
    @State private var newReplacement = ""
    @State private var addError: String?

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Zamiany", systemImage: "arrow.left.arrow.right") {
                GlassBadge(title: Text(verbatim: "\(dictionary.data.replacements.count)"))
            }
            ToolCaption("Gdy silnik usłyszy jedno z wyrażeń po lewej, w tekście pojawi się wersja po prawej. Kilka wariantów oddziel przecinkami. To jedyny sposób, aby model lokalny poprawnie pisał nazwy własne.")
            if dictionary.data.replacements.isEmpty {
                Text("Brak reguł. Dodaj pierwszą poniżej.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textTertiary)
                    .padding(.vertical, 4)
            } else {
                // Rules sit straight on the panel as rows (mockup 03), no inner card.
                VStack(alignment: .leading, spacing: 0) {
                    ReplacementColumns(
                        heard: Text("Usłyszane"),
                        target: Text("Zamiana na")
                    )
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                    .padding(.bottom, 6)
                    ForEach(Array(dictionary.data.replacements.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 {
                            GlassRowSeparator()
                        }
                        ReplacementRow(rule: rule, dictionary: dictionary)
                    }
                }
            }
            GlassRowSeparator()
            ReplacementColumns {
                TextField("np. kap tylo, kaptilo", text: $newTriggers)
                    .textFieldStyle(.glass)
                    .onSubmit(add)
            } target: {
                TextField("np. Captylo", text: $newReplacement)
                    .textFieldStyle(.glass)
                    .onSubmit(add)
            } actions: {
                Button(action: add) {
                    Label("Dodaj", systemImage: "plus")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            if let addError {
                ToolStatusLine(text: addError, tone: .error)
            }
        }
    }

    private func add() {
        let rule = ReplacementRule(triggers: Self.splitTriggers(newTriggers), replacement: newReplacement)
        addError = dictionary.upsert(rule)
        if addError == nil {
            newTriggers = ""
            newReplacement = ""
        }
    }

    static func splitTriggers(_ text: String) -> [String] {
        text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Shared column layout of the rule list: heard phrases and target grow evenly, a fixed arrow
/// column between them and a fixed actions column at the end (header, rows and the add line).
@MainActor
private struct ReplacementColumns<Heard: View, Target: View, Actions: View>: View {
    @ViewBuilder var heard: Heard
    @ViewBuilder var target: Target
    @ViewBuilder var actions: Actions
    var showsArrow = true

    var body: some View {
        HStack(spacing: 12) {
            heard
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if showsArrow {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GlassColor.textTertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 24)
            .accessibilityHidden(true)
            target
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .frame(width: ReplacementsPanel.actionsWidth, alignment: .trailing)
        }
    }
}

extension ReplacementColumns where Heard == Text, Target == Text, Actions == Color {
    /// Column titles, sentence case. The actions column stays as an empty spacer (an
    /// `EmptyView` would drop out of the layout and shift the titles).
    init(heard: Text, target: Text) {
        self.heard = heard
        self.target = target
        self.actions = Color.clear
        self.showsArrow = false
    }
}

/// One rule "a, b -> X". Reads as a plain row (heard phrases secondary, arrow tertiary, target
/// semibold); a click switches it to glass fields that commit on submit or focus loss, the
/// trash button removes it.
@MainActor
private struct ReplacementRow: View {
    private enum Field: Hashable {
        case triggers
        case replacement
    }

    let rule: ReplacementRule
    let dictionary: DictionaryStore

    @State private var triggers: String
    @State private var replacement: String
    @State private var error: String?
    @State private var isEditing = false
    @State private var isHovered = false
    @FocusState private var focus: Field?

    init(rule: ReplacementRule, dictionary: DictionaryStore) {
        self.rule = rule
        self.dictionary = dictionary
        _triggers = State(initialValue: rule.triggers.joined(separator: ", "))
        _replacement = State(initialValue: rule.replacement)
    }

    private var isDirty: Bool {
        triggers != rule.triggers.joined(separator: ", ") || replacement != rule.replacement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                editor
            } else {
                reader
            }
            if let error {
                ToolStatusLine(text: error, tone: .error)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: GlassTokens.Size.rowMinHeight)
        .animation(GlassMotion.press, value: isDirty)
        .onChange(of: focus) { _, field in
            // Both fields lost focus: save and fall back to the plain row.
            guard field == nil, isEditing else { return }
            commit()
            if error == nil {
                isEditing = false
            }
        }
        .onChange(of: rule) { _, fresh in
            triggers = fresh.triggers.joined(separator: ", ")
            replacement = fresh.replacement
        }
    }

    private var reader: some View {
        ReplacementColumns {
            Text(verbatim: rule.triggers.joined(separator: ", "))
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(2)
        } target: {
            Text(verbatim: rule.replacement)
                .font(GlassFont.body.weight(.semibold))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(2)
        } actions: {
            HStack(spacing: 6) {
                if isHovered {
                    ToolIconButton("pencil", label: Text("Edytuj regułę"), size: 28, action: beginEditing)
                        .transition(.opacity)
                }
                ToolIconButton("trash", label: Text("Usuń regułę"), size: 28) {
                    dictionary.removeRule(rule.id)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: beginEditing)
        .onHover { hovering in
            withAnimation(GlassMotion.press) { isHovered = hovering }
        }
        .help(Text("Kliknij, aby edytować"))
        .accessibilityAction(named: Text("Edytuj regułę"), beginEditing)
    }

    private var editor: some View {
        ReplacementColumns {
            TextField("Usłyszane", text: $triggers)
                .textFieldStyle(.glass)
                .focused($focus, equals: .triggers)
                .onSubmit(finish)
        } target: {
            TextField("Zamiana", text: $replacement)
                .textFieldStyle(.glass)
                .fontWeight(.semibold)
                .focused($focus, equals: .replacement)
                .onSubmit(finish)
        } actions: {
            HStack(spacing: 6) {
                ToolIconButton("checkmark", label: Text("Zapisz zmianę"), size: 28, action: finish)
                ToolIconButton("trash", label: Text("Usuń regułę"), size: 28) {
                    dictionary.removeRule(rule.id)
                }
            }
        }
    }

    private func beginEditing() {
        isEditing = true
        // The fields exist from the next update on.
        Task { @MainActor in focus = .triggers }
    }

    /// Enter or the checkmark: save and close the editor unless the rule was rejected.
    private func finish() {
        commit()
        if error == nil {
            isEditing = false
            focus = nil
        }
    }

    private func commit() {
        guard isDirty else {
            error = nil
            return
        }
        let updated = ReplacementRule(
            id: rule.id,
            triggers: triggers.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            replacement: replacement
        )
        error = dictionary.upsert(updated)
    }
}
