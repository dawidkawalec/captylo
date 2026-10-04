import SwiftUI

/// Small glass pill for states and tags ("Gotowy", "Szybki wybór", "3 dni").
@MainActor
struct GlassBadge: View {
    enum Tone: Sendable {
        case neutral
        case accent
        case success
        case warning
        case danger
    }

    var title: Text
    var systemImage: String?
    var tone: Tone

    init(_ title: LocalizedStringKey, systemImage: String? = nil, tone: Tone = .neutral) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tone = tone
    }

    init(title: Text, systemImage: String? = nil, tone: Tone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            title
                .lineLimit(1)
        }
        .font(GlassFont.badge)
        .foregroundStyle(Color.white.opacity(0.95))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background {
            Capsule().fill(fill)
        }
        .overlay {
            if tone == .success {
                // A lit green edge over a lighter fill: reads as "ready", not as a muted teal chip.
                Capsule().strokeBorder(GlassColor.success.opacity(0.6), lineWidth: 1)
            } else {
                Capsule().strokeBorder(GlassColor.rim(top: 0.4, bottom: 0.08), lineWidth: 1)
            }
        }
        .fixedSize()
    }

    private var fill: Color {
        switch tone {
        case .neutral: return Color.white.opacity(GlassTokens.Opacity.control)
        case .accent: return GlassColor.accent.opacity(0.55)
        case .success: return GlassColor.success.opacity(0.3)
        case .warning: return GlassColor.warning.opacity(0.5)
        case .danger: return GlassColor.destructive.opacity(0.55)
        }
    }
}
