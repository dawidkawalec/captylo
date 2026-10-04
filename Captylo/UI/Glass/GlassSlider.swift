import SwiftUI

/// Thin white track with a round knob over an integer range, in whole steps (the settings
/// sliders in "Wygląd"). Same look as the audio player's scrubber. VoiceOver sees a standard
/// slider (`accessibilityRepresentation`), so adjusting it works like the system control.
@MainActor
struct GlassSlider: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDragging = false

    private var span: Double { Double(max(range.upperBound - range.lowerBound, 1)) }
    private var fraction: Double { Double(value - range.lowerBound) / span }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knob: CGFloat = isHovered || isDragging ? 14 : 12
            let x = CGFloat(fraction) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: max(4, x), height: 4)
                    .shadow(color: .white.opacity(0.35), radius: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: min(max(x - knob / 2, 0), width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        set(fraction: drag.location.x / width)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered || isDragging)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }

    private func set(fraction: Double) {
        let raw = Double(range.lowerBound) + min(max(fraction, 0), 1) * span
        let stepped = Int((raw / Double(step)).rounded()) * step
        let next = min(max(stepped, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }
}
