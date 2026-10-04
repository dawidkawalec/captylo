import SwiftUI

/// "Twój styl" on Słownik: the style profile self-learning distills from the user's edits
/// (stage 4). Editable; the next distillation starts from what the user wrote here.
@MainActor
struct StylePanel: View {
    let learning: SelfLearning
    let aiEnabled: Bool

    @State private var draft = ""
    @State private var loaded = false

    private var profile: String { learning.store.data.styleProfile }
    private var pending: Int { learning.store.data.samplesSinceDistill }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Twój styl", systemImage: "text.quote") {
                if learning.isDistilling {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            ToolCaption("Captylo sam uzupełnia ten opis co kilka Twoich poprawek stylu: powitania, interpunkcję, ton. Działa z trybami AI. Możesz go dowolnie zmienić.")
            ToolTextArea(text: $draft, minHeight: 90, maxHeight: 180, label: Text("Twój styl"))
            HStack(spacing: 10) {
                ToolStatusLine(text: statusText)
                Spacer()
                if aiEnabled, pending > 0 {
                    Button("Zaktualizuj teraz") {
                        Task { await learning.distillStyle() }
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .disabled(learning.isDistilling)
                }
                if !profile.isEmpty {
                    Button("Wyczyść") {
                        draft = ""
                        learning.setStyleProfile("")
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
                Button("Zapisz") {
                    learning.setStyleProfile(draft)
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(draft == profile)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = profile
        }
        .onChange(of: profile) { old, fresh in
            // A distillation finished: show it unless the user has unsaved edits.
            if draft == old {
                draft = fresh
            }
        }
    }

    private var statusText: String {
        if !aiEnabled {
            return String(localized: "Włącz tryb AI, aby Captylo uczył się Twojego stylu.")
        }
        return String(localized: "Nowe poprawki stylu: \(pending) z \(StyleDistiller.batch) do następnej aktualizacji.")
    }
}
