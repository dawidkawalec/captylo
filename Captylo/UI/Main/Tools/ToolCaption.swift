import SwiftUI

/// Explanatory text under a section header or a row group: secondary white, wraps.
@MainActor
struct ToolCaption: View {
    var text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    init(verbatim string: String) {
        text = Text(verbatim: string)
    }

    init(text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(GlassFont.caption)
            .foregroundStyle(GlassColor.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
