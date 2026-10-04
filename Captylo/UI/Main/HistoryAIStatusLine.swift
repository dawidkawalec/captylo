import SwiftUI

/// Status line of an expanded history row: violet sparkles and "AI: E-mail · model · 812 ms" when
/// AI produced text, an amber warning and "AI pominięte: <note>" when it did not, a quiet "Bez AI"
/// when it was off. White type on glass, like `ToolStatusLine`.
@MainActor
struct HistoryAIStatusLine: View {
    let status: HistoryAIStatus
    /// Symbol of the mode that ran (from the current mode list), sparkles when unknown.
    var modeSymbol: String = "sparkles"
    /// Two lines in an expanded row, one under the text of a collapsed row.
    var lineLimit: Int = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                // Brand violet is dark on the warm glass; lift it to a readable lilac.
                .brightness(status == .none ? 0 : 0.3)
                .accessibilityHidden(true)
            Text(verbatim: status.line)
                .font(GlassFont.caption)
                .foregroundStyle(textColor)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .glassTextShadow(0.18)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .enhanced: return modeSymbol
        case .skipped: return "exclamationmark.triangle.fill"
        case .none: return "circle.slash"
        }
    }

    private var iconColor: Color {
        switch status {
        case .enhanced: return GlassColor.accent
        case .skipped: return GlassColor.warning
        case .none: return GlassColor.textTertiary
        }
    }

    private var textColor: Color {
        switch status {
        case .enhanced, .skipped: return GlassColor.textPrimary
        case .none: return GlassColor.textSecondary
        }
    }
}
