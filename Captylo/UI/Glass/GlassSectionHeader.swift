import SwiftUI

/// Section title with a thin line icon on the left ("Transkrypcja na żywo"), optional trailing
/// content (a badge, a small button). Semibold 15 pt, white.
@MainActor
struct GlassSectionHeader<Trailing: View>: View {
    var title: Text
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: LocalizedStringKey, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    /// For titles already localized at the call site (`String(localized:)`, model values).
    init(title: Text, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(GlassColor.icon)
                    .frame(width: 22)
            }
            title
                .font(GlassFont.sectionTitle)
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(1)
                .glassTextShadow()
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension GlassSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }

    init(title: Text, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}
