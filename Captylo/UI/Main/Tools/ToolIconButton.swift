import SwiftUI

/// Round icon-only glass button (copy, retry, remove, refresh). Always pass a label: it is the
/// tooltip and the VoiceOver name.
@MainActor
struct ToolIconButton: View {
    var systemImage: String
    var label: Text
    var size: CGFloat = 30
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    init(_ systemImage: String, label: Text, size: CGFloat = 30, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Color.white.opacity(isEnabled ? (isHovered ? 0.98 : 0.85) : 0.4))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(Color.white.opacity(isHovered && isEnabled ? 0.22 : GlassTokens.Opacity.control))
                }
                .overlay {
                    Circle().strokeBorder(GlassColor.rim(top: 0.32, bottom: 0.06), lineWidth: GlassTokens.Size.rimWidth)
                }
                .contentShape(Circle())
        }
        .buttonStyle(ToolPressStyle())
        .onHover { isHovered = $0 }
        .animation(GlassMotion.press, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Slight scale on press for hand-drawn glass buttons (respects Reduce Motion).
struct ToolPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolPressBody(configuration: configuration)
    }
}

@MainActor
private struct ToolPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : GlassMotion.press, value: configuration.isPressed)
    }
}
