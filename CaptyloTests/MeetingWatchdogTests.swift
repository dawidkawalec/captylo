import Testing
@testable import Captylo

struct MeetingWatchdogTests {
    private let second = Array(repeating: Float(0), count: 16_000)
    private let voice = Array(repeating: Float(0.2), count: 16_000)

    @Test func zerosFromTheStartWhileSomethingPlaysMeansNoAccess() {
        var dog = SilenceWatchdog(noAccessAfter: 4, stallAfter: 6)
        for _ in 0..<3 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: true) == .noAccess)
    }

    @Test func zerosWhileNothingPlaysAreFine() {
        var dog = SilenceWatchdog()
        for _ in 0..<20 { #expect(dog.observe(second, expectingAudio: false) == .ok) }
    }

    @Test func zerosAfterRealAudioMeanAStallAndFireAgainLater() {
        var dog = SilenceWatchdog(noAccessAfter: 4, stallAfter: 6)
        #expect(dog.observe(voice, expectingAudio: true) == .ok)
        for _ in 0..<5 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: true) == .stalled)
        for _ in 0..<5 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: true) == .stalled)
    }

    @Test func quietButNonZeroAudioIsNotSilence() {
        var dog = SilenceWatchdog(noAccessAfter: 1, stallAfter: 1)
        let hiss = Array(repeating: Float(0.00001), count: 16_000)
        for _ in 0..<5 { #expect(dog.observe(hiss, expectingAudio: true) == .ok) }
    }

    /// The verdict is an event, not a state: the recorder hops to the main actor for every
    /// non-ok verdict, so a denied grant must not fire ten times a second for the whole meeting.
    @Test func noAccessIsReportedOncePerSilentRun() {
        var dog = SilenceWatchdog(noAccessAfter: 4, stallAfter: 6)
        let tenth = Array(repeating: Float(0), count: 1_600)
        var verdicts: [SilenceWatchdog.Verdict] = []
        for _ in 0..<100 { verdicts.append(dog.observe(tenth, expectingAudio: true)) }
        #expect(verdicts.filter { $0 == .noAccess }.count == 1)
        #expect(verdicts.firstIndex(of: .noAccess) == 39)

        // Nothing playing breaks the run; a new silent run while an app plays reports again.
        #expect(dog.observe(tenth, expectingAudio: false) == .ok)
        for _ in 0..<39 { #expect(dog.observe(tenth, expectingAudio: true) == .ok) }
        #expect(dog.observe(tenth, expectingAudio: true) == .noAccess)
        #expect(!dog.heardAudio)
    }

    @Test func aPauseInPlaybackRestartsTheCount() {
        var dog = SilenceWatchdog(noAccessAfter: 4, stallAfter: 6)
        for _ in 0..<3 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: false) == .ok)
        for _ in 0..<3 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: true) == .noAccess)
    }

    @Test func realAudioEndsANoAccessRunForGood() {
        var dog = SilenceWatchdog(noAccessAfter: 4, stallAfter: 6)
        for _ in 0..<5 { _ = dog.observe(second, expectingAudio: true) }
        #expect(!dog.heardAudio)
        #expect(dog.observe(voice, expectingAudio: true) == .ok)
        #expect(dog.heardAudio)
        // From now on long zeros are a stall, never "no access".
        for _ in 0..<5 { #expect(dog.observe(second, expectingAudio: true) == .ok) }
        #expect(dog.observe(second, expectingAudio: true) == .stalled)
    }

    @Test func emptyBuffersChangeNothing() {
        var dog = SilenceWatchdog(noAccessAfter: 1, stallAfter: 1)
        for _ in 0..<10 { #expect(dog.observe([], expectingAudio: true) == .ok) }
        #expect(!dog.heardAudio)
        #expect(dog.observe(second, expectingAudio: true) == .noAccess)
    }
}
