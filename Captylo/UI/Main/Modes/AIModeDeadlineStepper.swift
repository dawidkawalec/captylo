import SwiftUI

/// "Limit czasu" of the mode editor: minus / value / plus on a glass capsule track, whole
/// seconds within `AIMode.deadlineRange` (1-20 s).
@MainActor
struct AIModeDeadlineStepper: View {
    @Binding var seconds: Double

    private var range: ClosedRange<Double> { AIMode.deadlineRange }

    var body: some View {
        HStack(spacing: 6) {
            ToolIconButton("minus", label: Text("Krótszy limit"), size: 26) {
                step(-1)
            }
            .disabled(seconds <= range.lowerBound)
            Text(AIMode.secondsLabel(seconds))
                .font(GlassFont.number(16))
                .foregroundStyle(GlassColor.textPrimary)
                .frame(minWidth: 46)
                .contentTransition(.numericText())
            ToolIconButton("plus", label: Text("Dłuższy limit"), size: 26) {
                step(1)
            }
            .disabled(seconds >= range.upperBound)
        }
        .padding(3)
        .glassSurface(.track, in: Capsule(), shadow: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Limit czasu"))
        .accessibilityValue(Text(AIMode.secondsLabel(seconds)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Double) {
        let base = seconds.isFinite ? seconds.rounded() : range.lowerBound
        withAnimation(GlassMotion.press) {
            seconds = min(max(base + delta, range.lowerBound), range.upperBound)
        }
    }
}
