import Foundation

/// What the transcript view draws: the segments in time order without the mic's echo, consecutive
/// segments of one speaker merged into one line, and a "przerwa w nagraniu" marker at each
/// capture gap. Pure, so the merge rules are tested without a view.
enum MeetingTranscriptLines {
    /// The same speaker goes on in one line when the next segment starts at most this long
    /// (seconds) after the previous one ended.
    static let mergeGap: Double = 2

    struct Line: Equatable, Identifiable, Sendable {
        /// The first merged segment's id, stable while later segments join the line.
        let id: UUID
        let track: MeetingTrack
        let speaker: String?
        let start: Double
        var end: Double
        var text: String
        /// Every merged segment in time order (playback, speaker rename).
        var segmentIDs: [UUID]
    }

    enum Item: Equatable, Identifiable, Sendable {
        case line(Line)
        /// A capture gap at this meeting time.
        case gap(Double)

        var id: String {
            switch self {
            case .line(let line): return line.id.uuidString
            case .gap(let at): return "gap-\(at)"
            }
        }
    }

    /// Lines and gaps in time order. A gap sits before the first segment that starts at or after
    /// it (gaps after the last segment close the list) and always ends the line before it.
    static func items(_ segments: [MeetingSegmentRecord], interruptions: [Double]) -> [Item] {
        let visible = segments.filter { !$0.isEcho }.sorted(by: order)
        var gaps = Array(Set(interruptions.filter(\.isFinite))).sorted()[...]
        var items: [Item] = []
        var open: Line?

        func closeLine() {
            if let line = open {
                items.append(.line(line))
                open = nil
            }
        }

        for segment in visible {
            while let gap = gaps.first, gap <= segment.start {
                closeLine()
                items.append(.gap(gap))
                gaps.removeFirst()
            }
            if var line = open, line.track == segment.track, line.speaker == segment.speaker,
               segment.start - line.end <= mergeGap {
                line.text += " " + segment.text
                line.end = max(line.end, segment.end)
                line.segmentIDs.append(segment.id)
                open = line
            } else {
                closeLine()
                open = Line(id: segment.id, track: segment.track, speaker: segment.speaker,
                            start: segment.start, end: segment.end, text: segment.text,
                            segmentIDs: [segment.id])
            }
        }
        closeLine()
        items.append(contentsOf: gaps.map(Item.gap))
        return items
    }

    /// Number of speaker tints besides "Ja".
    static let tintCount = 4

    /// Which tint the speaker chip of a line wears: nil for "Ja" (the Tide accent), else one of
    /// `tintCount` Glacier tints, stable per speaker label ("Mówca 2" keeps its tint after a rename).
    static func tintSlot(track: MeetingTrack, speaker: String?) -> Int? {
        guard track == .them else { return nil }
        guard let speaker else { return 0 }
        if let number = Int(speaker), number > 0 {
            return (number - 1) % tintCount
        }
        let sum = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % tintCount
    }

    /// Time order; at the same start the mic ("Ja") first, like `Database.segments(meetingID:)`.
    private static func order(_ a: MeetingSegmentRecord, _ b: MeetingSegmentRecord) -> Bool {
        if a.start != b.start { return a.start < b.start }
        return a.track == .me && b.track == .them
    }
}
