import Foundation
import Testing
@testable import Captylo

struct MeetingSystemAudioCheckTests {
    private let tenth = Array(repeating: Float(0), count: 1_600)
    private let voice = Array(repeating: Float(0.2), count: 1_600)

    @Test func realAudioMeansItWorks() {
        var check = SystemAudioCheck()
        for _ in 0..<5 { check.observe(tenth, expectingAudio: true) }
        check.observe(voice, expectingAudio: true)
        #expect(check.outcome(expectingAudioNow: true) == .works)
    }

    @Test func zerosWhileAnotherAppPlaysMeanNoAccess() {
        var check = SystemAudioCheck()
        for _ in 0..<15 { check.observe(tenth, expectingAudio: true) }
        #expect(check.outcome(expectingAudioNow: true) == .noAccess)
    }

    @Test func zerosWhileNothingPlaysAskToPlaySomething() {
        var check = SystemAudioCheck()
        for _ in 0..<20 { check.observe(tenth, expectingAudio: false) }
        #expect(check.outcome(expectingAudioNow: false) == .nothingPlaying)
    }

    /// A blip of playback is too short to tell a denied grant from a quiet moment.
    @Test func aShortBlipOfPlaybackIsNotEnough() {
        var check = SystemAudioCheck()
        for _ in 0..<4 { check.observe(tenth, expectingAudio: true) }
        for _ in 0..<14 { check.observe(tenth, expectingAudio: false) }
        #expect(check.outcome(expectingAudioNow: false) == .nothingPlaying)
    }

    @Test func noBuffersWhileAnotherAppPlaysMeanNoAccess() {
        let check = SystemAudioCheck()
        #expect(check.outcome(expectingAudioNow: true) == .noAccess)
        #expect(check.outcome(expectingAudioNow: false) == .nothingPlaying)
    }

    @Test func runListensThenStopsTheSource() async {
        let source = FakeAudioSource()
        let voice = self.voice
        let pusher = Task {
            for _ in 0..<200 {
                if source.isRunning {
                    source.push(voice)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let outcome = await SystemAudioCheck.run(source: source, listen: .milliseconds(400), expectingAudio: { true })
        await pusher.value
        #expect(outcome == .works)
        #expect(source.startCount == 1)
        #expect(source.stopCount == 1)
        #expect(!source.isRunning)
    }

    @Test func aSourceThatDoesNotStartReportsTheError() async {
        let source = FakeAudioSource()
        source.failOnStart = true
        let outcome = await SystemAudioCheck.run(source: source, listen: .milliseconds(50), expectingAudio: { true })
        #expect(outcome == .failed(MeetingAudioError.format.localizedDescription))
        #expect(source.stopCount == 0)
    }
}
