import SwiftUI

/// Header at the top of a step panel: violet glass icon badge, white title and one explanatory
/// sentence in secondary white, optional trailing content (the keycap of the Wypróbuj step).
@MainActor
struct OnboardingHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(symbol: String, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            GlassIconBadge(systemImage: symbol, size: 48, tint: VTColor.brandViolet)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(GlassFont.pageTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle)
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension OnboardingHeader where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}
