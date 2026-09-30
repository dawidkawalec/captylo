import SwiftUI

/// Multi-line editor on the recessed glass track (the AI prompt): white monospaced text, no
/// system background.
@MainActor
struct ToolTextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 140
    var maxHeight: CGFloat = 240
    var label: Text

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(GlassColor.textPrimary)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .glassSurface(.track, cornerRadius: GlassTokens.Radius.control, shadow: false)
            .accessibilityLabel(label)
    }
}
