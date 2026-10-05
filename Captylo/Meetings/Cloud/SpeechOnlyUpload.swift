import Foundation

/// What of a meeting track goes to the cloud: only the stretches where the live pass heard this
/// track speak, padded and joined by short silences, so the silence of a two-way call (each track
/// is quiet while the other side talks) is not paid for. The cloud words come back on the upload's
/// clock and `UploadTimeMap` puts them back on the meeting's.
enum SpeechOnlyUpload {
    /// Audio kept before and after each live line, so a word the live pass cut short still goes.
    static let padding: Double = 0.5
    /// Stretches closer than this are sent as one, pause included.
    static let mergeGap: Double = 3
    /// Silence between two stretches in the upload, so their words never run together.
    static let separator: Double = 0.6
    /// From this share of the track the whole file goes: cutting would save almost nothing.
    static let wholeTrackShare: Double = 0.85

    enum Plan: Equatable, Sendable {
        /// No usable live lines (the live pass failed or heard nothing): the whole track, as before.
        case whole
        /// Meeting-time stretches to send, sorted and apart.
        case ranges([ClosedRange<Double>])
        /// The live pass heard only echo on this track: nothing of the user's own to send.
        case nothing
    }

    /// The plan for one track from its live lines (`segments` of this track only).
    static func plan(segments: [MeetingSegmentRecord], duration: Double) -> Plan {
        let lines = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard duration > 0, !lines.isEmpty else { return .whole }
        let own = lines.filter { !$0.isEcho }
        guard !own.isEmpty else { return .nothing }

        let spans = own
            .map { max(0, $0.start - padding)...min(duration, max($0.start, $0.end) + padding) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound - last.upperBound < mergeGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        let covered = merged.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        return covered >= duration * wholeTrackShare ? .whole : .ranges(merged)
    }
}

/// Upload time -> meeting time for a track sent as stretches (`SpeechOnlyUpload`).
struct UploadTimeMap: Equatable, Sendable {
    struct Piece: Equatable, Sendable {
        /// Where the stretch starts in the upload and in the meeting, and how long it is.
        let upload: Double
        let original: Double
        let length: Double
    }

    let pieces: [Piece]

    /// The pieces of `ranges` laid one after another with `separator` seconds between them.
    init(ranges: [ClosedRange<Double>], separator: Double = SpeechOnlyUpload.separator) {
        var cursor = 0.0
        var pieces: [Piece] = []
        for range in ranges {
            let length = range.upperBound - range.lowerBound
            pieces.append(Piece(upload: cursor, original: range.lowerBound, length: length))
            cursor += length + separator
        }
        self.pieces = pieces
    }

    /// A time in the upload on the meeting's clock; inside a separator it sticks to the end of the
    /// stretch before.
    func original(_ time: Double) -> Double {
        guard let piece = pieces.last(where: { $0.upload <= time }) ?? pieces.first else { return time }
        let offset = min(max(0, time - piece.upload), piece.length)
        return piece.original + offset
    }

    /// The cloud words with their times on the meeting's clock.
    func mapped(_ words: [ElevenLabsSTT.Word]) -> [ElevenLabsSTT.Word] {
        words.map { word in
            let start = original(word.start)
            return ElevenLabsSTT.Word(text: word.text, start: start, end: max(start, original(word.end)))
        }
    }
}
