import Foundation
import Testing
@testable import Captylo

/// The "Wykrywanie mowy do spotkań" line under the model status: the voice detector loads
/// (which downloads it once) with the speech model and at launch.
@MainActor
struct MeetingDetectorStatusTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadsOnceAndReadsReady() async throws {
        let loader = CountingDetectorLoader()
        let cache = SpeechDetectorCache { try await loader.load() }
        let status = SpeechDetectorStatus { try await cache.prewarm() }
        #expect(status.state == .missing)
        await status.prewarm()
        #expect(status.state == .ready)
        await status.prewarm()
        #expect(await loader.loads == 1)
        // The prewarmed detector is the one the meetings get.
        _ = try await cache.detector()
        #expect(await loader.loads == 1)
    }

    @Test func loadingIsVisibleWhileItRuns() async {
        let gate = TestGate()
        let status = SpeechDetectorStatus { await gate.wait() }
        let run = Task { await status.prewarm() }
        await waitUntil { status.state == .loading }
        #expect(status.state == .loading)
        // A second call while loading neither restarts nor waits.
        await status.prewarm()
        #expect(status.state == .loading)
        await gate.open()
        await run.value
        #expect(status.state == .ready)
    }

    @Test func aFailedLoadIsShownAndTriedAgain() async {
        let loader = CountingDetectorLoader(failures: 1)
        let cache = SpeechDetectorCache { try await loader.load() }
        let status = SpeechDetectorStatus { try await cache.prewarm() }
        await status.prewarm()
        #expect(status.state == .failed(ScriptedFailure().localizedDescription))
        await status.prewarm()
        #expect(status.state == .ready)
        #expect(await loader.loads == 2)
    }

    /// The design preview pins the state: nothing loads or downloads.
    @Test func aPinnedStateNeverLoads() async {
        let loader = CountingDetectorLoader()
        let status = SpeechDetectorStatus(load: { _ = try await loader.load() }, pinned: .ready)
        await status.prewarm()
        #expect(status.state == .ready)
        #expect(await loader.loads == 0)
    }

    @Test func statusLineTexts() {
        #expect(SpeechDetectorStatusLine.line(for: .missing) == nil)
        let loading = SpeechDetectorStatusLine.line(for: .loading)
        #expect(loading?.text == String(localized: "Wykrywanie mowy do spotkań: pobieram..."))
        #expect(loading?.tone == .neutral)
        let ready = SpeechDetectorStatusLine.line(for: .ready)
        #expect(ready?.text == String(localized: "Wykrywanie mowy do spotkań: gotowe"))
        #expect(ready?.tone == .success)
        let failed = SpeechDetectorStatusLine.line(for: .failed("brak sieci"))
        #expect(failed?.text == String(localized: "Wykrywanie mowy do spotkań: nie pobrano (brak sieci)"))
        #expect(failed?.tone == .error)
    }
}
