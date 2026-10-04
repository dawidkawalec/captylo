import SwiftUI

/// "Przetwórz przez AI": a small neutral glass capsule (like the other row actions) that opens the
/// list of AI modes; picking one runs the row's original text through it. Shows a spinner and
/// "Przetwarzam..." while a run is in flight and is disabled then.
@MainActor
struct HistoryReprocessMenu: View {
    let modes: [AIMode]
    let isProcessing: Bool
    let onPick: (AIMode) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button {
                    onPick(mode)
                } label: {
                    Label(mode.name, systemImage: mode.symbol)
                }
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isProcessing || modes.isEmpty)
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(Text("Przetwórz oryginał wybranym trybem AI"))
    }

    private var label: some View {
        let active = isEnabled && !isProcessing
        return HStack(spacing: 8) {
            if isProcessing {
                ProgressView()
                    .controlSize(.mini)
                Text("Przetwarzam...")
            } else {
                Image(systemName: "sparkles")
                Text("Przetwórz przez AI")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .font(GlassFont.button.weight(.medium))
        .foregroundStyle(Color.white.opacity(active ? 0.97 : 0.55))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: GlassTokens.Size.buttonHeightSmall)
        .background {
            Capsule().fill(Color.white.opacity(GlassTokens.Opacity.control + (isHovered && active ? 0.04 : 0)))
        }
        .overlay {
            Capsule().stroke(GlassColor.rim(top: 0.32, bottom: 0.06), lineWidth: GlassTokens.Size.rimWidth)
        }
        .contentShape(Capsule())
    }
}
