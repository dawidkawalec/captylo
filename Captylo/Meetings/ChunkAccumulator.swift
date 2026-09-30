import FluidAudio

/// Silero VAD takes exactly `VadManager.chunkSize` (4096) samples per call; sources deliver any size.
/// Keeps the remainder between pushes, so chunks stay contiguous and in order.
struct ChunkAccumulator: Sendable {
    let size: Int
    private var pending: [Float] = []

    init(size: Int = VadManager.chunkSize) {
        precondition(size > 0, "chunk size must be positive")
        self.size = size
        pending.reserveCapacity(size * 2)
    }

    var pendingCount: Int { pending.count }

    /// Every whole chunk now available. A large push is split in one pass (no repeated front removal).
    mutating func push(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        let whole = pending.count / size
        guard whole > 0 else { return [] }
        var chunks: [[Float]] = []
        chunks.reserveCapacity(whole)
        for index in 0..<whole {
            chunks.append(Array(pending[(index * size)..<((index + 1) * size)]))
        }
        pending.removeFirst(whole * size)
        return chunks
    }

    /// The leftover shorter than one chunk (end of a track).
    mutating func drain() -> [Float] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
