import SwiftUI

/// Free-floating white waveform (mockups 01 / 03): rounded bars with a soft white glow and a
/// faint dark halo for legibility over bright content, no container. Recording pulls the level
/// per frame inside a `TimelineView` (never an observed 60 Hz property); transcribing and
/// enhancing show a calm low swell; paused and idle show dots.
@MainActor
struct WaveformView: View {
    let level: any LevelSource
    let phase: DictationPhase
    var barCount: Int = WaveformMath.barCount
    var barWidth: CGFloat = RecorderMetrics.compactBarWidth
    var barGap: CGFloat = RecorderMetrics.compactBarGap
    var maxHeight: CGFloat = RecorderMetrics.compactBarMaxHeight
    /// Design preview: one still frame with the center bar at its crest, so snapshots show the
    /// mockup shape instead of whatever the fake level was at capture time.
    var isStill: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(max(barCount - 1, 0)) * barGap
    }

    private var isLive: Bool { phase == .recording }
    private var isCalm: Bool { phase.isProcessing }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: isStill || !(isLive || (isCalm && !reduceMotion)))) { context in
            let now = ProcessInfo.processInfo.systemUptime
            let currentLevel = isLive ? level.read(now: now) : 0
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barGap) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(width: barWidth, height: barHeight(index: index, level: currentLevel, time: time))
                }
            }
        }
        .frame(width: width, height: maxHeight)
        .opacity(phase == .paused || phase == .idle ? 0.55 : 0.96)
        .compositingGroup()
        .shadow(color: Color.white.opacity(0.55), radius: 3)
        .glassFloatingHalo()
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, level: Float, time: TimeInterval) -> CGFloat {
        if isStill, isLive || isCalm {
            return WaveformMath.stillHeight(index: index, count: barCount, recording: isLive, maxHeight: Double(maxHeight))
        }
        if isLive {
            return WaveformMath.height(
                level: level,
                index: index,
                count: barCount,
                time: time,
                animated: !reduceMotion,
                maxHeight: Double(maxHeight)
            )
        }
        if isCalm {
            return WaveformMath.calmHeight(index: index, count: barCount, time: time, animated: !reduceMotion)
        }
        return CGFloat(WaveformMath.minHeight)
    }
}
