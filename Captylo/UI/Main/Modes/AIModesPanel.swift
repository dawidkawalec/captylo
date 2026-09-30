import SwiftUI

/// "Tryby AI" on the Modele screen: the list of modes (click = active mode for dictation and
/// files), "Dodaj tryb", the row menus (Edytuj, Duplikuj, moves, Usuń) and "Przywróć domyślne
/// tryby". Editing happens in `AIModeEditorSheet`; every change goes through the `AppSettings`
/// mode actions.
@MainActor
struct AIModesPanel: View {
    let settings: AppSettings
    let tester: ModeTester

    @State private var editor: AIModeEditorRequest?
    @State private var pendingDelete: AIMode?
    @State private var confirmRestore = false

    var body: some View {
        let modes = settings.aiModes
        let activeID = settings.activeMode.id

        GlassPanel {
            GlassSectionHeader("Tryby AI", systemImage: "wand.and.stars") {
                Button {
                    editor = AIModeEditorRequest(mode: AIMode.newCustom(), isNew: true)
                } label: {
                    Label("Dodaj tryb", systemImage: "plus")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            ToolCaption("Tryb decyduje, co AI zrobi z dyktatem: poprawi go, przetłumaczy albo przerobi na e-mail lub listę zadań. Kliknij tryb, aby go używać.")
            if !settings.aiEnabled {
                ToolStatusLine(
                    text: String(localized: "Poprawianie przez AI jest wyłączone, więc dyktaty wklejają się bez zmian. Kliknij tryb, aby je włączyć."),
                    tone: .neutral
                )
            }

            VStack(spacing: 4) {
                ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    AIModeRow(
                        mode: mode,
                        // "Bez AI" = no checked mode, like the widget and the menu bar.
                        isActive: settings.aiEnabled && mode.id == activeID,
                        canMoveUp: index > 0,
                        canMoveDown: index < modes.count - 1,
                        canDelete: modes.count > 1,
                        actions: actions(for: mode)
                    )
                }
            }
            .animation(GlassMotion.spring, value: modes.map(\.id))

            GlassRowSeparator()
            HStack(alignment: .center, spacing: 16) {
                ToolCaption("Gdy AI nie odpowie w limicie czasu trybu, wklejany jest surowy tekst.")
                Button {
                    confirmRestore = true
                } label: {
                    Label("Przywróć domyślne tryby", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .fixedSize()
            }
        }
        .sheet(item: $editor) { request in
            AIModeEditorSheet(request: request, tester: tester) { mode, isNew in
                save(mode, isNew: isNew)
            }
        }
        .alert(
            pendingDelete.map { Text("Usunąć tryb „\($0.name)”?") } ?? Text(verbatim: ""),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { mode in
            Button("Usuń", role: .destructive) {
                withAnimation(GlassMotion.spring) {
                    _ = settings.deleteMode(id: mode.id)
                }
                pendingDelete = nil
            }
            Button("Anuluj", role: .cancel) {
                pendingDelete = nil
            }
        } message: { mode in
            if mode.isBuiltIn {
                Text("Tryb wbudowany wróci po kliknięciu Przywróć domyślne tryby.")
            } else {
                Text("Tego nie da się cofnąć.")
            }
        }
        .alert("Przywrócić domyślne tryby?", isPresented: $confirmRestore) {
            Button("Przywróć") {
                withAnimation(GlassMotion.spring) {
                    settings.restoreDefaultModes()
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Wbudowane tryby wrócą do oryginalnych nazw, promptów i limitów, a usunięte pojawią się ponownie. Twoje własne tryby zostaną bez zmian.")
        }
    }

    private func actions(for mode: AIMode) -> AIModeRow.Actions {
        AIModeRow.Actions(
            activate: {
                // Same as a pick in the widget and the menu bar: the mode becomes active and AI
                // turns on, so a checked row always means the next dictation uses it.
                withAnimation(GlassMotion.selection) {
                    RecorderAIModeOptions.select(id: mode.id, in: settings)
                }
            },
            edit: {
                editor = AIModeEditorRequest(mode: mode, isNew: false)
            },
            duplicate: {
                let copy = withAnimation(GlassMotion.spring) {
                    settings.duplicateMode(id: mode.id)
                }
                if let copy {
                    editor = AIModeEditorRequest(mode: copy, isNew: false)
                }
            },
            moveUp: {
                withAnimation(GlassMotion.spring) {
                    settings.moveMode(id: mode.id, by: -1)
                }
            },
            moveDown: {
                withAnimation(GlassMotion.spring) {
                    settings.moveMode(id: mode.id, by: 1)
                }
            },
            delete: {
                pendingDelete = mode
            }
        )
    }

    private func save(_ mode: AIMode, isNew: Bool) {
        withAnimation(GlassMotion.spring) {
            if isNew {
                settings.addMode(mode)
            } else {
                settings.updateMode(mode)
            }
        }
    }
}
