import Foundation

/// What the Notatki screen does to a note besides typing: AI modes, restore the text from before
/// the AI, delete (with the recording), retry the transcription of a voice note. Owns no UI state;
/// views call it and refresh through `didChange`.
@MainActor
final class NoteActions {
    private let database: Database
    private let router: any TranscriptionRouting
    /// The long-deadline enhancer of "Przetwórz przez AI" (`utilityEnhancer`, dictation route:
    /// the own key in Free, Captylo AI in Pro).
    private let enhancer: any TextEnhancing
    private let vocabulary: @MainActor () -> [String]
    private let processor: @MainActor () -> TextProcessor
    private let engine: @MainActor () -> STTEngine
    private let language: @MainActor () -> String?
    private let decode: @Sendable (URL) async throws -> (samples: [Float], duration: TimeInterval)
    private let removeFile: @Sendable (String) -> Void
    private let didChange: @MainActor () -> Void

    init(
        database: Database,
        router: any TranscriptionRouting,
        enhancer: any TextEnhancing,
        vocabulary: @escaping @MainActor () -> [String],
        processor: @escaping @MainActor () -> TextProcessor,
        engine: @escaping @MainActor () -> STTEngine,
        language: @escaping @MainActor () -> String?,
        decode: @escaping @Sendable (URL) async throws -> (samples: [Float], duration: TimeInterval) = {
            try await AudioDecoder.decode16kMono($0)
        },
        removeFile: @escaping @Sendable (String) -> Void = {
            try? FileManager.default.removeItem(at: AppPaths.noteAudioURL(fileName: $0))
        },
        didChange: @escaping @MainActor () -> Void
    ) {
        self.database = database
        self.router = router
        self.enhancer = enhancer
        self.vocabulary = vocabulary
        self.processor = processor
        self.engine = engine
        self.language = language
        self.decode = decode
        self.removeFile = removeFile
        self.didChange = didChange
    }

    /// Runs the body through `mode` and saves the result; the text from before the first AI pass
    /// stays in `originalBody`. Nil on success, else the Polish message (the body is untouched).
    func applyAI(noteID: UUID, mode: AIMode) async -> String? {
        guard let note = try? await database.note(id: noteID) else {
            return DatabaseError.notFound(noteID).errorDescription
        }
        let text = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return String(localized: "Ta notatka nie ma tekstu do przetworzenia.")
        }
        // The enhancer's own long deadline instead of the mode's: the user waits on purpose.
        var job = mode.job(vocabulary: vocabulary())
        job.deadline = nil
        let outcome = await enhancer.enhance(text, job: job)
        guard let enhanced = outcome.text else {
            return outcome.errorMessage ?? String(localized: "AI nie zwróciło tekstu.")
        }
        let name = mode.name
        do {
            try await database.modifyNote(id: noteID) { record in
                if record.originalBody == nil {
                    record.originalBody = record.body
                }
                record.body = enhanced
                record.aiMode = name
            }
        } catch {
            Log.data.error("Saving the AI text of a note failed: \(error.localizedDescription, privacy: .public)")
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        didChange()
        return nil
    }

    /// "Przywróć oryginał": the text from before the first AI pass.
    func restoreOriginal(noteID: UUID) async {
        do {
            try await database.modifyNote(id: noteID) { record in
                guard let original = record.originalBody else { return }
                record.body = original
                record.originalBody = nil
                record.aiMode = nil
            }
        } catch {
            Log.data.error("Restoring a note failed: \(error.localizedDescription, privacy: .public)")
        }
        didChange()
    }

    /// Deletes the note and its recording.
    func delete(noteID: UUID) async {
        let fileName: String?
        do {
            fileName = try await database.deleteNote(id: noteID)
        } catch {
            Log.data.error("Deleting a note failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let fileName, !fileName.isEmpty {
            removeFile(fileName)
        }
        didChange()
    }

    /// Transcribes the note's recording again (a voice note whose first try failed) and replaces
    /// the body. Nil on success, else the Polish message, which also lands in `transcriptError`.
    func retryTranscription(noteID: UUID) async -> String? {
        guard let note = try? await database.note(id: noteID), let fileName = note.audioFileName else {
            return DatabaseError.notFound(noteID).errorDescription
        }
        let url = AppPaths.noteAudioURL(fileName: fileName)
        do {
            let decoded = try await decode(url)
            let audio = CapturedAudio(id: noteID, fileURL: url, samples: decoded.samples, duration: decoded.duration)
            let result = try await router.transcribe(audio, engine: engine(), language: language(), vocabulary: vocabulary())
            let text = processor().process(result.text, language: language())
            guard !text.isEmpty else { throw DictationError.emptyResult }
            let model = result.modelName
            try await database.modifyNote(id: noteID) { record in
                record.body = text
                record.transcriptModel = model
                record.transcriptError = nil
            }
            didChange()
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            _ = try? await database.modifyNote(id: noteID) { $0.transcriptError = message }
            didChange()
            return message
        }
    }
}
