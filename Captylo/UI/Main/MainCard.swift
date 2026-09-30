import SwiftUI

/// Rounded surface used by every main-window screen: system control background, hairline
/// border and a soft shadow, so it reads as native on macOS 14-26 next to the sidebar material.
@MainActor
struct MainCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VTSpacing.l) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: VTSpacing.xs) {
                    if let title {
                        HStack(spacing: VTSpacing.s) {
                            if let symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(VTColor.brandGradient)
                            }
                            Text(title)
                                .font(.headline)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(VTSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VTRadius.card, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VTRadius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

/// Scrollable page body shared by the screens: generous gutters and a comfortable max width.
@MainActor
struct MainPage<Content: View>: View {
    static var maxWidth: CGFloat { 960 }

    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VTSpacing.xl) {
                content
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .padding(VTSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Inline status line under a control: neutral, success or error tone.
@MainActor
struct InlineStatus: View {
    enum Tone {
        case neutral
        case success
        case error
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: VTSpacing.xs) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
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
        case .neutral: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }
}

/// Removable chip for vocabulary and filler words.
@MainActor
struct WordChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: VTSpacing.xs) {
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Usuń \(text)"))
        }
        .padding(.horizontal, VTSpacing.m)
        .padding(.vertical, VTSpacing.xs + 2)
        .background(
            Capsule(style: .continuous)
                .fill(VTColor.brandViolet.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(VTColor.brandViolet.opacity(0.25), lineWidth: 1)
        )
    }
}
