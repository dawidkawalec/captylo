import os

/// The only singleton: `os.Logger` per module plus the hot-path signposter.
/// `print` is reserved for the debug CLI output.
enum Log {
    static let subsystem = "com.captylo.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let enhancement = Logger(subsystem: subsystem, category: "enhancement")
    static let output = Logger(subsystem: subsystem, category: "output")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let learning = Logger(subsystem: subsystem, category: "learning")
    /// Calendar access and refresh counts only: never event titles or attendee names.
    static let calendar = Logger(subsystem: subsystem, category: "calendar")

    /// Wrap hot-path steps (capture stop, transcribe, enhance, paste) in signpost intervals.
    static let signposter = OSSignposter(subsystem: subsystem, category: "hotpath")
}
