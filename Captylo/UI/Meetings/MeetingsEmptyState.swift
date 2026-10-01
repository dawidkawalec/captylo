import SwiftUI

/// Spotkania before the first meeting: one centered panel with what the section is for and
/// "Nagraj spotkanie". A nil `onRecord` shows the button disabled; `error` is why the last start
/// failed.
@MainActor
struct MeetingsEmptyState: View {
    var onRecord: (() -> Void)?
    var error: String?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            GlassPanel(padding: 32, alignment: .center, spacing: 12) {
                GlassIconBadge(systemImage: MainSection.spotkania.symbol, size: 52, tint: GlassColor.accent)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text("Tu pojawią się Twoje spotkania.")
                    .font(GlassFont.display(17))
                    .foregroundStyle(GlassColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Nagraj pierwsze, a Captylo zapisze, kto co powiedział.")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                MeetingRecordButton(action: onRecord)
                    .padding(.top, 8)
                if let error {
                    ToolStatusLine(text: error, tone: .error)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 440)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .mainColumnFrame(alignment: .center)
        .padding(.vertical, 24)
    }
}
