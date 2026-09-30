import Foundation

/// The text of one utterance and its words with times (seconds, relative to wherever the caller says).
struct TimedTranscript: Sendable, Equatable {
    var text: String
    var words: [MeetingWord]
}
