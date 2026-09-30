/// Turns VAD start/end flags per chunk into utterances of at most `maxSamples` (one Parakeet
/// encoder window, so a pass has no seams). Keeps a short pre-roll so first syllables survive,
/// and at most one open utterance in memory: a 2 h meeting never builds a big array.
///
/// All positions are absolute sample indices (16 kHz) within the track, counted from the first
/// pushed sample.
struct UtteranceSegmenter: Sendable {
    struct Config: Sendable {
        var maxSamples = 14 * 16_000
        var minSamples = 6_400           // 0.4 s
        var preRollSamples = 4_000       // 0.25 s
        var partialEverySamples = 16_000 // 1 s
        /// How far back from `maxSamples` a forced cut may move to land in a pause (2 s).
        /// 0 cuts exactly at `maxSamples`.
        var cutSearchSamples = 32_000
    }

    enum Output: Sendable, Equatable {
        /// The open utterance so far (for a gray "in progress" line).
        case partial(start: Int, samples: [Float])
        /// A closed utterance, ready for the final pass and the store.
        case final(start: Int, samples: [Float])
    }

    /// Frame (30 ms) and hop (10 ms) of the pause search behind a forced cut.
    private static let cutFrameSamples = 480
    private static let cutHopSamples = 160

    let config: Config
    private var processed = 0
    private var preRoll: [Float] = []
    private var inUtterance = false
    private var utterance: [Float] = []
    private var utteranceStart = 0
    private var lastPartialCount = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Samples held right now (pre-roll plus the open utterance); bounded by the config, not by time.
    var bufferedSampleCount: Int { utterance.count + preRoll.count }

    mutating func push(_ chunk: [Float], speechStarted: Bool, speechEnded: Bool) -> [Output] {
        let chunkStart = processed
        processed += chunk.count

        if inUtterance {
            utterance.append(contentsOf: chunk)
        } else if speechStarted {
            inUtterance = true
            utteranceStart = chunkStart - preRoll.count
            utterance = preRoll
            utterance.append(contentsOf: chunk)
            preRoll.removeAll(keepingCapacity: true)
            lastPartialCount = 0
        } else {
            keepPreRoll(chunk)
            return []
        }

        var outputs = cutAtMaximum()
        if speechEnded {
            if let final = closeUtterance() { outputs.append(final) }
        } else if !utterance.isEmpty, utterance.count - lastPartialCount >= config.partialEverySamples {
            outputs.append(.partial(start: utteranceStart, samples: utterance))
            lastPartialCount = utterance.count
        }
        return outputs
    }

    /// Closes the open utterance (end of the track). Calling it again returns nothing.
    mutating func flush() -> [Output] {
        guard inUtterance, let final = closeUtterance() else { return [] }
        return [final]
    }

    private mutating func keepPreRoll(_ chunk: [Float]) {
        let limit = config.preRollSamples
        guard limit > 0 else { return }
        preRoll.append(contentsOf: chunk.suffix(limit))
        if preRoll.count > limit {
            preRoll.removeFirst(preRoll.count - limit)
        }
    }

    /// `config.maxSamples`, never below one sample (a zero would never stop cutting).
    private var maxSamples: Int { max(1, config.maxSamples) }

    /// Emits finals while the open utterance is at least `maxSamples` long; the rest stays open.
    private mutating func cutAtMaximum() -> [Output] {
        var outputs: [Output] = []
        var offset = 0
        while utterance.count - offset >= maxSamples {
            let length = cutLength(from: offset)
            outputs.append(.final(start: utteranceStart, samples: Array(utterance[offset..<(offset + length)])))
            offset += length
            utteranceStart += length
        }
        if offset > 0 {
            utterance.removeFirst(offset)
            lastPartialCount = 0
        }
        return outputs
    }

    /// Length of the piece to cut from `utterance[offset...]`: the end of the quietest short frame
    /// in the last `cutSearchSamples` before `maxSamples`, so the cut lands in a pause between
    /// words. Ties go to the latest frame, so flat audio is cut exactly at `maxSamples`.
    private func cutLength(from offset: Int) -> Int {
        let frame = Self.cutFrameSamples
        let upper = maxSamples
        let lower = max(frame, config.minSamples, upper - config.cutSearchSamples)
        guard lower < upper else { return upper }

        var best = upper
        var bestEnergy = Float.infinity
        var end = upper
        while end >= lower {
            var energy: Float = 0
            for index in (offset + end - frame)..<(offset + end) {
                energy += utterance[index] * utterance[index]
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = end
            }
            end -= Self.cutHopSamples
        }
        return best
    }

    /// Ends the open utterance; returns it as a final when it is long enough (short blips are dropped).
    private mutating func closeUtterance() -> Output? {
        defer {
            inUtterance = false
            utterance = []
            lastPartialCount = 0
        }
        guard !utterance.isEmpty, utterance.count >= config.minSamples else { return nil }
        return .final(start: utteranceStart, samples: utterance)
    }
}
