import Foundation
import Observation

/// The open note's title and text while they are typed: saved after a pause and when the note is
/// left, never on every key, and never when nothing changed. A save carries only the fields
/// edited here (`Change`), so a title written elsewhere meanwhile (the AI title), an AI pass or a
/// dictated paragraph is never overwritten by the draft's older copy.
@MainActor
@Observable
final class NoteDraft {
    /// What one save writes: the fields edited since the last save (nil = leave as stored), and
    /// the draft's whole view of the note.
    struct Change: Sendable, Equatable {
        var record: NoteRecord
        var title: String?
        var body: String?
    }

    private(set) var title: String
    private(set) var body: String
    let noteID: UUID
    /// The user edited the title or the text during this visit (leaving names such a note).
    @ObservationIgnored private(set) var wasEdited = false

    @ObservationIgnored private var saved: NoteRecord
    /// Writes the change; false when the save failed (the edit stays unsaved).
    @ObservationIgnored private let save: @MainActor (Change) async -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(note: NoteRecord, save: @escaping @MainActor (Change) async -> Bool, debounce: Duration = .milliseconds(600)) {
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
        wasEdited = true
        schedule()
    }

    func edit(body: String) {
        self.body = body
        wasEdited = true
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
        let change = Change(
            record: record,
            title: title != previous.title ? title : nil,
            body: body != previous.body ? body : nil
        )
        saved = record
        if !(await save(change)), saved == record {
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
