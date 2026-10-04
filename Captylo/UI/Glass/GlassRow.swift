import SwiftUI

/// One settings row as in the mockup ("Mikrofon ... MacBook Pro (Wbudowany) ⌄"): outline icon and
/// title (optional subtitle) on the left, trailing content (a `GlassRowValue`, `GlassMenuValue`,
/// a switch, a button) on the right. 46 pt minimum height. Separate groups with
/// `GlassRowSeparator`, not every row.
@MainActor
struct GlassRow<Trailing: View>: View {
    var title: Text
    var subtitle: Text?
    var systemImage: String?
    /// Draws the icon in a `GlassIconBadge` (32 pt) instead of a bare line glyph: rows that stand
    /// for an item (a permission, a model), not a setting.
    var iconBadge = false
    @ViewBuilder var trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    /// For texts already localized at the call site.
    init(
        title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        iconBadge: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconBadge = iconBadge
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                if iconBadge {
                    GlassIconBadge(systemImage: systemImage, size: GlassTokens.Size.rowBadge)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: GlassTokens.Size.rowIcon, weight: .regular))
                        .foregroundStyle(GlassColor.icon)
                        .frame(width: GlassTokens.Size.rowIconColumn)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(GlassFont.rowTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                if let subtitle {
                    subtitle
                        .font(GlassFont.rowSubtitle)
                        .foregroundStyle(GlassColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Keeps secondary white crisp where the panel sits over the bright horizon band.
            .glassTextShadow()
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .frame(minHeight: GlassTokens.Size.rowMinHeight)
        .contentShape(Rectangle())
    }
}

extension GlassRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// Hairline white 12 % line between row groups. `inset` indents it past the row icon.
@MainActor
struct GlassRowSeparator: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(GlassColor.separator)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// Trailing value of a row: secondary text plus an optional chevron (down for menus, right for
/// navigation), as in "Polski ⌄".
@MainActor
struct GlassRowValue: View {
    enum Chevron: Sendable {
        case none
        case down
        case right
    }

    var text: Text
    var chevron: Chevron

    init(_ value: String, chevron: Chevron = .none) {
        text = Text(verbatim: value)
        self.chevron = chevron
    }

    init(text: Text, chevron: Chevron = .none) {
        self.text = text
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: 8) {
            text
                .font(GlassFont.rowValue)
                .foregroundStyle(GlassColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            switch chevron {
            case .none:
                EmptyView()
            case .down:
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GlassColor.textSecondary)
            case .right:
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GlassColor.textTertiary)
            }
        }
        .glassTextShadow()
    }
}

/// A row's trailing menu: shows the current value with a down chevron and opens `content`
/// (Buttons / Pickers) on click, like the Mikrofon and Język transkrypcji rows.
@MainActor
struct GlassMenuValue<MenuContent: View>: View {
    var value: String
    @ViewBuilder var content: MenuContent

    init(_ value: String, @ViewBuilder content: () -> MenuContent) {
        self.value = value
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            GlassRowValue(value, chevron: .down)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
