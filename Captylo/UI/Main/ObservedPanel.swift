import AppKit
import SwiftUI

/// "Ostatnio zauważone" on Słownik: every correction Captylo saw lately and what it decided,
/// with the reason when it learned nothing ("Tylko wielka litera na początku zdania", "Ta
/// aplikacja nie pokazuje tekstu pola"). A pair undone before can be unblocked here.
@MainActor
struct ObservedPanel: View {
    let learning: SelfLearning
    let isEnabled: Bool

    /// Rows shown before "Pokaż wszystkie".
    static let collapsedCount = 8

    @State private var showsAll = false

    private var entries: [LearningObservation] {
        learning.store.data.observations.reversed()
    }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Ostatnio zauważone", systemImage: "eye") {
                GlassBadge(title: Text(verbatim: "\(entries.count)"))
            }
            ToolCaption("Poprawki, które Captylo zobaczył, i co z nimi zrobił. Gdy słowo nie zostało zapamiętane, zaznacz je w aplikacji i naciśnij \(GlobalShortcut.correction.display): wtedy Captylo nauczy się go od razu.")
            if !isEnabled {
                ToolStatusLine(text: String(localized: "Nauka jest wyłączona w Ustawieniach."))
            }
            if entries.isEmpty {
                Text("Nic jeszcze. Popraw coś w wklejonym tekście albo użyj \(GlobalShortcut.correction.display).")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let visible = showsAll ? entries : Array(entries.prefix(Self.collapsedCount))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            GlassRowSeparator()
                        }
                        row(entry)
                    }
                }
                GlassRowSeparator()
                HStack {
                    if entries.count > Self.collapsedCount {
                        Button(showsAll ? "Pokaż mniej" : "Pokaż wszystkie (\(entries.count))") {
                            showsAll.toggle()
                        }
                        .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    }
                    Spacer()
                    Button("Wyczyść listę") {
                        learning.clearObservations()
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
            }
        }
    }

    private func row(_ entry: LearningObservation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if entry.reason == .unreadable {
                    Text(verbatim: Self.appName(entry.appBundleID) ?? String(localized: "Nieznana aplikacja"))
                        .font(GlassFont.body.weight(.semibold))
                        .foregroundStyle(GlassColor.textPrimary)
                } else {
                    HStack(spacing: 8) {
                        Text(verbatim: entry.before)
                            .foregroundStyle(GlassColor.textSecondary)
                            .strikethrough(entry.outcome != .skipped, color: GlassColor.textTertiary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(GlassColor.textTertiary)
                            .accessibilityHidden(true)
                        Text(verbatim: entry.after)
                            .foregroundStyle(GlassColor.textPrimary)
                            .fontWeight(.semibold)
                    }
                    .font(GlassFont.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                Text(verbatim: detail(entry))
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if entry.reason == .blocked, learning.isBlocked(TermCorrection(misheard: entry.before, correct: entry.after)) {
                    Button("Odblokuj") {
                        learning.unblock(TermCorrection(misheard: entry.before, correct: entry.after))
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
                badge(entry)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func badge(_ entry: LearningObservation) -> some View {
        switch entry.outcome {
        case .rule: GlassBadge("Reguła", systemImage: "checkmark", tone: .accent)
        case .hint: GlassBadge("Podpowiedź AI", systemImage: "checkmark", tone: .neutral)
        case .skipped:
            if entry.reason == .alreadyKnown {
                GlassBadge("Znane", tone: .neutral)
            } else {
                GlassBadge("Pominięte", tone: .warning)
            }
        }
    }

    /// Why, where it came from and when: "Tylko wielka litera na początku zdania · Mail · 5 min temu".
    private func detail(_ entry: LearningObservation) -> String {
        var parts = [Self.reasonText(entry)]
        if entry.reason != .unreadable, let app = Self.appName(entry.appBundleID) {
            parts.append(app)
        }
        parts.append(entry.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    static func reasonText(_ entry: LearningObservation) -> String {
        let shortcut = GlobalShortcut.correction.display
        switch entry.outcome {
        case .rule:
            return entry.source == .manual
                ? String(localized: "Popraw: zapamiętane jako reguła zamiany")
                : String(localized: "Zapamiętane jako reguła zamiany")
        case .hint:
            return String(localized: "Zapamiętane jako podpowiedź dla AI (oba słowa istnieją)")
        case .skipped:
            switch entry.reason {
            case .rewrite?: return String(localized: "Zmieniła się większość tekstu: to przepisanie, nie poprawka")
            case .longChange?: return String(localized: "Zmiana dłuższa niż 3 słowa: trafia do profilu stylu")
            case .sentenceCase?: return String(localized: "Tylko wielka litera na początku zdania")
            case .ordinaryWords?: return String(localized: "Zwykłe słowa po obu stronach, wygląda na zmianę treści. Jeśli to źle rozpoznane słowo, użyj \(shortcut)")
            case .punctuation?: return String(localized: "Zmieniła się tylko interpunkcja")
            case .blocked?: return String(localized: "Cofnięte wcześniej, więc się tego nie uczę")
            case .alreadyKnown?: return String(localized: "Już to znam")
            case .unreadable?: return String(localized: "Ta aplikacja nie pokazuje tekstu pola, więc nie widzę tu poprawek. Użyj \(shortcut)")
            case nil: return String(localized: "Pominięte")
            }
        }
    }

    static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }
}
