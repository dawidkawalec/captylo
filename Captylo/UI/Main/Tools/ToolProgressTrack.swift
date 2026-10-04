import SwiftUI

/// Thin glass progress capsule: recessed track with a brand-gradient fill. `value` nil draws an
/// indeterminate sheen that slides across (a static partial fill with Reduce Motion).
@MainActor
struct ToolProgressTrack: View {
    var value: Double?
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(GlassTokens.Opacity.track))
                    .overlay { Capsule().fill(Color.white.opacity(0.08)) }
                if let value {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, width * min(max(value, 0), 1)))
                        .shadow(color: GlassColor.accent.opacity(0.6), radius: 6)
                        .animation(GlassMotion.spring, value: value)
                } else if reduceMotion {
                    Capsule().fill(fill).frame(width: width * 0.35)
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule()
                            .fill(fill)
                            .frame(width: width * 0.35)
                            .offset(x: (width * 1.35) * phase - width * 0.35)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
        .overlay { Capsule().strokeBorder(GlassColor.rim(top: 0.08, bottom: 0.2), lineWidth: 0.5) }
        .accessibilityElement()
        .accessibilityValue(value.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: ""))
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.95), GlassColor.accent], startPoint: .leading, endPoint: .trailing)
    }
}
