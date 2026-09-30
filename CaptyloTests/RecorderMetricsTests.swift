import CoreGraphics
import Foundation
import Testing
@testable import Captylo

struct RecorderMetricsTests {
    @Test func canvasFitsTheExpandedWidgetWithMargins() {
        let canvas = RecorderMetrics.canvas
        let expanded = RecorderMetrics.expandedSize
        #expect(canvas.width == expanded.width + RecorderMetrics.margin * 2)
        #expect(canvas.height == expanded.height + RecorderMetrics.margin * 2)
        #expect(RecorderMetrics.compactSize.width < expanded.width)
        #expect(RecorderMetrics.compactSize.height < expanded.height)
    }

    @Test func bothStatesAreBottomAnchoredAndCentered() {
        let canvas = RecorderMetrics.canvas
        for expanded in [false, true] {
            let rect = RecorderMetrics.visibleRect(expanded: expanded)
            #expect(rect.minY == RecorderMetrics.margin)
            #expect(abs(rect.midX - canvas.width / 2) <= 0.5)
        }
        let compact = RecorderMetrics.visibleRect(expanded: false)
        let expanded = RecorderMetrics.visibleRect(expanded: true)
        #expect(expanded.contains(compact), "the expanded widget covers the compact one, so hover survives the morph")
    }

    @Test func hoverAreaIsSlightlyLargerThanTheWidget() {
        for expanded in [false, true] {
            let visible = RecorderMetrics.visibleRect(expanded: expanded)
            let hover = RecorderMetrics.hoverRect(expanded: expanded)
            #expect(hover.contains(visible))
            #expect(hover.width > visible.width)
            #expect(hover.height > visible.height)
        }
        // The compact hover area never reaches the transparent top of the canvas.
        let compactHover = RecorderMetrics.hoverRect(expanded: false)
        #expect(compactHover.maxY < RecorderMetrics.visibleRect(expanded: true).maxY)
        #expect(!compactHover.contains(CGPoint(x: RecorderMetrics.canvas.width / 2, y: RecorderMetrics.canvas.height - 10)))
    }

    @Test func canvasOriginPutsTheWidgetAboveTheScreenBottom() {
        let visibleFrame = CGRect(x: 0, y: 80, width: 1512, height: 900)
        let origin = RecorderMetrics.canvasOrigin(in: visibleFrame)
        let widgetBottom = origin.y + RecorderMetrics.margin
        #expect(widgetBottom == visibleFrame.minY + RecorderMetrics.screenInset)
        #expect(abs(origin.x + RecorderMetrics.canvas.width / 2 - visibleFrame.midX) <= 0.5)
    }

    @Test func compactRowFitsTheSmallerOrbWaveformAndTimer() {
        let row = RecorderMetrics.compactOrb + RecorderMetrics.compactOrbToWaveform
            + RecorderMetrics.compactWaveformWidth + RecorderMetrics.compactWaveformToTimer
            + RecorderMetrics.compactTimerWidth
        #expect(row <= RecorderMetrics.compactSize.width)
        #expect(RecorderMetrics.compactOrb <= RecorderMetrics.compactSize.height)
        #expect(RecorderMetrics.compactOrb < RecorderMetrics.orb)
        #expect(RecorderMetrics.orbGlyph(for: RecorderMetrics.orb) == 27)
        #expect(RecorderMetrics.recordDot(for: RecorderMetrics.compactOrb) >= 5)
    }

    @Test func oneHaloCoversEveryVisibleMarkAndKeepsOffTheOrb() {
        let waveformMinX = RecorderMetrics.compactOrb + RecorderMetrics.compactOrbToWaveform
        let timerMaxX = waveformMinX + RecorderMetrics.compactWaveformWidth
            + RecorderMetrics.compactWaveformToTimer + RecorderMetrics.compactTimerWidth

        let recording = RecorderMetrics.compactHaloRect(showsTimer: true, statusLines: 0)
        #expect(recording.maxX > timerMaxX)
        #expect(recording.minX > RecorderMetrics.compactOrb / 2, "the cloud stays off the orb's center")

        let processing = RecorderMetrics.compactHaloRect(showsTimer: false, statusLines: 2)
        #expect(processing.maxX < timerMaxX)
        #expect(processing.maxY > recording.maxY + 2 * RecorderMetrics.compactStatusLineHeight - 1)

        // The feathered tail of the deepest shape stays inside the canvas margin.
        let belowRow = processing.maxY - RecorderMetrics.compactSize.height
        #expect(belowRow + RecorderMetrics.backdropBlur * 2 <= RecorderMetrics.margin)
    }
}
