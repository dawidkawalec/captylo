import Foundation
import Observation
import os

/// The user's notes of the meeting on screen while they are typed: the text, each line's meeting
/// time (`NoteLines`) and a save `saveDelay` after the last keystroke. The save changes only the
/// notes fields, in one step on the database actor (`Database.modifyMeeting`), so the recorder's
/// stop and the AI notes writing the same row meanwhile keep their fields.
///
/// Owned by the details view, not by the editor: when a meeting stops mid-sentence, the live
/// layout gives way to the tabs and a new editor appears, and the text typed a moment ago must
/// still be there. A reload of the same meeting never replaces edits that are not saved yet.
@MainActor
@Observable
final class MeetingNotesDraft {
    nonisolated static let defaultSaveDelay: Duration = .seconds(1)

    private(set) var meetingID: UUID?
    private(set) var text = ""
    private(set) var lines: [MeetingNoteLine] = []

    @ObservationIgnored private let database: Database
    @ObservationIgnored private let saveDelay: Duration
    /// Bumped by every edit; `savedRevision` catches up when a save of that edit lands.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var savedRevision = 0
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(database: Database, saveDelay: Duration = MeetingNotesDraft.defaultSaveDelay) {
        self.database = database
        self.saveDelay = saveDelay
    }

    /// Typed text the database does not have yet (waiting for the delay or being written).
    var hasUnsavedEdits: Bool { revision != savedRevision }

    /// Shows the notes of `meeting`. Another meeting first saves this one's pending edits right
    /// away; the same meeting keeps edits that are not saved yet.
    func show(_ meeting: MeetingRecord) {
        if meeting.id == meetingID {
            guard !hasUnsavedEdits else { return }
        } else {
            flush()
            pendingSave = nil
            revision = 0
            savedRevision = 0
            meetingID = meeting.id
        }
        text = meeting.notes
        lines = meeting.noteLines
    }

    /// The editor's text changed; `now` is the meeting time new lines get (the recording clock,
    /// or the meeting's length once it is over).
    func edit(_ newText: String, at now: Double) {
        guard meetingID != nil, newText != text else { return }
        text = newText
        lines = NoteLines.update(lines, text: newText, now: now)
        revision += 1
        scheduleSave(after: saveDelay)
    }

    /// Saves pending edits now (another meeting shown, the section left).
    func flush() {
        guard hasUnsavedEdits else { return }
        scheduleSave(after: .zero)
    }

    /// Takes the text as it is now: a later edit cancels this save and schedules its own.
    private func scheduleSave(after delay: Duration) {
        guard let id = meetingID else { return }
        let notes = text
        let noteLines = lines
        let saving = revision
        let database = self.database
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            do {
                try await database.modifyMeeting(id: id) {
                    $0.notes = notes
                    $0.noteLines = noteLines
                }
            } catch {
                Log.data.error("Meeting notes could not be saved: \(error.localizedDescription, privacy: .public)")
            }
            self?.didSave(saving, meetingID: id)
        }
    }

    /// A failed save still counts as done: the text stays on screen and the next edit retries.
    private func didSave(_ saved: Int, meetingID id: UUID) {
        guard id == meetingID, saved > savedRevision else { return }
        savedRevision = saved
    }
}
