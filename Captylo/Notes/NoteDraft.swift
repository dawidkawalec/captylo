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
    /// Writes the title and text; false when the save failed (the edit stays unsaved).
    @ObservationIgnored private let save: @MainActor (NoteRecord) async -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(note: NoteRecord, save: @escaping @MainActor (NoteRecord) async -> Bool, debounce: Duration = .milliseconds(600)) {
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

    /// The draft shows exactly this stored note (same note, same title and text): a reload can
    /// keep it, together with anything typed while the reload ran.
    func isShowing(_ note: NoteRecord) -> Bool {
        noteID == note.id && title == note.title && body == note.body
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
        let previous = saved
        var record = saved
        record.title = title
        record.body = body
        saved = record
        if !(await save(record)), saved == record {
            // Not written: the next pause or the next flush tries again.
            saved = previous
        }
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
