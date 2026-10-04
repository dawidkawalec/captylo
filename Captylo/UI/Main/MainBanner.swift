import SwiftUI

/// One warning strip: tinted icon badge, the message, its actions on the right. Real glass above
/// a screen (`MainBanners`); inside a panel (the live meeting's warnings) it takes the `.raised`
/// surface, because glass never sits on glass.
@MainActor
struct MainBanner<Actions: View>: View {
    enum Tone {
        case warning
        case danger

        var color: Color {
            switch self {
            case .warning: return GlassColor.warning
            case .danger: return GlassColor.destructive
            }
        }
    }

    let symbol: String
    let tone: Tone
    let text: String
    var surface: GlassSurfaceKind = .panel
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            GlassIconBadge(systemImage: symbol, size: 28, tint: tone.color)
            Text(text)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                actions
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(surface, cornerRadius: GlassTokens.Radius.card, tint: tone.color.opacity(0.5), shadow: surface == .panel)
        .accessibilityElement(children: .contain)
    }
}
