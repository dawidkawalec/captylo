import Foundation
import Testing
@testable import Captylo

struct AudioLevelMeterTests {
    @Test func normalizeClampsMinus60ToZeroRange() {
        #expect(LevelMeter.normalize(db: 0) == 1)
        #expect(LevelMeter.normalize(db: -60) == 0)
        #expect(LevelMeter.normalize(db: -120) == 0)
        #expect(LevelMeter.normalize(db: 12) == 1)
        #expect(abs(LevelMeter.normalize(db: -30) - 0.5) < 0.0001)
        #expect(LevelMeter.normalize(db: -.infinity) == 0)
        #expect(LevelMeter.normalize(db: .nan) == 0)
    }

    @Test func firstReadJumpsToTheStoredLevel() {
        let meter = LevelMeter()
        meter.store(rmsDB: -30, at: 10.0)
        let value = meter.read(now: 10.01)
        #expect(abs(value - 0.5) < 0.0001)
    }

    @Test func emaIsTimeBasedNotFrameBased() {
        // Two meters, same wall time span (80 ms = one tau), different frame counts.
        let coarse = LevelMeter()
        let fine = LevelMeter()
        for meter in [coarse, fine] {
            meter.store(rmsDB: -60, at: 0)
            _ = meter.read(now: 0)
            meter.store(rmsDB: 0, at: 0.001)
        }
        let coarseValue = coarse.read(now: 0.08)
        var fineValue: Float = 0
        for step in 1...8 {
            fineValue = fine.read(now: Double(step) * 0.01)
        }
        // After one tau both approach 1 - 1/e; the per-frame path converges the same way.
        let expected = Float(1 - exp(-1.0))
        #expect(abs(coarseValue - expected) < 0.01)
        #expect(abs(fineValue - expected) < 0.01)
    }

    @Test func decaysToZeroWhenSamplesStop() {
        let meter = LevelMeter()
        meter.store(rmsDB: 0, at: 1.0)
        #expect(meter.read(now: 1.0) == 1)
        // Still fresh at 100 ms.
        #expect(meter.read(now: 1.1) > 0.99)
        // Stale after 150 ms: the target drops to 0 and the EMA follows.
        var value: Float = 1
        for step in 1...50 {
            value = meter.read(now: 1.2 + Double(step) * 0.02)
        }
        #expect(value < 0.001)
    }

    @Test func resetForgetsEverything() {
        let meter = LevelMeter()
        meter.store(rmsDB: 0, at: 5)
        #expect(meter.read(now: 5) == 1)
        meter.reset()
        #expect(meter.read(now: 5.001) == 0)
    }

    @Test func readNeverGoesBackwardsInTime() {
        let meter = LevelMeter()
        meter.store(rmsDB: 0, at: 2)
        let first = meter.read(now: 2.05)
        let earlier = meter.read(now: 2.0)
        #expect(earlier == first)
    }
}
