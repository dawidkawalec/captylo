import Foundation

/// Turns the timed words of one cloud-transcribed track into transcript segments that read like
/// the live ones: a new segment after a pause of `pauseBreak`, at the end of a sentence once a
/// segment is `softLimit` long, and in any case at `hardLimit`.
enum CloudTranscriptSegments {
    /// Seconds of silence between two words that start a new segment.
    static let pauseBreak: Double = 1.0
    /// From this length a segment ends after the next word that closes a sentence.
    static let softLimit: Double = 14
    /// No segment runs longer than this.
    static let hardLimit: Double = 25

    static func build(_ words: [ElevenLabsSTT.Word], meetingID: UUID, track: MeetingTrack) -> [MeetingSegmentRecord] {
        var segments: [MeetingSegmentRecord] = []
        var current: [ElevenLabsSTT.Word] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(MeetingSegmentRecord(
                meetingID: meetingID,
                track: track,
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " "),
                words: current.map { MeetingWord(text: $0.text, start: $0.start, end: $0.end) }
            ))
            current = []
        }

        for word in words.sorted(by: { $0.start < $1.start }) {
            if let first = current.first, let last = current.last {
                let length = word.end - first.start
                let paused = word.start - last.end >= pauseBreak
                let sentenceDone = last.end - first.start >= softLimit && endsSentence(last.text)
                if paused || sentenceDone || length > hardLimit {
                    close()
                }
            }
            current.append(word)
        }
        close()
        return segments
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }
}
