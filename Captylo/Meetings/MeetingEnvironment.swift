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
    /// True when the speech model is on disk. Read by `start`: without it every pass fails and
    /// the meeting would record audio with no transcript, so it does not start at all.
    var speechModelReady: @Sendable () -> Bool = { true }
    /// The calendar event a recording starting now belongs to (`MeetingCalendar.currentEvent()`),
    /// nil while the calendar is off. Read on the main actor at `start` when no title and no
    /// event were given: the row takes the event's title, id and participants.
    var currentEvent: @MainActor @Sendable () -> CalendarEvent? = { nil }
}
