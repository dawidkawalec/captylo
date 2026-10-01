import Foundation
import os

/// "Sprawdź" next to "Dostęp do dźwięku systemu" (Ustawienia > Spotkania): listens to the system
/// audio tap for a moment and tells whether Captylo hears other apps. There is no API for the
/// grant and a denied tap delivers exact zeros, so the answer needs something playing: zeros
/// while another app plays mean no access, zeros while nothing plays mean nothing to judge.
/// The first start of a tap also shows the system prompt; a "no access" right after it is
/// cleared by allowing and checking again.
struct SystemAudioCheck: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Real audio arrived from another app.
        case works
        /// Exact zeros (or no buffers at all) while another app was playing.
        case noAccess
        /// Silence and nothing playing long enough to judge.
        case nothingPlaying
        /// The tap did not start; the text is for the user.
        case failed(String)
    }

    static let listenDuration: Duration = .seconds(2)

    /// One second of zeros while another app plays is the verdict: the check only listens for
    /// two, and the tap needs a moment to deliver its first buffer.
    private var watchdog = SilenceWatchdog(noAccessAfter: 1)
    private var silentWhilePlaying = false
    private var receivedSamples = false

    mutating func observe(_ samples: [Float], expectingAudio: Bool) {
        guard !samples.isEmpty else { return }
        receivedSamples = true
        if watchdog.observe(samples, expectingAudio: expectingAudio) == .noAccess {
            silentWhilePlaying = true
        }
    }

    func outcome(expectingAudioNow: Bool) -> Outcome {
        if watchdog.heardAudio { return .works }
        if silentWhilePlaying { return .noAccess }
        // An app plays and the tap delivered nothing at all: it hears nothing either.
        if !receivedSamples && expectingAudioNow { return .noAccess }
        return .nothingPlaying
    }

    /// Starts `source`, listens for `listen`, stops it and judges. Start and stop run on a
    /// queue of their own (Core Audio calls block); a cancelled task stops early.
    static func run(
        source: any MeetingAudioSource,
        listen: Duration = listenDuration,
        expectingAudio: @escaping @Sendable () -> Bool
    ) async -> Outcome {
        let state = OSAllocatedUnfairLock(initialState: SystemAudioCheck())
        do {
            try await onQueue {
                try source.start { samples in
                    let expecting = expectingAudio()
                    state.withLock { $0.observe(samples, expectingAudio: expecting) }
                }
            }
        } catch {
            Log.audio.error("System audio check: the tap did not start: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        try? await Task.sleep(for: listen)
        try? await onQueue { source.stop() }
        let expectingNow = expectingAudio()
        let outcome = state.withLock { $0.outcome(expectingAudioNow: expectingNow) }
        Log.audio.info("System audio check: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private static let queue = DispatchQueue(label: "com.captylo.app.meeting.audio-check", qos: .userInitiated)

    private static func onQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
