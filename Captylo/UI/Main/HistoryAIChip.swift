import SwiftUI

/// Tiny tag next to the chevron of a collapsed history row: violet "AI" when the row has an AI version, amber
/// "AI ✕" when a mode ran and produced nothing (the tooltip says why), nothing when AI was off.
@MainActor
struct HistoryAIChip: View {
    let status: HistoryAIStatus

    var body: some View {
        switch status {
        case .enhanced:
            chip(fill: GlassColor.accent.opacity(0.6), crossed: false)
                .help(Text(verbatim: status.line))
                .accessibilityLabel(Text("Ma wersję AI"))
        case .skipped:
            chip(fill: GlassColor.warning.opacity(0.55), crossed: true)
                .help(Text(verbatim: status.line))
                .accessibilityLabel(Text(verbatim: status.line))
        case .none:
            EmptyView()
        }
    }

    private func chip(fill: Color, crossed: Bool) -> some View {
        HStack(spacing: 3) {
            Text("AI")
            if crossed {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .heavy))
            }
        }
        .font(GlassFont.ui(10, .bold))
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(GlassColor.rim(top: 0.4, bottom: 0.08), lineWidth: 1))
        .fixedSize()
    }
}
