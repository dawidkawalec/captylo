import SwiftUI

/// Text field on glass: recessed rounded track with a faint rim, white text, as tall as a small button.
/// `TextField("Klucz API", text: $key).textFieldStyle(.glass)`
struct GlassTextFieldStyle: TextFieldStyle {
    // `_body` is nonisolated, so it draws the `.track` surface inline instead of calling the
    // main-actor `glassSurface` modifier (same fills and rim, no Reduce Transparency variant needed:
    // the track is nearly opaque already).
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassTokens.Radius.control - 2, style: .continuous)
        return configuration
            .textFieldStyle(.plain)
            .font(GlassFont.body)
            .foregroundStyle(GlassColor.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: GlassTokens.Size.fieldHeight)
            .background(shape.fill(Color.black.opacity(GlassTokens.Opacity.track)))
            .background(shape.fill(Color.white.opacity(GlassTokens.Opacity.trackLift)))
            .overlay(shape.strokeBorder(GlassColor.rim(top: 0.06, bottom: 0.16), lineWidth: GlassTokens.Size.rimWidth))
    }
}

extension TextFieldStyle where Self == GlassTextFieldStyle {
    static var glass: GlassTextFieldStyle { GlassTextFieldStyle() }
}

/// Secure field on the same track, with an eye button that reveals the value (API keys).
@MainActor
struct GlassSecureField: View {
    var title: LocalizedStringKey
    @Binding var text: String
    @State private var isRevealed = false

    init(_ title: LocalizedStringKey, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(GlassFont.body)
            .foregroundStyle(GlassColor.textPrimary)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(GlassColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRevealed ? Text("Ukryj") : Text("Pokaż"))
            .accessibilityLabel(isRevealed ? Text("Ukryj") : Text("Pokaż"))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: GlassTokens.Size.fieldHeight)
        .glassSurface(.track, cornerRadius: GlassTokens.Radius.control - 2, shadow: false)
    }
}
