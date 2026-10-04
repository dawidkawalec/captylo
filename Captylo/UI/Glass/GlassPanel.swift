import SwiftUI

/// Big frosted panel (mockup 03, the lower part of the expanded widget): radius 28, generous
/// padding, luminous rim, soft shadow. Liquid Glass on macOS 26, material fallback below.
/// Put every content block of a Dusk window in one; nest `GlassCard`s, never another panel.
@MainActor
struct GlassPanel<Content: View>: View {
    var padding: CGFloat
    var cornerRadius: CGFloat
    var tint: Color?
    var alignment: HorizontalAlignment
    var spacing: CGFloat
    @ViewBuilder var content: Content

    init(
        padding: CGFloat = GlassTokens.Padding.panel,
        cornerRadius: CGFloat = GlassTokens.Radius.panel,
        tint: Color? = nil,
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .glassSurface(.panel, cornerRadius: cornerRadius, tint: tint)
    }
}
