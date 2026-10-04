import SwiftUI

/// Inset card inside a `GlassPanel` (the "Transkrypcja na żywo" card): radius 18, a slightly
/// darker recess (`.card`) or a lighter raised block (`.raised`), faint rim, no shadow.
@MainActor
struct GlassCard<Content: View>: View {
    enum Style: Sendable {
        case inset
        case raised
    }

    var style: Style
    var padding: CGFloat
    var cornerRadius: CGFloat
    var spacing: CGFloat
    @ViewBuilder var content: Content

    init(
        style: Style = .inset,
        padding: CGFloat = GlassTokens.Padding.card,
        cornerRadius: CGFloat = GlassTokens.Radius.card,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(style == .inset ? .card : .raised, cornerRadius: cornerRadius, shadow: false)
    }
}
