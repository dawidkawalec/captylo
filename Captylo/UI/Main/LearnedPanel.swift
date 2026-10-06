import SwiftUI

/// "Nauczone" on Słownik: what self-learning picked up (heard -> meant), where it came from, and
/// whether it is a replacement rule or only a hint for AI. "Cofnij" removes the lesson and what
/// it added to the dictionary and never learns that pair again.
@MainActor
struct LearnedPanel: View {
    let learning: SelfLearning
    let isEnabled: Bool

    static let badgesWidth: CGFloat = 240

    @State private var confirmsReset = false

    private var entries: [LearnedTerm] {
        learning.store.data.learned.sorted { $0.learnedAt > $1.learnedAt }
    }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Nauczone", systemImage: "sparkles") {
                GlassBadge(title: Text(verbatim: "\(entries.count)"))
            }
            ToolCaption("Słowa, których Captylo nauczył się z Twoich poprawek, z \(GlobalShortcut.correction.display) i z literowania na głos. Reguła zamiany działa zawsze, podpowiedź pomaga tylko poprawianiu przez AI. Cofnięte słowo wróci tylko przez \(GlobalShortcut.correction.display) albo „Odblokuj” niżej.")
            if !isEnabled {
                ToolStatusLine(text: String(localized: "Nauka jest wyłączona w Ustawieniach. Nauczone słowa nadal działają."))
            }
            if entries.isEmpty {
                Text("Nic jeszcze. Zaznacz źle rozpoznane słowo i naciśnij \(GlobalShortcut.correction.display) albo przeliteruj je na głos, np. „Brzęk, pisane B R Z Ę K”.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            GlassRowSeparator()
                        }
                        row(entry)
                    }
                }
                GlassRowSeparator()
                HStack {
                    Spacer()
                    Button("Wyczyść naukę") {
                        confirmsReset = true
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
            }
        }
        .confirmationDialog("Wyczyścić wszystko, czego Captylo się nauczył?", isPresented: $confirmsReset) {
            Button("Wyczyść naukę", role: .destructive) {
                learning.resetAll()
            }
        } message: {
            Text("Nauczone reguły i słowa znikną ze słownika. Twoje własne wpisy zostaną.")
        }
    }

    private func row(_ entry: LearnedTerm) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: entry.pair.misheard)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GlassColor.textTertiary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(verbatim: entry.pair.correct)
                .font(GlassFont.body.weight(.semibold))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                switch entry.source {
                case .voice: GlassBadge("Literowanie", systemImage: "mic")
                case .manual: GlassBadge("Popraw", systemImage: "pencil.and.scribble")
                case .edit: GlassBadge("Poprawka", systemImage: "pencil")
                }
                GlassBadge(entry.ruleID != nil ? "Reguła" : "Podpowiedź AI", tone: entry.ruleID != nil ? .accent : .neutral)
                ToolIconButton("arrow.uturn.backward", label: Text("Cofnij"), size: 28) {
                    learning.undo(entry.id)
                }
            }
            // Fixed width, so the arrow column lines up whatever the badges say.
            .frame(width: Self.badgesWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
