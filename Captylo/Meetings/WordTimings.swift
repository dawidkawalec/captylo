import FluidAudio
import Foundation

/// Groups Parakeet's SentencePiece tokens into words. A token that starts with the word marker
/// begins a new word, anything else continues it. `AsrManager` hands the marker out already turned
/// into a leading space ("▁do" arrives as " do"), so both forms count; FluidAudio's
/// `buildWordTimings` does exactly that and also skips `<blank>` / `<pad>` and bare marker tokens.
enum WordTimings {
    static func words(from tokens: [TokenTiming], offset: Double) -> [MeetingWord] {
        buildWordTimings(from: tokens).map {
            MeetingWord(text: $0.word, start: offset + $0.startTime, end: offset + $0.endTime)
        }
    }

    /// Every pass appends zero padding after the slice, and tokens decoded there (often the final
    /// punctuation) get times past its end. Pins them to `duration` so a word never outlives its audio.
    static func clamped(_ words: [MeetingWord], toDuration duration: Double) -> [MeetingWord] {
        words.map { word in
            var word = word
            word.start = min(word.start, duration)
            word.end = min(max(word.end, word.start), duration)
            return word
        }
    }
}
