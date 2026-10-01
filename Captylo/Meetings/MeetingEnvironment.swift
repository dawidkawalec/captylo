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
    /// True when the default output is the Mac's own speakers (the headphones hint). Polled off
    /// the main actor while a meeting records.
    var outputUsesBuiltInSpeakers: @Sendable () -> Bool = { false }
}
