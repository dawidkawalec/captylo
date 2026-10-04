import SwiftUI

/// Dense settings row of the expanded widget. Same look as `GlassRow` (outline icon, white title,
/// trailing value), but about 32 pt tall like the Mikrofon / Język transkrypcji rows of mockup 03:
/// `GlassRow`'s 46 pt minimum suits windows and would make the widget a third taller than the
/// mockup.
@MainActor
struct RecorderRow<Trailing: View>: View {
    var title: Text
    var subtitle: Text?
    var systemImage: String
    @ViewBuilder var trailing: Trailing

    static var height: CGFloat { 34 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(GlassColor.icon)
                .frame(width: GlassTokens.Size.rowIconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // Lighter than the live transcript title, like the row labels of mockup 03.
                title
                    .font(GlassFont.ui(13))
                    .foregroundStyle(GlassColor.textPrimary.opacity(0.85))
                    .lineLimit(1)
                if let subtitle {
                    subtitle
                        .font(GlassFont.ui(11))
                        .foregroundStyle(GlassColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .layoutPriority(1)
        }
        .glassTextShadow()
        .padding(.leading, 2)
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }
}

/// `RecorderRow` with the blue glass switch ("Automatycznie kopiuj transkrypcję").
@MainActor
struct RecorderToggleRow: View {
    var title: Text
    var systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        RecorderRow(title: title, systemImage: systemImage) {
            Toggle(isOn: $isOn) {
                title
            }
            .toggleStyle(.glassSwitchCompact)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}
