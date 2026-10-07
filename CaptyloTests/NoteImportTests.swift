import Foundation
import Testing
@testable import Captylo

private final class NoteImportFakeRouter: TranscriptionRouting, Sendable {
    func transcribe(_ audio: CapturedAudio, engine: STTEngine, language: String?, vocabulary: [String]) async throws -> TranscriptionResult {
        TranscriptionResult(text: "głosówka od ani", modelName: "fake-model", ms: 3)
    }
}

@MainActor
struct NoteImportTests {
    @Test func aTranscribedFileBecomesAVoiceNote() {
        let row = DictationRecord(
            id: UUID(), text: "Głosówka od Ani.", status: .completed, source: .file,
            audioDuration: 12, audioFileName: "x.wav", language: "pl", modelName: "m", wordCount: 3
        )
        let note = NoteRecord.imported(from: row)
        #expect(note.id == row.id && note.body == "Głosówka od Ani." && note.audioFileName == "x.wav")
        #expect(note.audioDuration == 12 && note.transcriptModel == "m" && note.transcriptError == nil)
        #expect(note.title.isEmpty)
    }

    @Test func aFailedFileBecomesANoteWithItsAudioAndTheError() {
        let row = DictationRecord(
            id: UUID(), text: "", status: .failed, errorMessage: "Brak internetu", source: .file,
            audioDuration: 5, audioFileName: "y.wav", wordCount: 0
        )
        let note = NoteRecord.imported(from: row)
        #expect(note.body.isEmpty && note.transcriptError == "Brak internetu" && note.hasAudio)
    }

    /// The real queue with the note services: the WAV lands under the notes folder, the store
    /// gets a note and no history row.
    @Test func theNoteQueueSavesANoteAndNoDictation() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "captylo-note-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Database(modelContainer: try Store.makeInMemoryContainer())
        let defaults = UserDefaults(suiteName: "NoteImportTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        var services = FileTranscriptionQueue.Services.makeForNotes(
            settings: settings,
            router: NoteImportFakeRouter(),
            vocabulary: { [] },
            processor: { TextProcessor(dictionary: .default, paragraphs: true) },
            database: db,
            didSave: {}
        )
        services.decode = { _ in ([Float](repeating: 0.1, count: 16_000), 1.0) }
        services.writeWAV = { _, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(to: url)
        }
        services.recordingURL = { folder.appending(path: "\($0.uuidString).wav") }
        let queue = FileTranscriptionQueue(services: services)
        queue.add(urls: [URL(filePath: "/tmp/glosowka.opus")])
        for _ in 0..<200 where !queue.hasFinishedItems {
            try await Task.sleep(for: .milliseconds(10))
        }
        let notes = try await db.notes(query: "", limit: 5)
        #expect(notes.count == 1)
        #expect(notes.first?.body.isEmpty == false)
        #expect(notes.first?.audioFileName?.hasSuffix(".wav") == true)
        #expect(await db.count() == 0)
    }
}
