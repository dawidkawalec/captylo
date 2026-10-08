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
    /// AI titles are allowed (`AppSettings.aiEnabled`: the user lets dictations go to the AI).
    private let titleAI: @MainActor () -> Bool
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
        titleAI: @escaping @MainActor () -> Bool = { false },
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
        self.titleAI = titleAI
        self.decode = decode
        self.removeFile = removeFile
        self.didChange = didChange
    }

    /// Runs the body through `mode` and saves the result; the text from before the first AI pass
    /// stays in `originalBody`. The result replaces the body only if the body is still the text
    /// the AI was given: a note edited during the wait keeps the edit. Nil on success, else the
    /// Polish message (the body is untouched).
    func applyAI(noteID: UUID, mode: AIMode) async -> String? {
        guard let note = try? await database.note(id: noteID) else {
            return DatabaseError.notFound(noteID).errorDescription
        }
        let source = note.body
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let saved = try await database.modifyNote(id: noteID) { record in
                guard record.body == source else { return }
                if record.originalBody == nil {
                    record.originalBody = record.body
                }
                record.body = enhanced
                record.aiMode = name
            }
            guard let saved else { return DatabaseError.notFound(noteID).errorDescription }
            guard saved.body == enhanced else {
                return String(localized: "Notatka zmieniła się w trakcie, więc AI jej nie nadpisało. Spróbuj jeszcze raz.")
            }
        } catch {
            Log.data.error("Saving the AI text of a note failed: \(error.localizedDescription, privacy: .public)")
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        didChange()
        return nil
    }

    /// The user left a note (another note selected, Notatki closed). An untouched empty note
    /// ("Nowa notatka" with nothing typed) goes, unless `keepEmpty` (a dictation into it is still
    /// on its way, or the last save failed). A note edited during the visit gets its AI title;
    /// one only looked at costs nothing.
    func leave(noteID: UUID, edited: Bool, keepEmpty: Bool) async {
        if !keepEmpty, (try? await database.deleteNoteIfEmpty(id: noteID)) == true {
            didChange()
            return
        }
        if edited {
            await ensureTitle(noteID: noteID)
        }
    }

    /// Notes whose AI title is being written (two triggers at once make one call).
    private var titling: Set<UUID> = []

    /// Names a note that has text but no stored title with the AI title, when AI is allowed and
    /// the note has at least `NoteTitles.aiMinWords` words. Otherwise nothing is stored: the list
    /// shows the short first sentence (`NoteRecord.displayTitle`), which follows the text. A
    /// title typed meanwhile is never overwritten.
    func ensureTitle(noteID: UUID) async {
        guard titleAI(), !titling.contains(noteID) else { return }
        titling.insert(noteID)
        defer { titling.remove(noteID) }
        guard let note = try? await database.note(id: noteID),
              note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WordCounter.count(body) >= NoteTitles.aiMinWords else { return }
        let outcome = await enhancer.enhance(String(body.prefix(NoteTitles.aiInputLimit)), job: NoteTitles.job)
        guard let text = outcome.text, let title = NoteTitles.clean(text) else {
            Log.enhancement.notice("Note title from AI skipped: \(outcome.errorMessage ?? "no text", privacy: .public)")
            return
        }
        let named = title
        do {
            try await database.modifyNote(id: noteID) { record in
                if record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = named
                }
            }
        } catch {
            Log.data.error("Saving a note title failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        didChange()
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

    /// Transcribes the note's recording again (a voice note whose first try failed). The text
    /// becomes the body, or a paragraph under what the user typed meanwhile. Nil on success, else
    /// the Polish message, which also lands in `transcriptError`.
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
                record.body = NoteTake.appending(text, to: record.body)
                record.transcriptModel = model
                record.transcriptError = nil
            }
            didChange()
            // The title comes on its own: "Spróbuj ponownie" never waits for the AI title.
            Task { await self.ensureTitle(noteID: noteID) }
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            _ = try? await database.modifyNote(id: noteID) { $0.transcriptError = message }
            didChange()
            return message
        }
    }
}
