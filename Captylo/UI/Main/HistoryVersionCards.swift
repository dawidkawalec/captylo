import SwiftUI

/// Texts of an expanded history row: "Oryginał" (what the speech engine heard, after the
/// dictionary) and "Po AI · <tryb>" side by side, stacked when the row is narrow. Each card has
/// its own copy button, so the owner can compare and take either version. While a
/// "Przetwórz przez AI" run is in flight the AI card shows its progress.
@MainActor
struct HistoryVersionCards: View {
    let original: String
    let aiText: String?
    /// Mode that produced `aiText`, nil for rows saved before AI modes.
    let aiModeName: String?
    let aiModeSymbol: String
    /// Name of the mode a "Przetwórz przez AI" run is using right now.
    let processingMode: String?
    let onCopy: (String) -> Void

    var body: some View {
        HistoryVersionLayout(minColumnWidth: 250, spacing: 10) {
            HistoryVersionCard(
                title: Text("Oryginał"),
                systemImage: "waveform",
                text: original,
                copyLabel: Text("Kopiuj oryginał"),
                onCopy: onCopy
            )
            if let processingMode {
                HistoryVersionCard(
                    title: Text("Po AI · \(processingMode)"),
                    systemImage: aiModeSymbol,
                    text: nil,
                    copyLabel: Text("Kopiuj wersję AI"),
                    isAI: true,
                    onCopy: onCopy
                )
            } else if let aiText {
                HistoryVersionCard(
                    title: aiTitle,
                    systemImage: aiModeSymbol,
                    text: aiText,
                    copyLabel: Text("Kopiuj wersję AI"),
                    isAI: true,
                    onCopy: onCopy
                )
            }
        }
    }

    private var aiTitle: Text {
        if let aiModeName {
            return Text("Po AI · \(aiModeName)")
        }
        return Text("Po AI")
    }
}

/// One version: small header (icon, title, copy) over the selectable text. The AI card carries a
/// faint violet rim so the two read apart at a glance. `text == nil` = the AI run in progress.
@MainActor
private struct HistoryVersionCard: View {
    let title: Text
    let systemImage: String
    let text: String?
    let copyLabel: Text
    var isAI = false
    let onCopy: (String) -> Void

    var body: some View {
        GlassCard(style: .inset, padding: 14, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isAI ? GlassColor.accent : GlassColor.textSecondary)
                    // Brand violet is dark on the warm glass; lift it to a readable lilac.
                    .brightness(isAI ? 0.3 : 0)
                    .accessibilityHidden(true)
                title
                    .font(GlassFont.caption.weight(.semibold))
                    .foregroundStyle(GlassColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let text, !text.isEmpty {
                    ToolIconButton("doc.on.doc", label: copyLabel, size: 24) {
                        onCopy(text)
                    }
                }
            }
            .frame(minHeight: 24)
            Group {
                if let text {
                    Text(text)
                        .font(GlassFont.body)
                        .lineSpacing(3)
                        .foregroundStyle(GlassColor.textPrimary)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Przetwarzam przez AI...")
                            .font(GlassFont.body)
                            .foregroundStyle(GlassColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if isAI {
                RoundedRectangle(cornerRadius: GlassTokens.Radius.card, style: .continuous)
                    .strokeBorder(GlassColor.accent.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
