import Foundation
import Testing
@testable import Captylo

struct NoteTakeTests {
    @Test func shortcutStartsANoteOnlyWhenIdleAndStopsAnyRunningTake() {
        #expect(TakeDestination.forShortcutPress(phase: .idle) == .start(.newNote))
        // A take that records (a note or a dictation) is stopped as what it is, never turned
        // into a note.
        #expect(TakeDestination.forShortcutPress(phase: .recording) == .stop)
        #expect(TakeDestination.forShortcutPress(phase: .paused) == .stop)
        #expect(TakeDestination.forShortcutPress(phase: .transcribing) == .busy)
        #expect(TakeDestination.forShortcutPress(phase: .enhancing) == .busy)
    }

    @Test func appendingAddsOneBlankLineBetweenParagraphs() {
        #expect(NoteTake.appending("Druga myśl.", to: "") == "Druga myśl.")
        #expect(NoteTake.appending("Druga myśl.", to: "Pierwsza myśl.") == "Pierwsza myśl.\n\nDruga myśl.")
        #expect(NoteTake.appending("Druga myśl.", to: "Pierwsza myśl.\n\n") == "Pierwsza myśl.\n\nDruga myśl.")
    }

    @Test func newAndFailedNotesCarryTheirAudio() {
        let id = UUID()
        let file = "\(id.uuidString).wav"
        let ok = NoteTake.newNote(id: id, text: "Treść", duration: 4, language: "pl", model: "m", audioFileName: file)
        #expect(ok.id == id && ok.body == "Treść" && ok.audioDuration == 4)
        #expect(ok.transcriptModel == "m" && ok.title.isEmpty && ok.audioFileName == file)
        let failed = NoteTake.failedNote(id: id, duration: 4, language: "pl", audioFileName: file, error: "Brak internetu")
        #expect(failed.body.isEmpty && failed.transcriptError == "Brak internetu" && failed.hasAudio)
    }

    @Test func adoptAudioMovesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "captylo-take-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let from = folder.appending(path: "Recordings/a.wav")
        let to = folder.appending(path: "Notes/a.wav")
        try FileManager.default.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: from)
        try NoteTake.adoptAudio(from: from, to: to)
        #expect(!FileManager.default.fileExists(atPath: from.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: to.path(percentEncoded: false)))
    }
}
