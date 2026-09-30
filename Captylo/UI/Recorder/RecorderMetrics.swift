import CoreGraphics
import Foundation

/// Sizes of the recorder widget (docs/design/dusk-glass.md, mockups 01 / 03 / 04) and the pure
/// geometry the panel controller uses for toasts and hover. The canvas is fixed and sized for
/// the expanded state; both states are bottom-anchored and horizontally centered inside it.
enum RecorderMetrics {
    // MARK: Orb

    /// The orb of the expanded header (mockups 03 / 04).
    static let orb: CGFloat = 64
    /// The compact widget's orb: smaller and quieter than the mockup's 64 pt, so the waveform and
    /// the timer carry the row instead of a big bubble (owner feedback).
    static let compactOrb: CGFloat = 46
    /// Mic glyph and record dot as fractions of the orb (27 pt and 7 pt on the 64 pt orb).
    static let orbGlyphRatio: CGFloat = 0.42
    static let recordDotRatio: CGFloat = 0.115

    static func orbGlyph(for orb: CGFloat) -> CGFloat { (orb * orbGlyphRatio).rounded() }
    static func recordDot(for orb: CGFloat) -> CGFloat { max(5, orb * recordDotRatio) }

    // MARK: Compact (mockup 01)

    // Orb, a free-floating waveform a bit wider than the orb and about 0.6 of its height, then
    // the small light timer. Fixed size so the row never shifts while it ticks.
    static let compactSize = CGSize(width: 184, height: 52)
    static let compactOrbToWaveform: CGFloat = 12
    static let compactWaveformToTimer: CGFloat = 14
    static let compactTimerWidth: CGFloat = 40
    static let compactTimerFont: CGFloat = 13
    /// Thin bars with gaps about 1.5x their width (airy, like mockup 01): 15 bars span 72 pt.
    static let compactBarWidth: CGFloat = 2
    static let compactBarGap: CGFloat = 3
    static let compactBarMaxHeight: CGFloat = 28

    static var compactWaveformWidth: CGFloat {
        CGFloat(WaveformMath.barCount) * compactBarWidth + CGFloat(WaveformMath.barCount - 1) * compactBarGap
    }

    // MARK: Backdrop halo (compact)

    /// ONE soft dark cloud behind all the free-floating marks of the compact widget (waveform,
    /// timer, status line), `RecorderBackdropHalo`: a grey bed under white type over a white
    /// document, barely visible over a dark desktop. Wide, low, heavily feathered, so it never
    /// reads as a smudge with an edge. Peak opacity of the blurred shape.
    /// The blur eats into a shape this low, so the peak is set for the core under the timer to
    /// land near 170 over a white window (white type with its tight outline stays readable).
    static let backdropOpacity: Double = 0.42
    /// How far the shape reaches past the marks before the blur. Kept short on the left so the
    /// cloud does not creep under the orb.
    static let backdropSpread = CGSize(width: 18, height: 16)
    static let backdropLeadingSpread: CGFloat = 8
    static let backdropBlur: CGFloat = 16
    /// Width of the status area the cloud covers under the waveform (the text itself is centered
    /// there, up to `compactStatusWidth`) and the height of one status line.
    static let backdropStatusWidth: CGFloat = 116
    static let compactStatusLineHeight: CGFloat = 15

    /// Status line (and the AI mode line) under the compact waveform: the widest it may get
    /// before a long mode name is truncated, and the gap below the bars.
    static let compactStatusWidth: CGFloat = 160
    static let compactStatusGap: CGFloat = 5

    /// The cloud's shape in the compact row's coordinates (origin top left, before the blur):
    /// the union of the waveform, the timer while it shows and the status lines under the
    /// waveform, plus the spread. One shape, so there is never a seam between two clouds.
    static func compactHaloRect(showsTimer: Bool, statusLines: Int) -> CGRect {
        let waveform = CGRect(
            x: compactOrb + compactOrbToWaveform,
            y: (compactSize.height - compactBarMaxHeight) / 2,
            width: compactWaveformWidth,
            height: compactBarMaxHeight
        )
        var rect = waveform
        if showsTimer {
            rect.size.width += compactWaveformToTimer + compactTimerWidth
        }
        if statusLines > 0 {
            let status = CGRect(
                x: waveform.midX - backdropStatusWidth / 2,
                y: waveform.maxY + compactStatusGap,
                width: backdropStatusWidth,
                height: CGFloat(statusLines) * compactStatusLineHeight
            )
            rect = rect.union(status)
        }
        return CGRect(
            x: rect.minX - backdropLeadingSpread,
            y: rect.minY - backdropSpread.height,
            width: rect.width + backdropLeadingSpread + backdropSpread.width,
            height: rect.height + backdropSpread.height * 2
        )
    }

    // MARK: Expanded (mockups 03 / 04)

    static let expandedWidth: CGFloat = 392
    static let headerHeight: CGFloat = 96
    static let headerRadius: CGFloat = 30
    /// Gap between the header capsule and the panel (they almost touch in the mockup).
    static let headerGap: CGFloat = 4
    /// Room for the live card, three menu rows (Mikrofon, Język transkrypcji, Tryb AI), the two
    /// switches and the buttons.
    static let panelHeight: CGFloat = 420
    static let panelPadding: CGFloat = 16
    static let panelSpacing: CGFloat = 8
    static let expandedBarWidth: CGFloat = 3
    static let expandedBarGap: CGFloat = 4
    static let expandedBarMaxHeight: CGFloat = 44
    static let expandedTimerFont: CGFloat = 24
    /// Height of the live text column (three lines of 14 pt).
    static let liveTextHeight: CGFloat = 64

    static var expandedSize: CGSize {
        CGSize(width: expandedWidth, height: headerHeight + headerGap + panelHeight)
    }

    // MARK: Canvas

    /// Transparent margin around the widget for glows and soft shadows. Deep enough for the
    /// feathered tail of the backdrop cloud under the compact two-line status ("Poprawiam z AI"
    /// + mode), which fades out about 70 pt below the compact row; less cuts the cloud with a
    /// straight edge.
    static let margin: CGFloat = 72
    /// Gap between the widget bottom and `visibleFrame.minY`.
    static let screenInset: CGFloat = 24

    static var canvas: CGSize {
        CGSize(width: expandedSize.width + margin * 2, height: expandedSize.height + margin * 2)
    }

    // MARK: Hover

    /// Dwell before the widget expands, so passing over it or going for the orb does not open it.
    static let expandDelay: Duration = .milliseconds(280)
    /// Grace period before it collapses, so a short slip past the edge keeps it open.
    static let collapseDelay: Duration = .milliseconds(450)
    /// Pointer check while the widget is on screen (backs up the tracking area events).
    static let pointerPoll: Duration = .milliseconds(150)
    /// The hover area is a little larger than the visible widget (hysteresis).
    static let compactHoverSlop: CGFloat = 8
    static let expandedHoverSlop: CGFloat = 14

    // MARK: Geometry

    /// Visible widget in canvas coordinates (AppKit, origin bottom left).
    static func visibleRect(expanded: Bool, canvas: CGSize = canvas) -> CGRect {
        let size = expanded ? expandedSize : compactSize
        return CGRect(
            x: ((canvas.width - size.width) / 2).rounded(),
            y: margin,
            width: size.width,
            height: size.height
        )
    }

    /// Area in which the pointer keeps (or makes) the widget expanded, canvas coordinates.
    static func hoverRect(expanded: Bool, canvas: CGSize = canvas) -> CGRect {
        let slop = expanded ? expandedHoverSlop : compactHoverSlop
        return visibleRect(expanded: expanded, canvas: canvas).insetBy(dx: -slop, dy: -slop)
    }

    /// Canvas origin on screen: horizontally centered, widget bottom `screenInset` above the
    /// bottom of `visibleFrame`.
    static func canvasOrigin(in visibleFrame: CGRect, canvas: CGSize = canvas) -> CGPoint {
        CGPoint(
            x: (visibleFrame.midX - canvas.width / 2).rounded(),
            y: (visibleFrame.minY + screenInset - margin).rounded()
        )
    }
}
