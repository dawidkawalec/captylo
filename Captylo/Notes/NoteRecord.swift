import Foundation

/// Value mirror of `Note` (models never leave the `Database` actor).
struct NoteRecord: Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Typed by the user; empty = the list shows the first line (`displayTitle`).
    var title: String = ""
    var body: String = ""
    /// The text before the first AI pass ("Przywróć oryginał"); nil when no AI touched it.
    var originalBody: String? = nil
    /// `<id>.wav` under `AppPaths.notes`; nil for a typed note.
    var audioFileName: String? = nil
    var audioDuration: Double = 0
    var language: String? = nil
    /// The speech model that wrote the body from the audio.
    var transcriptModel: String? = nil
    /// Why the audio could not be transcribed (Polish); nil when it worked.
    var transcriptError: String? = nil
    /// The AI mode of the last "Uporządkuj przez AI" (its name).
    var aiMode: String? = nil

    var hasAudio: Bool { audioFileName != nil }

    /// The typed title, else the first non-empty line of the body, else "Notatka bez tytułu".
    var displayTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let firstLine = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine ?? String(localized: "Notatka bez tytułu")
    }
}
