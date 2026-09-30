import Foundation

/// Without headphones the mic hears the other side, so "Ja" gets a noisy copy of "Rozmówcy".
/// A mic segment of 3+ distinct words whose words mostly appear in system segments overlapping
/// it in time (give or take `window` seconds) is echo. Short replies ("tak", "jasne", "tak, tak,
/// tak") are never marked: real overlaps are common and cheap to keep. Words are compared folded
/// (`MeetingSearch.fold`), so case, punctuation and Polish diacritics do not matter.
enum EchoFilter {
    /// Fewest distinct words a mic segment needs before it can count as echo.
    static let minimumDistinctWords = 3

    static func isEcho(_ mic: MeetingSegmentRecord, against system: [MeetingSegmentRecord], window: Double = 1.5, threshold: Double = 0.6) -> Bool {
        guard mic.track == .me else { return false }
        let micWords = tokens(mic.text)
        guard Set(micWords).count >= minimumDistinctWords else { return false }
        let nearby = system.filter { $0.track == .them && $0.end >= mic.start - window && $0.start <= mic.end + window }
        guard !nearby.isEmpty else { return false }
        let systemWords = Set(nearby.flatMap { tokens($0.text) })
        let shared = micWords.filter { systemWords.contains($0) }.count
        return Double(shared) / Double(micWords.count) >= threshold
    }

    /// Re-checks every mic segment against the whole system track and returns only the `.me`
    /// segments whose `isEcho` changed, carrying the new value, in input order.
    static func mark(_ segments: [MeetingSegmentRecord]) -> [MeetingSegmentRecord] {
        let system = segments.filter { $0.track == .them }
        return segments.compactMap { segment in
            guard segment.track == .me else { return nil }
            let echo = isEcho(segment, against: system)
            guard echo != segment.isEcho else { return nil }
            var changed = segment
            changed.isEcho = echo
            return changed
        }
    }

    /// Folded words of a text, split on anything that is not a letter or digit.
    static func tokens(_ text: String) -> [String] {
        MeetingSearch.fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
