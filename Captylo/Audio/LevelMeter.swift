import Foundation
import os

/// Lock-guarded level shared between the capture thread and the waveform (gotcha 35).
/// The capture side stores RMS dB per converted buffer; the UI pulls a smoothed 0...1 value
/// inside `TimelineView` with a time-based EMA, so the smoothing is frame-rate independent.
final class LevelMeter: LevelSource, Sendable {
    /// Quietest level that still shows on the meter.
    static let floorDB: Float = -60
    /// EMA time constant.
    static let tau: TimeInterval = 0.080
    /// No sample for this long means the capture stopped: the meter decays to 0.
    static let staleAfter: TimeInterval = 0.150

    private struct State: Sendable {
        var db: Float = LevelMeter.floorDB
        /// Uptime of the last `store`; nil until the first sample.
        var at: TimeInterval?
        var smoothed: Float = 0
        var lastRead: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Called from the capture thread with the RMS of one converted buffer in dB (<= 0).
    func store(rmsDB: Float) {
        store(rmsDB: rmsDB, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Same as `store(rmsDB:)` with an explicit timestamp (tests).
    func store(rmsDB: Float, at time: TimeInterval) {
        state.withLock { state in
            state.db = rmsDB
            state.at = time
        }
    }

    /// Normalized 0...1 level for `now` (`ProcessInfo.processInfo.systemUptime`).
    func read(now: TimeInterval) -> Float {
        state.withLock { state in
            let target: Float
            if let at = state.at, now - at <= Self.staleAfter {
                target = Self.normalize(db: state.db)
            } else {
                target = 0
            }

            let alpha: Float
            if let lastRead = state.lastRead, now > lastRead {
                let dt = now - lastRead
                alpha = Float(1 - exp(-dt / Self.tau))
            } else if state.lastRead == nil {
                alpha = 1
            } else {
                alpha = 0
            }
            state.lastRead = now
            state.smoothed += alpha * (target - state.smoothed)
            return state.smoothed
        }
    }

    /// Forgets every sample and the smoothing history (call at start and stop).
    func reset() {
        state.withLock { $0 = State() }
    }

    /// Maps `floorDB...0` dB to 0...1, clamped.
    static func normalize(db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let clamped = min(max(db, floorDB), 0)
        return (clamped - floorDB) / -floorDB
    }
}
