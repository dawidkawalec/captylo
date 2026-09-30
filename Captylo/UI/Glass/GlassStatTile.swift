import SwiftUI

/// Stat tile of the Pulpit: icon badge, big light number with monospaced digits, label.
/// `surface: .panel` for tiles standing on the wallpaper, `.raised` inside a `GlassPanel`.
@MainActor
struct GlassStatTile: View {
    var title: Text
    var value: String
    var systemImage: String
    var tint: Color?
    var surface: GlassSurfaceKind

    init(_ title: LocalizedStringKey, value: String, systemImage: String, tint: Color? = nil, surface: GlassSurfaceKind = .panel) {
        self.title = Text(title)
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.surface = surface
    }

    init(title: Text, value: String, systemImage: String, tint: Color? = nil, surface: GlassSurfaceKind = .panel) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.surface = surface
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassIconBadge(systemImage: systemImage, size: 28, tint: tint)
            Text(verbatim: value)
                .font(GlassFont.number(30))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            title
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GlassTokens.Padding.tile)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(surface, cornerRadius: GlassTokens.Radius.tile)
        .accessibilityElement(children: .combine)
    }
}
