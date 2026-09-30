import Foundation
import Testing
@testable import Captylo

struct RecorderWaveformMathTests {
    @Test func compactAndExpandedBarCountsFollowTheMockups() {
        #expect(WaveformMath.barCount == 15)
        #expect(WaveformMath.expandedBarCount == 25)
        #expect(WaveformMath.centerIndex() == 7)
        #expect(WaveformMath.centerIndex(count: 25) == 12)
    }

    @Test func silenceStillShowsTheBellAtTheRecordingFloor() {
        for count in [WaveformMath.barCount, WaveformMath.expandedBarCount] {
            let center = Int(WaveformMath.centerIndex(count: count))
            for time in stride(from: 0.0, through: 2.0, by: 0.137) {
                let middle = WaveformMath.height(level: 0, index: center, count: count, time: time)
                // 3 + 31 * 0.35
                #expect(abs(middle - 13.85) < 0.001)
                #expect(middle >= 0.35 * WaveformMath.maxHeight)
                // The outermost bars stay dots.
                #expect(WaveformMath.height(level: 0, index: 0, count: count, time: time) < 3.2)
                #expect(WaveformMath.height(level: 0, index: count - 1, count: count, time: time) < 3.2)
            }
        }
    }

    @Test func withoutTheFloorSilenceIsDots() {
        for index in 0..<WaveformMath.barCount {
            #expect(WaveformMath.height(level: 0, index: index, time: 0.4, floor: 0) == 3)
        }
    }

    @Test func fullLevelCenterBarReachesMaximum() {
        let center = 7
        let height = WaveformMath.height(level: 1, index: center, time: WaveformMath.peakTime(index: center))
        #expect(abs(height - 34) < 0.001)

        let expanded = WaveformMath.height(
            level: 1,
            index: 12,
            count: 25,
            time: WaveformMath.peakTime(index: 12),
            maxHeight: 44
        )
        #expect(abs(expanded - 44) < 0.001)
    }

    @Test func fullLevelNeverExceedsMaximumOrDropsBelowMinimum() {
        for index in 0..<WaveformMath.barCount {
            for time in stride(from: 0.0, through: 1.0, by: 0.01) {
                let height = WaveformMath.height(level: 1, index: index, time: time)
                #expect(height >= 3)
                #expect(height <= 34.0001)
            }
        }
    }

    @Test func envelopeIsABellThatTapersToDots() {
        #expect(WaveformMath.envelope(index: 7) == 1)
        #expect(WaveformMath.envelope(index: 0) < 0.02)
        #expect(WaveformMath.envelope(index: 14) < 0.02)
        #expect(WaveformMath.envelope(index: 0, count: 25) < 0.02)
        // Monotonic from the edge to the middle.
        for index in 0..<7 {
            #expect(WaveformMath.envelope(index: index) < WaveformMath.envelope(index: index + 1))
        }
        // Symmetric around the middle, for any count.
        #expect(abs(WaveformMath.envelope(index: 3) - WaveformMath.envelope(index: 11)) < 0.0001)
        #expect(abs(WaveformMath.envelope(index: 5, count: 25) - WaveformMath.envelope(index: 19, count: 25)) < 0.0001)
    }

    @Test func envelopeIsClampedOutsideTheRow() {
        #expect(abs(WaveformMath.envelope(index: 40) - WaveformMath.envelope(index: 0)) < 0.0001)
        #expect(WaveformMath.envelope(index: 0, count: 1) == 1)
    }

    @Test func stillFrameShowsTheMockupBell() {
        for (count, maxHeight) in [(WaveformMath.barCount, 32.0), (WaveformMath.expandedBarCount, 44.0)] {
            let center = Int(WaveformMath.centerIndex(count: count))
            let middle = WaveformMath.stillHeight(index: center, count: count, recording: true, maxHeight: maxHeight)
            #expect(middle > maxHeight * 0.9, "the center bar nearly reaches the maximum")
            let edge = WaveformMath.stillHeight(index: 0, count: count, recording: true, maxHeight: maxHeight)
            #expect(edge < 4)
        }
    }

    @Test func frozenWaveIgnoresTime() {
        let a = WaveformMath.height(level: 0.5, index: 4, time: 0.1, animated: false)
        let b = WaveformMath.height(level: 0.5, index: 4, time: 7.3, animated: false)
        #expect(a == b)
        #expect(a > 3)
    }

    @Test func levelIsClamped() {
        let over = WaveformMath.height(level: 5, index: 7, time: WaveformMath.peakTime(index: 7))
        let under = WaveformMath.height(level: -1, index: 7, time: 0)
        #expect(abs(over - 34) < 0.001)
        #expect(under == WaveformMath.height(level: 0, index: 7, time: 0))
    }

    @Test func calmSwellStaysLowAndMoves() {
        var heights: Set<Double> = []
        for index in 0..<WaveformMath.barCount {
            for time in stride(from: 0.0, through: 3.0, by: 0.05) {
                let height = WaveformMath.calmHeight(index: index, time: time)
                #expect(height >= 3)
                #expect(height <= 9.0001)
                heights.insert((Double(height) * 100).rounded())
            }
        }
        #expect(heights.count > 10, "the swell animates")
    }

    @Test func calmSwellIsFlatWithReduceMotion() {
        for index in 0..<WaveformMath.barCount {
            #expect(WaveformMath.calmHeight(index: index, time: 1.7, animated: false) == 3)
        }
    }
}
