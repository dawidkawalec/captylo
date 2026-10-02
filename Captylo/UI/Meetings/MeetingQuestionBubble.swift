import SwiftUI

/// A question the user asked, on the right in a small raised glass bubble: the "Zapytaj" tab and
/// the "Zapytaj wszystkie spotkania" panel.
@MainActor
struct MeetingQuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(verbatim: text)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassSurface(.raised, cornerRadius: 14, shadow: false)
        }
    }
}
