import FluidAudio
import Testing
@testable import Captylo

struct MeetingSegmenterTests {
    private func chunk(_ value: Float, _ count: Int = 4_096) -> [Float] { Array(repeating: value, count: count) }

    private func finals(_ outputs: [UtteranceSegmenter.Output]) -> [(start: Int, samples: [Float])] {
        outputs.compactMap { output in
            if case .final(let start, let samples) = output { return (start, samples) }
            return nil
        }
    }

    // MARK: - ChunkAccumulator

    @Test func accumulatorCutsExactChunks() {
        var acc = ChunkAccumulator(size: 4)
        #expect(acc.push([1, 2, 3]).isEmpty)
        #expect(acc.push([4, 5, 6, 7, 8, 9]) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(acc.pendingCount == 1)
        #expect(acc.drain() == [9])
        #expect(acc.pendingCount == 0)
    }

    @Test func accumulatorSplitsOneLargePushInOrder() {
        var acc = ChunkAccumulator(size: 4)
        let samples = (0..<43).map(Float.init)
        let chunks = acc.push(samples)
        #expect(chunks.count == 10)
        #expect(chunks.allSatisfy { $0.count == 4 })
        #expect(chunks.flatMap { $0 } == Array(samples.prefix(40)))
        #expect(acc.drain() == [40, 41, 42])
    }

    @Test func accumulatorDefaultsToTheVadChunkSize() {
        #expect(ChunkAccumulator().size == VadManager.chunkSize)
    }

    // MARK: - UtteranceSegmenter

    @Test func speechBetweenStartAndEndBecomesOneFinalWithPreRoll() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 100_000, minSamples: 1_000, preRollSamples: 2_000, partialEverySamples: 1_000_000))
        #expect(seg.push(chunk(0), speechStarted: false, speechEnded: false).isEmpty)       // 0..<4096 silence
        #expect(seg.push(chunk(1), speechStarted: true, speechEnded: false).isEmpty)        // 4096..<8192 speech
        #expect(seg.push(chunk(1), speechStarted: false, speechEnded: false).isEmpty)
        let out = seg.push(chunk(0), speechStarted: false, speechEnded: true)
        guard case .final(let start, let samples) = out.first else { Issue.record("no final"); return }
        #expect(start == 4_096 - 2_000)
        #expect(samples.count == 2_000 + 3 * 4_096)
        #expect(seg.bufferedSampleCount <= 2_000)
    }

    @Test func blipsShorterThanTheMinimumAreDropped() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 100_000, minSamples: 10_000, preRollSamples: 0, partialEverySamples: 1_000_000))
        #expect(seg.push(chunk(1), speechStarted: true, speechEnded: true).isEmpty)
        #expect(seg.bufferedSampleCount == 0)
    }

    @Test func longSpeechIsCutAtTheMaximumAndContinues() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 8_192, minSamples: 1, preRollSamples: 0, partialEverySamples: 1_000_000))
        var starts: [Int] = []
        for i in 0..<6 {
            for final in finals(seg.push(chunk(1), speechStarted: i == 0, speechEnded: false)) {
                starts.append(final.start)
                #expect(final.samples.count <= 8_192)
            }
        }
        #expect(starts == [0, 8_192, 16_384])
        #expect(seg.bufferedSampleCount <= 8_192)
    }

    /// A cut forced by the maximum lands in the pause just before it, not in the middle of a word.
    @Test func longSpeechIsCutInThePauseNearTheMaximum() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 16_384, minSamples: 1, preRollSamples: 0, partialEverySamples: 1_000_000, cutSearchSamples: 8_192))
        var track = chunk(1, 20_480)
        for i in 12_000..<12_800 { track[i] = 0 }
        var outputs: [UtteranceSegmenter.Output] = []
        for (i, start) in stride(from: 0, to: track.count, by: 4_096).enumerated() {
            outputs += seg.push(Array(track[start..<(start + 4_096)]), speechStarted: i == 0, speechEnded: false)
        }
        outputs += seg.flush()
        let pieces = finals(outputs)
        #expect(pieces.count == 2)
        guard pieces.count == 2 else { return }
        let cut = pieces[0].samples.count
        #expect(cut > 12_000 && cut <= 12_800)
        #expect(pieces[1].start == cut)
        #expect(pieces[0].samples + pieces[1].samples == track)
    }

    @Test func finalsAreExactSlicesOfTheTrackWhateverTheSourceBufferSize() {
        // Sample value = its index, so every slice can be checked against the track.
        let track = (0..<40_960).map(Float.init)
        var acc = ChunkAccumulator(size: 4_096)
        var seg = UtteranceSegmenter(config: .init(maxSamples: 10_000, minSamples: 1, preRollSamples: 1_000, partialEverySamples: 1_000_000, cutSearchSamples: 0))
        var outputs: [UtteranceSegmenter.Output] = []
        var chunkIndex = 0
        for start in stride(from: 0, to: track.count, by: 1_600) {
            for vadChunk in acc.push(Array(track[start..<min(start + 1_600, track.count)])) {
                outputs += seg.push(vadChunk, speechStarted: chunkIndex == 2 || chunkIndex == 7, speechEnded: chunkIndex == 5)
                chunkIndex += 1
            }
        }
        outputs += seg.flush()
        let pieces = finals(outputs)
        #expect(pieces.map(\.start) == [7_192, 17_192, 27_672, 37_672])
        for piece in pieces {
            #expect(piece.samples == Array(track[piece.start..<(piece.start + piece.samples.count)]))
            #expect(piece.samples.count <= 10_000)
        }
    }

    @Test func partialsComeAtTheConfiguredCadence() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 100_000, minSamples: 1, preRollSamples: 0, partialEverySamples: 8_192))
        var partials = 0
        for i in 0..<5 {
            for output in seg.push(chunk(1), speechStarted: i == 0, speechEnded: false) {
                if case .partial = output { partials += 1 }
            }
        }
        #expect(partials == 2) // at 8192 and 16384 samples of speech
    }

    @Test func flushEmitsTheOpenUtterance() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 100_000, minSamples: 1, preRollSamples: 0, partialEverySamples: 1_000_000))
        _ = seg.push(chunk(1), speechStarted: true, speechEnded: false)
        #expect(seg.flush() == [.final(start: 0, samples: chunk(1))])
        #expect(seg.flush().isEmpty)
    }

    @Test func emptyPiecesAreNeverEmitted() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 4_096, minSamples: 0, preRollSamples: 0, partialEverySamples: 1_000_000))
        #expect(seg.push(chunk(1), speechStarted: true, speechEnded: false) == [.final(start: 0, samples: chunk(1))])
        #expect(seg.flush().isEmpty)
        _ = seg.push(chunk(1), speechStarted: true, speechEnded: false)
        #expect(seg.push(chunk(0, 0), speechStarted: false, speechEnded: true).isEmpty)
    }

    @Test func speechEndWithoutAStartIsIgnored() {
        var seg = UtteranceSegmenter(config: .init(maxSamples: 100_000, minSamples: 1, preRollSamples: 0, partialEverySamples: 1_000_000))
        #expect(seg.push(chunk(0), speechStarted: false, speechEnded: true).isEmpty)
        #expect(seg.flush().isEmpty)
    }

    // MARK: - Memory over long meetings

    @Test func longSilenceKeepsOnlyThePreRoll() {
        var seg = UtteranceSegmenter()
        for _ in 0..<2_000 { _ = seg.push(chunk(0), speechStarted: false, speechEnded: false) }
        #expect(seg.bufferedSampleCount == seg.config.preRollSamples)
    }

    @Test func longMonologueKeepsAtMostOneWindow() {
        var seg = UtteranceSegmenter()
        var start = 0
        for i in 0..<250 { // about 64 s of speech with no pause
            for final in finals(seg.push(chunk(0.5), speechStarted: i == 0, speechEnded: false)) {
                #expect(final.start == start)
                #expect(final.samples.count <= seg.config.maxSamples)
                start += final.samples.count
            }
            #expect(seg.bufferedSampleCount < seg.config.maxSamples)
        }
        #expect(start > 3 * seg.config.maxSamples - 1)
    }

    // MARK: - Detector tuning

    @Test func detectorEndsSpeechAfterShortPauses() {
        #expect(FluidSpeechDetector.segmentation.minSilenceDuration == 0.6)
    }
}
