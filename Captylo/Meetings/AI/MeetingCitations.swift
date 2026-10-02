import Foundation

/// The `[mm:ss]` / `[h:mm:ss]` citations the AI notes put after each point (the transcript's
/// stamps, `MeetingTime.stamp`): which meeting seconds a line cites, the line without them, and
/// which track to play for one.
enum MeetingCitations {
    /// `[12:34]` or `[1:02:03]`. Seconds above 59, or minutes above 59 next to hours, are checked
    /// after the match and leave the text as it is.
    private static let regex = try! NSRegularExpression(pattern: #"\[(?:(\d+):)?(\d{1,2}):(\d{2})\]"#)

    /// `text` without its citations (a space before each goes with it, so "piątek [1:58]," reads
    /// "piątek,") and the cited seconds in order.
    static func split(_ text: String) -> MeetingNotesDocument.Line {
        let ns = text as NSString
        var citations: [Double] = []
        var remove: [NSRange] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let seconds = seconds(of: match, in: ns) else { continue }
            citations.append(seconds)
            var range = match.range
            while range.location > 0, isSpace(ns.character(at: range.location - 1)) {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            remove.append(range)
        }
        guard !remove.isEmpty else { return MeetingNotesDocument.Line(text: text, citations: []) }
        let kept = NSMutableString(string: text)
        for range in remove.reversed() {
            kept.deleteCharacters(in: range)
        }
        let cleaned = (kept as String).trimmingCharacters(in: .whitespaces)
        return MeetingNotesDocument.Line(text: cleaned, citations: citations)
    }

    /// The track of the line spoken at `seconds` (echo skipped): the one whose time span (start
    /// rounded down, as its stamp shows it) is nearest, and among lines that span it the one
    /// that starts closest to it. Nil without a line.
    static func track(at seconds: Double, in segments: [MeetingSegmentRecord]) -> MeetingTrack? {
        segment(at: seconds, in: segments)?.track
    }

    /// The line spoken at `seconds` (echo skipped), chosen like `track(at:in:)`: what a
    /// "Zapytaj wszystkie spotkania" citation jumps to in the transcript. Nil without a line.
    static func segment(at seconds: Double, in segments: [MeetingSegmentRecord]) -> MeetingSegmentRecord? {
        segments.filter { !$0.isEcho }.min { lhs, rhs in
            let left = distance(seconds, lhs)
            let right = distance(seconds, rhs)
            if left != right { return left < right }
            return abs(lhs.start.rounded(.down) - seconds) < abs(rhs.start.rounded(.down) - seconds)
        }
    }

    private static func distance(_ seconds: Double, _ segment: MeetingSegmentRecord) -> Double {
        let start = segment.start.rounded(.down)
        if seconds < start { return start - seconds }
        if seconds > segment.end { return seconds - segment.end }
        return 0
    }

    /// Longest meeting a citation can point into (also keeps the arithmetic far from overflow).
    private static let maxHours = 99

    private static func seconds(of match: NSTextCheckingResult, in text: NSString) -> Double? {
        func number(_ group: Int) -> Int? {
            Int(text.substring(with: match.range(at: group)))
        }
        guard let minutes = number(2), let secs = number(3), secs < 60 else { return nil }
        guard match.range(at: 1).location != NSNotFound else {
            return Double(minutes * 60 + secs)
        }
        guard let hours = number(1), hours <= maxHours, minutes < 60 else { return nil }
        return Double(hours * 3600 + minutes * 60 + secs)
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0
    }
}
