import Foundation
import os

/// After a meeting (Pro, "Dokładniejszy transkrypt z chmury"): each track goes to the cloud
/// engine with word times, and its transcript replaces the live local segments of that track.
/// Only the stretches where the live pass heard that track speak are sent (`SpeechOnlyUpload`),
/// so the silence of a call is not paid for; a track with only echo is not sent at all.
/// Runs first among the post-processors, so the speaker labels, the AI fixes and the AI notes all
/// work on the cloud text. A track that fails, or comes back empty where the live pass heard
/// speech, keeps its live segments; the meeting row says which engine made the transcript and
/// why the cloud pass failed.
struct MeetingCloudTranscription: MeetingPostProcessing {
    typealias Transcribe = @Sendable (_ request: STTRequest, _ mimeType: String) async throws -> [ElevenLabsSTT.Word]

    let database: Database
    /// Pro and the setting are on (after a meeting); the manual action skips it.
    let isEnabled: @Sendable () async -> Bool
    let trackURL: @Sendable (UUID, MeetingTrack) -> URL
    let language: @Sendable () async -> String?
    let vocabulary: @Sendable () async -> [String]
    let transcribe: Transcribe
    /// Where the encoded uploads are written (and removed right after).
    var workFolder: URL = FileManager.default.temporaryDirectory.appending(path: "CaptyloMeetingUpload", directoryHint: .isDirectory)

    static let modelName = STTEngine.elevenLabs.modelName
    /// A track shorter than this is not sent.
    static let minimumSeconds: Double = 1

    func process(meetingID: UUID) async {
        guard await isEnabled() else { return }
        await run(meetingID: meetingID)
    }

    /// Also "Transkrybuj ponownie w chmurze". Returns true when at least one track was replaced.
    @discardableResult
    func run(meetingID: UUID) async -> Bool {
        let existing: [MeetingSegmentRecord]
        do {
            guard let meeting = try await database.meeting(id: meetingID), meeting.hasAudio else { return false }
            existing = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Cloud meeting transcript could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let language = await language()
        let vocabulary = await vocabulary()
        let started = ContinuousClock.now
        var replaced = 0
        var failure: String?

        for track in MeetingTrack.allCases {
            let url = trackURL(meetingID, track)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            do {
                let live = existing.filter { $0.track == track }
                let segments = try await transcribeTrack(url, track: track, live: live, meetingID: meetingID, language: language, vocabulary: vocabulary)
                guard let segments else { continue }
                if segments.isEmpty, existing.contains(where: { $0.track == track && !$0.isEcho }) {
                    Log.transcription.notice("Cloud meeting transcript of \(track.rawValue, privacy: .public) came back empty, keeping the live one")
                    continue
                }
                try await database.replaceSegments(meetingID: meetingID, track: track, with: segments)
                replaced += 1
            } catch {
                Log.transcription.error("Cloud meeting transcript failed (\(track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
                failure = error.localizedDescription
            }
        }

        if replaced > 0 {
            do {
                let all = try await database.segments(meetingID: meetingID)
                try await database.updateSegments(EchoFilter.mark(all))
            } catch {
                Log.data.error("Cloud meeting transcript echo marks could not be saved: \(error.localizedDescription, privacy: .public)")
            }
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            Log.transcription.info("Cloud meeting transcript: \(replaced, privacy: .public) track(s) in \(ms, privacy: .public) ms")
        }
        let didReplace = replaced > 0
        let message = failure.map { String(localized: "Transkrypt z chmury: \($0)") }
        do {
            try await database.modifyMeeting(id: meetingID) { record in
                if didReplace {
                    record.transcriptModel = Self.modelName
                    // The fixed lines were replaced with the rest of the track.
                    record.transcriptAIModel = nil
                }
                record.transcriptError = message
            }
        } catch {
            Log.data.error("Cloud meeting transcript state could not be saved: \(error.localizedDescription, privacy: .public)")
        }
        return didReplace
    }

    /// The segments of one track, or nil when there is nothing to send (too short, or only echo).
    private func transcribeTrack(_ url: URL, track: MeetingTrack, live: [MeetingSegmentRecord], meetingID: UUID, language: String?, vocabulary: [String]) async throws -> [MeetingSegmentRecord]? {
        let folder = workFolder
        let encoded: TrackUploadEncoder.Encoded? = try await Task.detached(priority: .utility) {
            switch SpeechOnlyUpload.plan(segments: live, duration: try TrackUploadEncoder.duration(of: url)) {
            case .nothing:
                return nil
            case .whole:
                return try TrackUploadEncoder.encode(url, into: folder)
            case .ranges(let ranges):
                return try TrackUploadEncoder.encode(url, into: folder, ranges: ranges)
            }
        }.value
        guard let encoded else { return nil }
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        guard encoded.seconds >= Self.minimumSeconds else { return nil }
        let data = try Data(contentsOf: encoded.url)
        let request = STTRequest(
            wav: data,
            fileName: "\(track.rawValue).\(encoded.url.pathExtension)",
            model: Self.modelName,
            language: language,
            vocabulary: vocabulary,
            audioSeconds: encoded.seconds
        )
        let uploaded = try await transcribe(request, encoded.mimeType)
        let words = encoded.timeMap?.mapped(uploaded) ?? uploaded
        return CloudTranscriptSegments.build(words, meetingID: meetingID, track: track)
    }
}
