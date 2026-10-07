import Foundation

/// The note side of a take (`TakeDestination.newNote` / `.appendToNote`), kept pure for tests.
enum NoteTake {
    /// A voice note from a transcribed take; the title stays empty (the list shows the first line).
    static func newNote(id: UUID, text: String, duration: Double, language: String?, model: String?, audioFileName: String) -> NoteRecord {
        NoteRecord(
            id: id,
            body: text,
            audioFileName: audioFileName,
            audioDuration: duration,
            language: language,
            transcriptModel: model
        )
    }

    /// A voice note whose transcription failed: the recording is kept, the reason sits next to it.
    static func failedNote(id: UUID, duration: Double, language: String?, audioFileName: String, error: String) -> NoteRecord {
        NoteRecord(
            id: id,
            body: "",
            audioFileName: audioFileName,
            audioDuration: duration,
            language: language,
            transcriptError: error
        )
    }

    /// `text` as a new paragraph at the end of `body`.
    static func appending(_ text: String, to body: String) -> String {
        let head = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? text : head + "\n\n" + text
    }

    /// Moves the take's WAV from `Recordings/` to `Notes/`, where the dictation orphan sweep never runs.
    static func adoptAudio(from source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: source, to: target)
    }
}
