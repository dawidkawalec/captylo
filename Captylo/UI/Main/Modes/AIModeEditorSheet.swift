import SwiftUI

/// The glass sheet that edits one AI mode: Nazwa, Ikona, Rodzaj, Limit czasu, Prompt, and
/// "Testuj tryb" on the draft. Nothing is stored until Zapisz (`onSave(mode, isNew)`).
@MainActor
struct AIModeEditorSheet: View {
    let request: AIModeEditorRequest
    let tester: ModeTester
    let onSave: (AIMode, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIMode

    init(request: AIModeEditorRequest, tester: ModeTester, onSave: @escaping (AIMode, Bool) -> Void) {
        self.request = request
        self.tester = tester
        self.onSave = onSave
        _draft = State(initialValue: request.mode)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptIsEmpty: Bool {
        draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !promptIsEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsPanel
                    promptPanel
                    AIModeTestPanel(mode: draft, tester: tester)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollContentBackground(.hidden)
            .mask {
                // Soft fade where the panels slide under the header and the footer.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.025),
                        .init(color: .black, location: 0.97),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            footer
                .padding(.horizontal, 28)
                .padding(.top, 10)
                .padding(.bottom, 20)
        }
        .frame(minWidth: 660, idealWidth: 680, maxWidth: 820, minHeight: 480, idealHeight: 680, maxHeight: 980)
        .background {
            DuskBackground(role: .sheet)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(GlassColor.textPrimary)
        .tint(GlassColor.accent)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 14) {
            GlassIconBadge(systemImage: draft.symbol, size: 44, tint: GlassColor.accent)
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if request.isNew {
                        Text("Nowy tryb")
                    } else {
                        Text("Edytuj tryb")
                    }
                }
                .font(GlassFont.display(20))
                .foregroundStyle(GlassColor.textPrimary)
                // A new mode keeps its placeholder name until renamed: no "Nowy tryb" twice.
                Text(verbatim: trimmedName.isEmpty || (request.isNew && trimmedName == request.mode.name) ? " " : trimmedName)
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                    .lineLimit(1)
            }
            .glassTextShadow()
            Spacer(minLength: 12)
            if draft.isBuiltIn {
                GlassBadge("Wbudowany", systemImage: "shippingbox")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !canSave {
                ToolStatusLine(
                    text: trimmedName.isEmpty
                        ? String(localized: "Podaj nazwę trybu.")
                        : String(localized: "Prompt nie może być pusty."),
                    tone: .neutral
                )
            }
            Spacer(minLength: 0)
            Button("Anuluj") {
                dismiss()
            }
            .buttonStyle(.glass(.neutral))
            .keyboardShortcut(.cancelAction)
            .frame(minWidth: 110)
            Button {
                var saved = draft
                saved.name = trimmedName
                onSave(saved, request.isNew)
                dismiss()
            } label: {
                Label(request.isNew ? "Dodaj tryb" : "Zapisz", systemImage: "checkmark")
            }
            .buttonStyle(.glass(.accent))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave)
        }
    }

    // MARK: Panels

    private var settingsPanel: some View {
        GlassPanel(spacing: 6) {
            GlassRow("Nazwa", systemImage: "character.cursor.ibeam") {
                TextField("Nazwa trybu", text: $draft.name)
                    .textFieldStyle(.glass)
                    .frame(maxWidth: 300)
            }
            GlassRowSeparator()
            VStack(alignment: .leading, spacing: 8) {
                GlassRow("Ikona", systemImage: "square.grid.2x2")
                AIModeSymbolGrid(selection: $draft.symbol)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.bottom, 8)
            }
            GlassRowSeparator()
            VStack(alignment: .leading, spacing: 6) {
                GlassRow("Rodzaj", systemImage: "slider.horizontal.3") {
                    GlassSegmentedPicker(
                        selection: $draft.kind,
                        segments: AIModeKind.allCases.map { kind in
                            GlassSegment(kind, title: Text(kind.title), systemImage: kind.symbol)
                        }
                    )
                }
                ToolCaption(text: Text(draft.kind.explanation))
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.bottom, 8)
                    .animation(nil, value: draft.kind)
            }
            GlassRowSeparator()
            GlassRow(
                title: Text("Limit czasu"),
                subtitle: Text("Po tym czasie wklejany jest surowy tekst."),
                systemImage: "timer"
            ) {
                AIModeDeadlineStepper(seconds: $draft.deadlineSeconds)
            }
        }
    }

    private var promptPanel: some View {
        GlassPanel {
            GlassSectionHeader("Prompt", systemImage: "text.quote") {
                if let shipped = draft.shippedVersion, shipped.prompt != draft.prompt {
                    Button {
                        draft.prompt = shipped.prompt
                    } label: {
                        Label("Przywróć oryginalny", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
            }
            ToolTextArea(text: $draft.prompt, minHeight: 170, maxHeight: 280, label: Text("Prompt"))
            ToolCaption(text: Text("Znacznik \(CleanupPrompt.dictionaryPlaceholder) zostanie zastąpiony listą słów ze Słownika (przy pustym Słowniku ta linia znika). Zakończ prompt poleceniem, by model zwrócił tylko wynik."))
            if !promptIsEmpty, !draft.prompt.contains(CleanupPrompt.dictionaryPlaceholder) {
                ToolStatusLine(
                    text: String(localized: "Ten prompt nie używa Słownika, więc model nie zobaczy Twoich słów."),
                    tone: .neutral
                )
            }
        }
    }
}
