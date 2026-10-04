import SwiftUI

/// "Ikona" of the mode editor: a grid of glass tiles, the chosen one lit in brand violet.
@MainActor
struct AIModeSymbolGrid: View {
    @Binding var selection: String

    /// Two even rows of eight for the 16 offered symbols.
    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(AIModeSymbols.options(including: selection), id: \.self) { symbol in
                AIModeSymbolCell(symbol: symbol, isSelected: symbol == selection) {
                    withAnimation(GlassMotion.selection) {
                        selection = symbol
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ikona"))
    }
}

@MainActor
private struct AIModeSymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.8))
                .frame(width: 38, height: 38)
                .background {
                    if isSelected {
                        shape.fill(
                            LinearGradient(
                                colors: [GlassColor.accent.opacity(0.6), GlassColor.accent.opacity(0.38)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    } else {
                        shape.fill(Color.white.opacity(isHovered ? 0.14 : 0.06))
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        GlassColor.rim(top: isSelected ? 0.55 : 0.22, bottom: 0.05),
                        lineWidth: GlassTokens.Size.rimWidth
                    )
                }
                .shadow(color: GlassColor.accent.opacity(isSelected ? 0.45 : 0), radius: 8)
                .contentShape(shape)
        }
        .buttonStyle(ToolPressStyle())
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(Text(verbatim: AIModeSymbols.label(for: symbol)))
        .accessibilityLabel(Text(verbatim: AIModeSymbols.label(for: symbol)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
