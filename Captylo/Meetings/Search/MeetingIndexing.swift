import Foundation

/// What `Database` tells the search index after a save that changed searchable text.
/// Every call only queues the work and returns at once; the index applies the calls in the
/// order they were made and never throws back into the store path (it logs a failure instead).
protocol MeetingIndexing: Sendable {
    /// Replaces every row of the meeting: title, notes and its segments (echo left out).
    func indexMeeting(_ meeting: MeetingRecord, segments: [MeetingSegmentRecord])
    /// Upserts segments by id; an echo segment loses its row.
    func indexSegments(_ segments: [MeetingSegmentRecord])
    /// Replaces the title and notes rows of the meeting.
    func indexTitleNotes(_ meeting: MeetingRecord)
    /// Drops every row of the meeting.
    func removeMeeting(_ id: UUID)
    /// Replaces the title and body rows of the note.
    func indexNote(_ note: NoteRecord)
    /// Drops every row of the note.
    func removeNote(_ id: UUID)
}
