import Foundation
import os

/// Thread-safe 16 kHz mono Float32 sample store shared between the capture callback,
/// the live preview loop and the final transcription pass.
final class SampleBuffer: Sendable {
    static let sampleRate = 16_000

    private let storage: OSAllocatedUnfairLock<[Float]>

    /// - Parameter reservingCapacity: samples to reserve up front (default 60 s) so the
    ///   audio path does not reallocate during a typical dictation.
    init(reservingCapacity capacity: Int = SampleBuffer.sampleRate * 60) {
        var initial: [Float] = []
        initial.reserveCapacity(max(0, capacity))
        storage = OSAllocatedUnfairLock(initialState: initial)
    }

    /// Append from the audio path without copying into an intermediate array.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        storage.withLockUnchecked { $0.append(contentsOf: samples) }
    }

    func append(_ samples: [Float]) {
        storage.withLock { $0.append(contentsOf: samples) }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    var isEmpty: Bool { count == 0 }

    /// Seconds of audio stored so far.
    var duration: TimeInterval {
        Double(count) / Double(Self.sampleRate)
    }

    /// The last `n` samples (all samples when `n` exceeds `count`).
    func tail(_ n: Int) -> [Float] {
        storage.withLock { Array($0.suffix(max(0, n))) }
    }

    /// Copy of every sample stored so far.
    func snapshot() -> [Float] {
        storage.withLock { $0 }
    }

    func removeAll() {
        storage.withLock { $0.removeAll(keepingCapacity: true) }
    }
}
