import Foundation

/// One stretch of one voice on the "Rozmówcy" track, as the diarizer found it. `speaker` is the
/// diarizer's own id ("S3"); times are seconds from the meeting start (the track file's time).
struct SpeakerTurn: Sendable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
}
