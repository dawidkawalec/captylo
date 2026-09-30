import Foundation

/// Everything `MeetingRecorder` touches outside itself, so tests run on fakes.
struct MeetingEnvironment: Sendable {
    var makeMic: @Sendable () -> any MeetingAudioSource
    var makeSystem: @Sendable () -> any MeetingAudioSource
    var makeTranscriber: @Sendable (_ meetingID: UUID, _ language: String?, _ save: @escaping @Sendable (MeetingSegmentRecord) async -> Void) -> MeetingTranscriber
    var database: Database
    var trackURL: @Sendable (UUID, MeetingTrack) -> URL
    /// True when another app plays audio (watchdog context). Called for silent system buffers only.
    var expectingSystemAudio: @Sendable () -> Bool
    /// Read on the main actor at `start` (the transcription language setting, nil = auto).
    var language: @MainActor @Sendable () -> String?
    /// On while a meeting records: a dictation take must not mute the call.
    var setMuteSuppressed: @MainActor @Sendable (Bool) -> Void
    var postProcessors: [any MeetingPostProcessing]
}
