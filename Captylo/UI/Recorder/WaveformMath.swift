import Foundation

/// Pure bar-height formulas for the waveform: 15 bars in the compact widget (mockup 01),
/// 25 in the header of the expanded one (mockup 03). Both mockups show a bell: the center bar
/// is the tallest and the bars taper evenly to dots at both ends.
enum WaveformMath {
    /// Compact widget, mockup 01.
    static let barCount = 15
    /// Expanded widget header, mockup 03.
    static let expandedBarCount = 25
    static let minHeight: Double = 3
    static let maxHeight: Double = 34
    /// Width of the bell as a fraction of the bar count (gaussian `exp(-(d / (count * w))^2)`).
    /// Compact widget: narrow enough that only the center 3-5 bars stand tall and the outer ones
    /// are dots (mockup 01).
    static let envelopeWidth: Double = 0.16
    /// Expanded header: the wider, busier crest of mockup 03.
    static let expandedEnvelopeWidth: Double = 0.22

    /// Bell width for `count` bars: the long header row keeps the wider crest.
    static func envelopeWidth(count: Int) -> Double {
        count > barCount ? expandedEnvelopeWidth : envelopeWidth
    }
    /// While recording the bell never sinks below this share of its height, so quiet speech
    /// (and a breath between words) still shows the mockup shape instead of a row of dots.
    static let recordingFloor: Double = 0.35
    /// Phase offset between neighbouring bars of the travelling wave.
    static let phaseStep: Double = 0.7
    /// Processing: the calm swell stays this low.
    static let calmMaxHeight: Double = 9

    /// Middle of `count` bars (7 for 15 bars, 12 for 25).
    static func centerIndex(count: Int = barCount) -> Double {
        Double(max(count, 1) - 1) / 2
    }

    /// Height of bar `index` of `count` at `time` for a normalized 0...1 `level` while recording.
    ///
    /// `amp = floor + (1 - floor) * pow(level, 0.7) * wave`, `wave = sin(t*8 + i*0.7)*0.5 + 0.5`,
    /// `h = min + (max - min) * envelope(i) * amp`. The travelling wave only moves the part above
    /// the floor, so the bell stays whole and the bars shimmer inside it.
    /// With `animated == false` the wave is frozen at its crest (Reduce Motion).
    static func height(
        level: Float,
        index: Int,
        count: Int = barCount,
        time: TimeInterval,
        animated: Bool = true,
        maxHeight: Double = maxHeight,
        floor: Double = recordingFloor
    ) -> CGFloat {
        let clamped = Double(min(max(level, 0), 1))
        let speech = pow(clamped, 0.7)
        let wave = animated ? sin(time * 8 + Double(index) * phaseStep) * 0.5 + 0.5 : 1
        let amp = floor + (1 - floor) * speech * wave
        let height = minHeight + (maxHeight - minHeight) * envelope(index: index, count: count) * amp
        return CGFloat(min(max(minHeight, height), maxHeight))
    }

    /// Gaussian bell: 1.0 in the middle, about 0.01 at the outermost bars (dots), symmetric.
    static func envelope(index: Int, count: Int = barCount) -> Double {
        let center = centerIndex(count: count)
        guard center > 0 else { return 1 }
        let distance = min(abs(Double(index) - center), center)
        let spread = Double(count) * envelopeWidth(count: count)
        return exp(-pow(distance / spread, 2))
    }

    /// Transcribing / enhancing: a slow low swell drifting across the bars, never taller than
    /// `calmMaxHeight`. Flat dots with `animated == false` (Reduce Motion).
    static func calmHeight(index: Int, count: Int = barCount, time: TimeInterval, animated: Bool = true) -> CGFloat {
        guard animated else { return CGFloat(minHeight) }
        let swell = sin(time * 2.4 - Double(index) * 0.55) * 0.5 + 0.5
        let bell = 0.3 + 0.7 * envelope(index: index, count: count)
        return CGFloat(minHeight + swell * bell * (calmMaxHeight - minHeight))
    }

    /// The `time` at which bar `index` sits at the crest of its wave (for tests and previews).
    static func peakTime(index: Int) -> TimeInterval {
        (Double.pi / 2 - Double(index) * phaseStep) / 8
    }

    /// The `time` at which the calm swell crests on bar `index`.
    static func calmPeakTime(index: Int) -> TimeInterval {
        (Double.pi / 2 + Double(index) * 0.55) / 2.4
    }

    /// Level of the frozen design-preview frame: loud speech, so the snapshot shows the bell of
    /// mockups 01 / 03 with the center bar at about full height.
    static let stillFrameLevel: Float = 0.85
}

extension WaveformMath {
    /// Bar heights of one still frame with the center bar at its crest (design preview).
    static func stillHeight(index: Int, count: Int, recording: Bool, maxHeight: Double) -> CGFloat {
        let center = Int(centerIndex(count: count))
        if recording {
            return height(level: stillFrameLevel, index: index, count: count, time: peakTime(index: center), maxHeight: maxHeight)
        }
        return calmHeight(index: index, count: count, time: calmPeakTime(index: center))
    }
}
