import FluidAudio
import Testing
@testable import Captylo

struct MeetingWordTimingsTests {
    private func token(_ t: String, _ s: Double, _ e: Double) -> TokenTiming {
        TokenTiming(token: t, tokenId: 0, startTime: s, endTime: e, confidence: 1)
    }

    private let dzienDobryAnno = [
        MeetingWord(text: "Dzień", start: 10.0, end: 10.3),
        MeetingWord(text: "dobry,", start: 10.4, end: 10.72),
        MeetingWord(text: "Anno", start: 10.9, end: 11.2),
    ]

    @Test func sentencePieceMarkersStartWords() {
        let tokens = [token("▁Dzień", 0.0, 0.3), token("▁do", 0.4, 0.5), token("bry", 0.5, 0.7), token(",", 0.7, 0.72), token("▁Anno", 0.9, 1.2)]
        #expect(WordTimings.words(from: tokens, offset: 10) == dzienDobryAnno)
    }

    /// `AsrManager` hands out tokens with the marker already turned into a leading space.
    @Test func leadingSpaceStartsWordsLikeTheRealDecoderOutput() {
        let tokens = [token(" Dzień", 0.0, 0.3), token(" do", 0.4, 0.5), token("bry", 0.5, 0.7), token(",", 0.7, 0.72), token(" Anno", 0.9, 1.2)]
        #expect(WordTimings.words(from: tokens, offset: 10) == dzienDobryAnno)
    }

    @Test func emptyAndPunctuationOnlyInput() {
        #expect(WordTimings.words(from: [], offset: 0).isEmpty)
        #expect(WordTimings.words(from: [token(".", 0, 0.1)], offset: 0) == [MeetingWord(text: ".", start: 0, end: 0.1)])
    }

    /// A bare marker token ("▁" before a digit) opens a new word; the next piece must not glue onto the previous word.
    @Test func bareMarkerTokenStartsTheNextWord() {
        let tokens = [token(" Mam", 0.0, 0.2), token(" ", 0.3, 0.32), token("5", 0.32, 0.4), token(" lat", 0.5, 0.7)]
        #expect(WordTimings.words(from: tokens, offset: 0) == [
            MeetingWord(text: "Mam", start: 0.0, end: 0.2),
            MeetingWord(text: "5", start: 0.32, end: 0.4),
            MeetingWord(text: "lat", start: 0.5, end: 0.7),
        ])
    }

    /// The pass appends 1 s of zeros; tokens decoded there (often the final ".") must not outlive the slice.
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
    }

    @Test func blankAndPadTokensAreSkipped() {
        let tokens = [token("<blank>", 0.0, 0.1), token(" tak", 0.1, 0.3), token("<pad>", 0.3, 0.4), token("", 0.4, 0.5)]
        #expect(WordTimings.words(from: tokens, offset: 2) == [MeetingWord(text: "tak", start: 2.1, end: 2.3)])
    }
}
