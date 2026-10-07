import Foundation
import Observation

/// The open note's title and text while they are typed: saved after a pause and when the note is
/// left, never on every key, and never when nothing changed. The save writes only the title and
/// the text (`Database.modifyNote`), so an AI pass or a dictated paragraph that landed meanwhile
/// keeps its other fields.
@MainActor
@Observable
final class NoteDraft {
    private(set) var title: String
    private(set) var body: String
    let noteID: UUID

    @ObservationIgnored private var saved: NoteRecord
    @ObservationIgnored private let save: @MainActor (NoteRecord) async -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(note: NoteRecord, save: @escaping @MainActor (NoteRecord) async -> Void, debounce: Duration = .milliseconds(600)) {
        saved = note
        noteID = note.id
        title = note.title
        body = note.body
        self.save = save
        self.debounce = debounce
    }

    var hasUnsavedChanges: Bool {
        title != saved.title || body != saved.body
    }

    func edit(title: String) {
        self.title = title
        schedule()
    }

    func edit(body: String) {
        self.body = body
        schedule()
    }

    /// Saves now if anything changed (leaving the note, another note selected, a reload).
    func flush() async {
        pending?.cancel()
        pending = nil
        guard hasUnsavedChanges else { return }
        var record = saved
        record.title = title
        record.body = body
        saved = record
        await save(record)
    }

    private func schedule() {
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}
