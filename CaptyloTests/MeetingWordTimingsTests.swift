import Testing
@testable import Captylo

/// Inputs mirror WhisperKit word timings: words with their leading space, punctuation attached.
struct MeetingWordTimingsTests {
    private func timed(_ word: String, _ start: Double, _ end: Double) -> WordTimings.Timed {
        WordTimings.Timed(word: word, start: start, end: end)
    }

    @Test func leadingSpacesAreTrimmed() {
        let timings = [timed(" Dzień", 0.0, 0.3), timed(" dobry,", 0.4, 0.72), timed(" Anno", 0.9, 1.2)]
        #expect(WordTimings.words(from: timings, duration: 2) == [
            MeetingWord(text: "Dzień", start: 0.0, end: 0.3),
            MeetingWord(text: "dobry,", start: 0.4, end: 0.72),
            MeetingWord(text: "Anno", start: 0.9, end: 1.2),
        ])
    }

    @Test func emptyWordsAndAnnotationsAreSkipped() {
        let timings = [timed(" ", 0.0, 0.1), timed(" tak", 0.1, 0.3), timed(" *szum*", 0.3, 0.9), timed("", 0.9, 1.0)]
        #expect(WordTimings.words(from: timings, duration: 2) == [MeetingWord(text: "tak", start: 0.1, end: 0.3)])
    }

    @Test func emptyInput() {
        #expect(WordTimings.words(from: [], duration: 1).isEmpty)
    }

    /// A last word timed past the end of the slice must not outlive it.
    @Test func wordsArePinnedToTheSliceDuration() {
        let words = [
            MeetingWord(text: "Dobra", start: 0.0, end: 0.5),
            MeetingWord(text: "robimy.", start: 0.6, end: 1.4),
            MeetingWord(text: ".", start: 1.2, end: 1.3),
        ]
        #expect(WordTimings.clamped(words, toDuration: 1.0) == [
            MeetingWord(text: "Dobra", start: 0.0, end: 0.5),
            MeetingWord(text: "robimy.", start: 0.6, end: 1.0),
            MeetingWord(text: ".", start: 1.0, end: 1.0),
        ])
        #expect(WordTimings.words(from: [timed(" robimy.", 0.6, 1.4)], duration: 1.0) == [MeetingWord(text: "robimy.", start: 0.6, end: 1.0)])
    }
}
