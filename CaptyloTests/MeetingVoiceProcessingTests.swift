import Foundation
import Testing
@testable import Captylo

/// "Redukcja echa (eksperymentalna)": the switch reaches the mic capture, and the engine work is
/// a closure, so the fallback runs here with a fake that throws (no audio in tests).
struct MeetingVoiceProcessingTests {
    private struct Refused: Error {}

    @Test func offNeverTouchesTheEngine() {
        var calls = 0
        let outcome = VoiceProcessingSetup.apply(wanted: false) { calls += 1 }
        #expect(outcome == .off)
        #expect(!outcome.isActive)
        #expect(calls == 0)
        #expect(outcome.logLabel == "off")
    }

    @Test func onWhenTheInputAcceptsIt() {
        var calls = 0
        let outcome = VoiceProcessingSetup.apply(wanted: true) { calls += 1 }
        #expect(outcome == .on)
        #expect(outcome.isActive)
        #expect(calls == 1)
        #expect(outcome.logLabel == "on")
    }

    @Test func aRefusalMeansThePlainEngine() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -10875)
        let outcome = VoiceProcessingSetup.apply(wanted: true) { throw error }
        #expect(outcome == .unavailable(error.localizedDescription))
        #expect(!outcome.isActive)
        #expect(outcome.logLabel == "unavailable (\(error.localizedDescription))")
    }

    @Test func anyThrownErrorIsUnavailable() {
        let outcome = VoiceProcessingSetup.apply(wanted: true) { throw Refused() }
        guard case .unavailable = outcome else {
            Issue.record("expected unavailable, got \(outcome)")
            return
        }
    }

    /// One line at start, one more only when a rebuild changes the outcome: a device change
    /// mid-meeting must not repeat "unavailable" every two seconds.
    @Test func theLogLineIsWrittenOncePerOutcome() {
        #expect(VoiceProcessingSetup.logMessage(.off, after: nil) == "Meeting mic voice processing: off")
        #expect(VoiceProcessingSetup.logMessage(.on, after: nil) == "Meeting mic voice processing: on")
        #expect(VoiceProcessingSetup.logMessage(.unavailable("x"), after: nil) == "Meeting mic voice processing: unavailable (x)")
        #expect(VoiceProcessingSetup.logMessage(.on, after: .on) == nil)
        #expect(VoiceProcessingSetup.logMessage(.unavailable("x"), after: .unavailable("x")) == nil)
        #expect(VoiceProcessingSetup.logMessage(.unavailable("y"), after: .on) == "Meeting mic voice processing: unavailable (y)")
    }

    /// Construction only stores the wish; the engine is built at `start`, so nothing is active
    /// yet and the test host opens no microphone.
    @Test func theCaptureKeepsTheWishUntilStart() {
        let plain = MeetingMicCapture()
        #expect(!plain.voiceProcessingWanted)
        #expect(!plain.isVoiceProcessingActive)
        let wanted = MeetingMicCapture(voiceProcessing: true)
        #expect(wanted.voiceProcessingWanted)
        #expect(!wanted.isVoiceProcessingActive)
    }
}
