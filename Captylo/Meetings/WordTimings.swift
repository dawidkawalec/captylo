import Foundation

/// Turns the word times of a Whisper pass into meeting words. Whisper hands words out with their
/// leading space (" dzień"), may time a last word past the end of the slice, and sometimes emits
/// a sound annotation ("*szum*") as a word; all three are cleaned here.
enum WordTimings {
    struct Timed: Sendable, Equatable {
        var word: String
        var start: Double
        var end: Double
    }

    /// Trimmed, non-empty words without annotations, pinned to `duration` (seconds, relative to
    /// the start of the slice).
    static func words(from timings: [Timed], duration: Double) -> [MeetingWord] {
        let words = timings.compactMap { timing -> MeetingWord? in
            let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !WhisperOutputFilter.isAnnotation(text) else { return nil }
            return MeetingWord(text: text, start: timing.start, end: timing.end)
        }
        return clamped(words, toDuration: duration)
    }

    /// A word never outlives its audio: times past `duration` are pinned to it.
    static func clamped(_ words: [MeetingWord], toDuration duration: Double) -> [MeetingWord] {
        words.map { word in
            var word = word
            word.start = min(word.start, duration)
            word.end = min(max(word.end, word.start), duration)
            return word
        }
    }
}
