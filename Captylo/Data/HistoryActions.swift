import AppKit
import Foundation
import UniformTypeIdentifiers

/// Row actions of the history list: copy, reveal, retranscribe, delete, export.
/// Owns no UI state; views call it and refresh through `AppState.statsVersion`.
@MainActor
final class HistoryActions {
    private let database: Database
    private let output: any TextDelivering
    private let router: any TranscriptionRouting
    /// "Przetwórz przez AI": an enhancer with the long file deadline (not the hot path).
    private let enhancer: any TextEnhancing
    private let vocabulary: @MainActor () -> [String]
    /// Called after every change that the dashboard or the list must pick up (`AppState.bumpStats`).
    private let didChange: @MainActor () -> Void

    init(
        database: Database,
        output: any TextDelivering,
        router: any TranscriptionRouting,
        enhancer: any TextEnhancing,
        vocabulary: @escaping @MainActor () -> [String],
        didChange: @escaping @MainActor () -> Void
    ) {
        self.database = database
        self.output = output
        self.router = router
        self.enhancer = enhancer
        self.vocabulary = vocabulary
        self.didChange = didChange
    }

    // MARK: Reprocess with AI

    /// "Przetwórz przez AI": runs the row's original text (`text`) through `mode` and stores the
    /// result in the AI fields of the same row (`enhancedText`, `enhancementMode`,
    /// `enhancementModel`, `enhancementMs`, `enhancementNote`). The word count and the
    /// dashboard stats stay as they are (no new `UsageStat`). Works with AI dictation switched
    /// off; it only needs the OpenRouter key. On failure the row keeps its previous AI version
    /// and the Polish message is returned; nil on success.
    func reprocessWithAI(id: UUID, mode: AIMode) async -> String? {
        guard var record = await database.record(id: id) else {
            return DatabaseError.notFound(id).errorDescription
        }
        guard record.status == .completed,
              !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return String(localized: "Ten wpis nie ma tekstu do przetworzenia.")
        }
        // The enhancer's own 15 s deadline instead of the mode's: the user waits for this
        // on purpose, and a long history row takes longer than a fresh dictation.
        var job = mode.job(vocabulary: vocabulary())
        job.deadline = nil
        let outcome = await enhancer.enhance(record.text, job: job)
        guard case .enhanced = outcome else {
            let message = outcome.errorMessage ?? String(localized: "AI nie zwróciło tekstu.")
            Log.enhancement.notice("Reprocess of \(id.uuidString, privacy: .public) gave no text: \(message, privacy: .public)")
            return message
        }
        record.applyEnhancement(outcome, mode: mode.name)
        do {
            try await database.updateEnhancement(record)
        } catch {
            Log.data.error("Saving the reprocessed AI text failed: \(error.localizedDescription, privacy: .public)")
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        didChange()
        Log.data.info("Reprocessed \(id.uuidString, privacy: .public) with mode \(mode.kind.rawValue, privacy: .public)")
        return nil
    }

    // MARK: Copy and reveal

    func copy(_ text: String) {
        output.copy(text)
    }

    func revealInFinder(fileName: String) {
        let url = AppPaths.recordingURL(fileName: fileName)
        let directory = AppPaths.recordings.path(percentEncoded: false)
        NSWorkspace.shared.selectFile(url.path(percentEncoded: false), inFileViewerRootedAtPath: directory)
    }

    // MARK: Retranscribe

    /// Runs the saved WAV through the router again and overwrites the same row (gotcha 85).
    /// `process` is the text pipeline (`TextProcessor`) applied to the raw engine output.
    /// Returns the Polish error message on failure, nil on success.
    func retranscribe(
        id: UUID,
        engine: STTEngine,
        language: String?,
        vocabulary: [String],
        process: @escaping @Sendable (String) -> String
    ) async -> String? {
        guard var record = await database.record(id: id) else {
            return DatabaseError.notFound(id).errorDescription
        }
        guard let fileName = record.audioFileName else {
            return String(localized: "Ten wpis nie ma zapisanego nagrania.")
        }
        let url = AppPaths.recordingURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return String(localized: "Plik nagrania już nie istnieje.")
        }

        do {
            let audio = try await Task.detached(priority: .userInitiated) {
                try RecordingReader.load(url)
            }.value
            let result = try await router.transcribe(audio, engine: engine, language: language, vocabulary: vocabulary)
            let text = process(result.text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictationError.emptyResult
            }
            record.text = text
            // The old AI cleanup belonged to the old text; the row shows the fresh transcript.
            record.enhancedText = nil
            record.enhancementModel = nil
            record.enhancementMs = nil
            record.enhancementMode = nil
            record.enhancementNote = nil
            record.modelName = result.modelName
            record.transcriptionMs = result.ms
            record.language = language
            record.status = .completed
            record.errorMessage = nil
            record.wordCount = WordCounter.count(text)
            record.audioDuration = audio.duration
            try await database.update(record)
            didChange()
            Log.data.info("Retranscribed \(id.uuidString, privacy: .public) with \(result.modelName, privacy: .public)")
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.data.error("Retranscribe failed for \(id.uuidString, privacy: .public): \(message, privacy: .public)")
            // A good dictation stays good: a transient failure (timeout, empty pass) only shows
            // in the row banner. Only an already failed row gets its new error stored.
            guard record.status == .failed else { return message }
            record.errorMessage = message
            do {
                try await database.update(record)
            } catch {
                Log.data.error("Could not store the retranscribe failure: \(error.localizedDescription, privacy: .public)")
            }
            didChange()
            return message
        }
    }

    // MARK: Delete

    /// Removes the rows and their WAV files. Dashboard totals never change (gotcha 82).
    func delete(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let fileNames = try await database.delete(ids: ids)
            await Self.removeRecordings(fileNames)
            didChange()
        } catch {
            Log.data.error("History delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func removeRecordings(_ fileNames: [String]) async {
        guard !fileNames.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for fileName in fileNames {
                let url = AppPaths.recordingURL(fileName: fileName)
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    Log.data.error("Could not remove \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }.value
    }

    // MARK: Export

    /// Asks where to save and writes the CSV of the selected rows.
    func exportCSV(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Captylo-historia.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let csv = try await database.csv(ids: ids)
            try csv.write(to: url, atomically: true, encoding: .utf8)
            Log.data.info("Exported \(ids.count) rows to \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.data.error("CSV export failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
