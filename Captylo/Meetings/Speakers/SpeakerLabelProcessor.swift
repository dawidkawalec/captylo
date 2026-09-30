import Foundation
import os

/// After a meeting: "Mówca 1/2/3" on the "Rozmówcy" track, Pro and macOS 15+ only. Runs the
/// diarizer over the closed `them` track file and writes the labels onto the stored segments;
/// with one remote voice (a 1:1 call) or on any failure the segments keep "Rozmówcy".
struct SpeakerLabelProcessor: MeetingPostProcessing {
    let database: Database
    let diarizer: any SpeakerDiarizing
    let isAllowed: @Sendable () async -> Bool
    let trackURL: @Sendable (UUID, MeetingTrack) -> URL
    /// `systemSupportsDiarization` in the app; tests pin it.
    var systemSupported: Bool = SpeakerLabelProcessor.systemSupportsDiarization

    /// The offline diarizer crashes on macOS 14 (FluidAudio #878), fixed by Apple in 15.
    static var systemSupportsDiarization: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    func process(meetingID: UUID) async {
        guard systemSupported, await isAllowed() else { return }
        let url = trackURL(meetingID, .them)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let segments = try await database.segments(meetingID: meetingID)
            // Nothing heard from the other side: no labels to give, so the models never load.
            guard segments.contains(where: { $0.track == .them && !$0.isEcho }) else { return }
            let started = ContinuousClock.now
            let turns = try await diarizer.diarize(url: url)
            let labeled = SpeakerAssigner.assign(segments, turns: turns)
            try await database.updateSegments(labeled)
            let speakers = Set(labeled.compactMap(\.speaker)).count
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            Log.transcription.info("Meeting speakers: \(speakers, privacy: .public) labeled in \(ms, privacy: .public) ms")
        } catch {
            Log.transcription.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
