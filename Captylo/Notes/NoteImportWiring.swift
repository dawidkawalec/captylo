import Foundation

extension NoteRecord {
    /// The note an imported recording becomes (the file queue speaks `DictationRecord`). A file
    /// that could not be transcribed keeps its recording and the reason.
    static func imported(from row: DictationRecord) -> NoteRecord {
        let transcribed = row.status == .completed
        return NoteRecord(
            id: row.id,
            createdAt: row.createdAt,
            updatedAt: row.createdAt,
            body: transcribed ? row.text : "",
            audioFileName: row.audioFileName,
            audioDuration: row.audioDuration,
            language: row.language,
            transcriptModel: row.modelName,
            transcriptError: transcribed ? nil : row.errorMessage
        )
    }
}

extension FileTranscriptionQueue.Services {
    /// "Importuj nagranie" in Notatki: the same queue as "Transkrypcja pliku", but the WAV goes
    /// under `Notes/`, every file becomes a note, no AI runs and nothing lands in Historia. Kept
    /// even with "Zapisuj historię" off: a note is the user's own content, not history.
    @MainActor
    static func makeForNotes(
        settings: AppSettings,
        router: any TranscriptionRouting,
        vocabulary: @escaping @MainActor () -> [String],
        processor: @escaping @MainActor () -> TextProcessor,
        database: Database,
        didSave: @escaping @MainActor () -> Void
    ) -> FileTranscriptionQueue.Services {
        FileTranscriptionQueue.Services(
            recordingURL: { AppPaths.noteAudioURL(for: $0) },
            router: router,
            engine: { settings.sttEngine },
            language: { settings.transcriptionLanguage },
            vocabulary: vocabulary,
            processor: processor,
            enhancement: { nil },
            save: { row in try await database.createNote(NoteRecord.imported(from: row)) },
            didSave: didSave,
            saveHistory: { true }
        )
    }
}
