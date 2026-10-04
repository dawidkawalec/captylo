import SwiftUI

/// The orb of mockups 01 / 03 (64 pt in the expanded header, a quieter 46 pt in the compact
/// widget): a bubble with an inner highlight, a luminous rim and a white mic glyph; the glowing
/// red dot sits on the rim at the upper right while recording, a pause glyph shows while paused,
/// and a slow white arc circles inside the rim while the take is transcribed or polished. The
/// glyph, the dot and the arc scale with `size`. Tap = stop.
///
/// The glass itself comes from the caller: the compact widget wraps the orb in real glass
/// (`recorderGlass(.orb)`), the expanded header draws it as a plain translucent bubble
/// (`isGlass == false`) because glass never sits on glass.
@MainActor
struct OrbButton: View {
    let phase: DictationPhase
    /// False inside the header capsule: the orb then paints its own translucent fill.
    var isGlass: Bool = true
    var size: CGFloat = RecorderMetrics.orb
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    /// 1 on the 64 pt header orb; shadows and strokes follow the size.
    private var scale: CGFloat { size / RecorderMetrics.orb }

    var body: some View {
        Button(action: action) {
            ZStack {
                bubble
                glyph
                if phase.isProcessing {
                    OrbSpinner(size: size)
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(OrbPressStyle())
        .overlay(alignment: .topTrailing) {
            if phase == .recording {
                recordDot
                    // On the rim at about 45 degrees, like the mockup.
                    .offset(x: -size * 0.1, y: size * 0.1)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(!phase.isProcessing)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeOut(duration: 0.18), value: phase)
    }

    // MARK: Layers

    private var bubble: some View {
        ZStack {
            // Milky but clear body: the wallpaper stays visible through the bubble (mockup 01).
            Circle().fill(Color.white.opacity(isGlass ? 0.10 : 0.14))
            // Inner highlight: a soft white bloom in the upper left quadrant, like light caught
            // in a glass bead.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.06), .clear],
                        center: UnitPoint(x: 0.3, y: 0.24),
                        startRadius: 0,
                        endRadius: size * 0.5
                    )
                )
            // Soft glow along the lower edge.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.clear, .clear, Color.white.opacity(0.14)],
                        center: UnitPoint(x: 0.5, y: 0.35),
                        startRadius: 0,
                        endRadius: size * 0.62
                    )
                )
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.85), Color.white.opacity(0.25), Color.white.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5 * max(scale, 0.8)
                )
        }
        // Compact: a soft, low lift (the orb floats over any app and a dark drop read as a
        // smudge under it on white windows). Header: the mockup 03 shadow on its glass.
        .shadow(
            color: Color.black.opacity(isGlass ? 0.13 : 0.12),
            radius: isGlass ? 8 * scale : 10,
            y: isGlass ? 2 * scale : 4
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var glyph: some View {
        Image(systemName: phase == .paused ? "pause.fill" : "mic.fill")
            .font(.system(size: RecorderMetrics.orbGlyph(for: size), weight: .medium))
            .foregroundStyle(Color.white.opacity(phase.isProcessing ? 0.7 : 0.96))
            // The bubble is clear, so over a white window the glyph needs its own halo.
            .glassFloatingHalo()
            .contentTransition(.symbolEffect(.replace))
    }

    private var recordDot: some View {
        Circle()
            .fill(VTColor.recordRed)
            .frame(width: RecorderMetrics.recordDot(for: size), height: RecorderMetrics.recordDot(for: size))
            // Flat red with a soft glow, no bead highlight (mockup 01).
            .shadow(color: VTColor.recordRed.opacity(0.8), radius: 6 * scale)
            .scaleEffect(pulsing && !reduceMotion ? 1.18 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: VTMotion.recordDotPulsePeriod / 2)
                        .repeatForever(autoreverses: true)
                ) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        switch phase {
        case .recording, .paused:
            return String(localized: "Zakończ nagrywanie")
        case .transcribing, .enhancing:
            return String(localized: "Przetwarzanie")
        case .idle:
            return String(localized: "Mikrofon")
        }
    }
}

/// Slow white arc circling just inside the rim (transcribing, enhancing). Reduce Motion: a
/// still arc that breathes in opacity instead of turning.
@MainActor
private struct OrbSpinner: View {
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let turn = reduceMotion ? 0 : (time.truncatingRemainder(dividingBy: 1.4) / 1.4) * 360
            let breathe = reduceMotion ? 0.55 + 0.35 * (sin(time * 2.2) * 0.5 + 0.5) : 1
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(
                    AngularGradient(
                        colors: [Color.white.opacity(0), Color.white.opacity(0.95)],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(108)
                    ),
                    style: StrokeStyle(lineWidth: max(1.8, size * 0.0375), lineCap: .round)
                )
                .rotationEffect(.degrees(turn - 90))
                .opacity(breathe)
                .shadow(color: Color.white.opacity(0.6), radius: 3)
        }
        .padding(size * 0.078)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Gentle press feedback for the orb.
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(GlassMotion.press, value: configuration.isPressed)
    }
}
