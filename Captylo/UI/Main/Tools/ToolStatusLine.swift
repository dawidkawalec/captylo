import SwiftUI

/// Status line on glass under a control (key saved, test result, import error): a colored glyph
/// and white text, never black. The glass counterpart of `InlineStatus`, same tones.
@MainActor
struct ToolStatusLine: View {
    let text: String
    var tone: InlineStatus.Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(GlassFont.caption)
                .foregroundStyle(tone == .neutral ? GlassColor.textSecondary : GlassColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .neutral: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: return GlassColor.textSecondary
        case .success: return GlassColor.success
        case .error: return GlassColor.destructive
        }
    }
}
