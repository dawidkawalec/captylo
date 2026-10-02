import Foundation

/// Without headphones the mic hears the other side, so "Ja" gets a noisy copy of "Rozmówcy".
/// A mic segment of 3+ distinct words whose words mostly appear in system segments overlapping
/// it in time (give or take `window` seconds) is echo. A mic segment that only partly repeats
/// the other side loses those runs of words in `mark` (word times, `minimumEchoRun`). Short replies ("tak", "jasne", "tak, tak,
/// tak") are never marked: real overlaps are common and cheap to keep. Words are compared folded
/// (`MeetingSearch.fold`), so case, punctuation and Polish diacritics do not matter.
enum EchoFilter {
    /// Fewest distinct words a mic segment needs before it can count as echo.
    static let minimumDistinctWords = 3
    /// Seconds a system segment may lie before or after a mic segment and still count.
    static let window: Double = 1.5
    /// Share of the mic words that must appear on the system track.
    static let threshold: Double = 0.6

    static func isEcho(_ mic: MeetingSegmentRecord, against system: [MeetingSegmentRecord], window: Double = EchoFilter.window, threshold: Double = EchoFilter.threshold) -> Bool {
        guard mic.track == .me else { return false }
        let micWords = tokens(mic.text)
        guard Set(micWords).count >= minimumDistinctWords else { return false }
        let nearby = system.filter { $0.track == .them && $0.end >= mic.start - window && $0.start <= mic.end + window }
        guard !nearby.isEmpty else { return false }
        let systemWords = Set(nearby.flatMap { tokens($0.text) })
        let shared = micWords.filter { systemWords.contains($0) }.count
        return Double(shared) / Double(micWords.count) >= threshold
    }

    /// Shortest run of consecutive mic words, each heard on the system track at the same moment,
    /// that is cut out of a mic segment which is not echo as a whole. Shorter repeats ("tak, tak",
    /// the user echoing two words of the other side on purpose) stay.
    static let minimumEchoRun = 4
    /// Seconds a system word may lie from a mic word and still count as the same word heard twice.
    static let wordWindow: Double = 1.5

    /// Re-checks every mic segment against the whole system track and returns only the `.me`
    /// segments that changed, in input order: the `isEcho` flag, and in a segment that is not
    /// echo as a whole, the runs of the other side's words cut out of its text and words (a mic
    /// utterance that holds the user's own words and then the other side through the speakers).
    static func mark(_ segments: [MeetingSegmentRecord]) -> [MeetingSegmentRecord] {
        let system = segments.filter { $0.track == .them }
        return segments.compactMap { segment in
            guard segment.track == .me else { return nil }
            var changed = segment
            changed.isEcho = isEcho(segment, against: system)
            if !changed.isEcho, let words = wordsWithoutEchoRuns(segment, against: system) {
                changed.words = words
                changed.text = words.map(\.text).joined(separator: " ")
            }
            return changed == segment ? nil : changed
        }
    }

    /// The mic segment's words without its echo runs, or nil when it has none (or no word times).
    static func wordsWithoutEchoRuns(_ mic: MeetingSegmentRecord, against system: [MeetingSegmentRecord]) -> [MeetingWord]? {
        guard mic.track == .me, mic.words.count >= minimumEchoRun else { return nil }
        let heard = system
            .filter { $0.track == .them && $0.end >= mic.start - wordWindow && $0.start <= mic.end + wordWindow }
            .flatMap(\.words)
            .map { (token: tokens($0.text).joined(), start: $0.start) }
        guard !heard.isEmpty else { return nil }
        let echoed = mic.words.map { word in
            let token = tokens(word.text).joined()
            return !token.isEmpty && heard.contains { $0.token == token && abs($0.start - word.start) <= wordWindow }
        }
        var keep = [Bool](repeating: true, count: mic.words.count)
        var index = 0
        while index < echoed.count {
            guard echoed[index] else {
                index += 1
                continue
            }
            var end = index
            while end < echoed.count, echoed[end] { end += 1 }
            if end - index >= minimumEchoRun {
                for cut in index..<end { keep[cut] = false }
            }
            index = end
        }
        guard keep.contains(false) else { return nil }
        let remaining = zip(mic.words, keep).filter(\.1).map(\.0)
        return remaining.isEmpty ? nil : remaining
    }

    /// Folded words of a text, split on anything that is not a letter or digit.
    static func tokens(_ text: String) -> [String] {
        MeetingSearch.fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
