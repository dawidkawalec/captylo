import SwiftUI

/// Slim warning panel on the wallpaper (dictionary file damaged, save failed): orange icon badge,
/// title, message and small glass buttons on the right.
@MainActor
struct ToolNoticePanel<Actions: View>: View {
    var title: Text
    var message: Text
    var systemImage: String
    @ViewBuilder var actions: Actions

    init(title: Text, message: Text, systemImage: String = "exclamationmark.triangle", @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        GlassPanel(padding: 16, tint: GlassColor.warning.opacity(0.10)) {
            HStack(alignment: .top, spacing: 14) {
                GlassIconBadge(systemImage: systemImage, size: 34, tint: GlassColor.warning)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(GlassFont.sectionTitle)
                        .foregroundStyle(GlassColor.textPrimary)
                    message
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        actions
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
