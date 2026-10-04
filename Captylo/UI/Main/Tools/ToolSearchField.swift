import SwiftUI

/// Search field on the glass track with a magnifier glyph and a clear button.
@MainActor
struct ToolSearchField: View {
    var prompt: LocalizedStringKey
    @Binding var text: String

    init(_ prompt: LocalizedStringKey, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GlassColor.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(GlassColor.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Wyczyść wyszukiwanie"))
                .accessibilityLabel(Text("Wyczyść wyszukiwanie"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .glassSurface(.track, cornerRadius: GlassTokens.Radius.control - 2, shadow: false)
    }
}
