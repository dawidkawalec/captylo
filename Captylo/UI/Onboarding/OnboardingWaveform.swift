import SwiftUI

/// A small free-floating waveform (the bars of mockup 01): white rounded bars, the center tallest,
/// the edges down to dots, with a soft white glow. Idles on its own (no audio involved); Reduce
/// Motion freezes it on the resting shape.
@MainActor
struct OnboardingWaveform: View {
    var barCount = 15
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 4
    var maxHeight: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: barWidth, height: height(of: index, at: time))
                }
            }
            .frame(height: maxHeight)
        }
        .shadow(color: Color.white.opacity(0.55), radius: 4)
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 2)
        .accessibilityHidden(true)
    }

    /// Bell envelope (center tallest) times a slow per-bar breathing, never below a dot.
    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = (Double(index) - center) / (center * 0.62)
        let envelope = exp(-distance * distance)
        let phase = Double(index) * 0.9
        let speed = 2.1 + Double(index % 4) * 0.35
        let breathing = reduceMotion ? 0.8 : 0.62 + 0.38 * (0.5 + 0.5 * sin(time * speed + phase))
        let value = CGFloat(envelope * breathing) * maxHeight
        return max(barWidth, value)
    }
}
