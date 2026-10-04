import Foundation

/// Maps diarization turns onto "Rozmówcy" segments: the turn overlapping a segment the most
/// wins; a segment in a gap takes the nearest turn within 1 s. Labels are "1", "2"... in order of
/// first appearance, so "Mówca 1" is whoever spoke first.
enum SpeakerAssigner {
    /// How far a segment's middle may sit from the nearest turn and still take its speaker.
    static let gapTolerance: Double = 1

    /// The `.them`, non-echo segments that got a speaker, in time order. Segments left out keep
    /// the track label ("Rozmówcy"). Fewer than 2 voices returns `[]`: a 1:1 call needs no labels.
    static func assign(_ segments: [MeetingSegmentRecord], turns: [SpeakerTurn]) -> [MeetingSegmentRecord] {
        guard Set(turns.map(\.speaker)).count >= 2 else { return [] }
        var labels: [String: String] = [:]
        var result: [MeetingSegmentRecord] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.track == .them && !segment.isEcho {
            guard let raw = speaker(for: segment, in: turns) else { continue }
            let label = labels[raw] ?? {
                let next = String(labels.count + 1)
                labels[raw] = next
                return next
            }()
            var labeled = segment
            labeled.speaker = label
            result.append(labeled)
        }
        return result
    }

    private static func speaker(for segment: MeetingSegmentRecord, in turns: [SpeakerTurn]) -> String? {
        var best: (speaker: String, overlap: Double)?
        for turn in turns where turn.end > segment.start && turn.start < segment.end {
            let overlap = min(turn.end, segment.end) - max(turn.start, segment.start)
            if overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
        }
        if let best { return best.speaker }
        let middle = (segment.start + segment.end) / 2
        let nearest = turns.min { distance(middle, $0) < distance(middle, $1) }
        guard let nearest, distance(middle, nearest) <= gapTolerance else { return nil }
        return nearest.speaker
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}
