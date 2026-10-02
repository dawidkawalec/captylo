import Foundation
import SwiftData

/// Meeting reads and writes. Like the dictation methods, models never leave the actor: callers get
/// `MeetingRecord` and `MeetingSegmentRecord`. Every segment is saved the moment it is appended, so
/// a crash or quit mid-meeting keeps the transcript up to that point.
///
/// Every write that changes searchable text tells `searchIndex` after its save succeeded, in the
/// same actor step (so the index sees the changes in store order). Those calls only queue work
/// and never throw back here.
extension Database {
    // MARK: Meeting writes

    func createMeeting(_ record: MeetingRecord) throws {
        modelContext.insert(Meeting(record))
        try modelContext.save()
        searchIndex?.indexTitleNotes(record)
    }

    /// Overwrites every field of the row (title, status, notes, AI notes, speaker names...).
    func updateMeeting(_ record: MeetingRecord) throws {
        guard let row = try fetchMeeting(id: record.id) else {
            throw DatabaseError.notFound(record.id)
        }
        let titleNotesChanged = row.title != record.title || row.notes != record.notes
        row.apply(record)
        try modelContext.save()
        if titleNotesChanged {
            searchIndex?.indexTitleNotes(record)
        }
    }

    /// Reads, changes and saves one meeting in a single step on the actor. Writers of different
    /// fields at the same time (the notes editor, the recorder's stop, the AI notes, a speaker
    /// rename) never undo each other, which a `meeting(id:)` then `updateMeeting` pair can.
    /// Returns the saved record, or nil when the meeting is gone (deleted meanwhile).
    @discardableResult
    func modifyMeeting(id: UUID, _ change: @Sendable (inout MeetingRecord) -> Void) throws -> MeetingRecord? {
        guard let row = try fetchMeeting(id: id) else { return nil }
        var record = row.record
        let before = (record.title, record.notes)
        change(&record)
        row.apply(record)
        try modelContext.save()
        let saved = row.record
        if before != (saved.title, saved.notes) {
            searchIndex?.indexTitleNotes(saved)
        }
        return saved
    }

    /// Saves one transcribed utterance right away and adds its text to the meeting's search text
    /// (echo segments are kept but never searchable).
    func appendSegment(_ segment: MeetingSegmentRecord) throws {
        modelContext.insert(MeetingSegment(segment))
        if !segment.isEcho, let meeting = try fetchMeeting(id: segment.meetingID) {
            meeting.searchText += MeetingSearch.transcript([segment.text])
        }
        try modelContext.save()
        if !segment.isEcho {
            searchIndex?.indexSegments([segment])
        }
    }

    /// Overwrites the given segments by id (speaker labels after diarization, echo marks). When a
    /// text or an echo mark changes, the meeting's search text is rebuilt from its segments.
    func updateSegments(_ segments: [MeetingSegmentRecord]) throws {
        guard !segments.isEmpty else { return }
        let ids = segments.map(\.id)
        let rows = try modelContext.fetch(
            FetchDescriptor<MeetingSegment>(predicate: #Predicate { ids.contains($0.id) })
        )
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var reindex: Set<UUID> = []
        // The index holds the text, start and track (speaker labels are not in it).
        var indexed: [MeetingSegmentRecord] = []
        for row in rows {
            guard let record = byID[row.id] else { continue }
            if row.text != record.text || row.isEcho != record.isEcho {
                reindex.insert(row.meetingID)
            }
            if row.text != record.text || row.isEcho != record.isEcho || row.start != record.start
                || row.track != record.track.rawValue {
                // `apply` keeps the row's meeting id.
                var saved = record
                saved.meetingID = row.meetingID
                indexed.append(saved)
            }
            row.apply(record)
        }
        for meetingID in reindex {
            try rebuildSearchText(meetingID: meetingID)
        }
        try modelContext.save()
        searchIndex?.indexSegments(indexed)
    }

    /// The cloud transcript of one track replaces its live segments (speaker labels and AI fixes
    /// of that track go with them), in one save, and the search text follows.
    func replaceSegments(meetingID: UUID, track: MeetingTrack, with segments: [MeetingSegmentRecord]) throws {
        let raw = track.rawValue
        let old = try modelContext.fetch(FetchDescriptor<MeetingSegment>(
            predicate: #Predicate { $0.meetingID == meetingID && $0.track == raw }
        ))
        for row in old {
            modelContext.delete(row)
        }
        for segment in segments where segment.meetingID == meetingID && segment.track == track {
            modelContext.insert(MeetingSegment(segment))
        }
        try rebuildSearchText(meetingID: meetingID)
        try modelContext.save()
        queueReindex(meetingID: meetingID)
    }

    /// "Przywróć transkrypt": every line the AI fixed gets its earlier text back, and the meeting
    /// no longer names the AI model. Returns how many lines changed.
    @discardableResult
    func restoreOriginalTranscript(meetingID: UUID) throws -> Int {
        var restored = 0
        for row in try fetchSegments(meetingID: meetingID) {
            guard let original = row.originalText else { continue }
            row.text = original
            row.originalText = nil
            restored += 1
        }
        if let meeting = try fetchMeeting(id: meetingID) {
            meeting.transcriptAIModel = nil
        }
        if restored > 0 {
            try rebuildSearchText(meetingID: meetingID)
        }
        try modelContext.save()
        if restored > 0 {
            queueReindex(meetingID: meetingID)
        }
        return restored
    }

    /// Removes the meeting row and all its segments. The caller deletes the track files.
    func deleteMeeting(id: UUID) throws {
        if let row = try fetchMeeting(id: id) {
            modelContext.delete(row)
        }
        for segment in try fetchSegments(meetingID: id) {
            modelContext.delete(segment)
        }
        try modelContext.save()
        searchIndex?.removeMeeting(id)
    }

    /// Launch recovery for meetings of a run that ended (crash, quit, power loss).
    /// - "recording": becomes "interrupted" with the segments it saved, which get the echo marks
    ///   the stop never made (without headphones the other side would show twice), and a length:
    ///   the longer of `recordedLength` (the track files) and the end of the last segment.
    /// - "processing": the stop had saved the transcript, echo marks and length, only the
    ///   post-processors (speaker labels, AI notes) were cut short, so it becomes "completed"
    ///   and is returned as "resumed" (in stop order) for the recorder to finish the AI steps.
    func markInterruptedMeetings(recordedLength: @Sendable (UUID) -> Double = { _ in 0 }) throws -> MeetingRecovery {
        let recording = MeetingStatus.recording.rawValue
        let processing = MeetingStatus.processing.rawValue
        let rows = try modelContext.fetch(FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.status == recording || $0.status == processing },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        guard !rows.isEmpty else { return MeetingRecovery() }
        var recovery = MeetingRecovery()
        var echoMarked: [UUID] = []
        for row in rows {
            guard row.status == recording else {
                row.status = MeetingStatus.completed.rawValue
                recovery.resumed.append(row.id)
                continue
            }
            row.status = MeetingStatus.interrupted.rawValue
            recovery.interrupted.append(row.id)
            let segments = try fetchSegments(meetingID: row.id)
            let records = segments.map(\.record)
            let lastEnd = records.map(\.end).max() ?? 0
            row.duration = max(row.duration, lastEnd, recordedLength(row.id))
            let changes = Dictionary(EchoFilter.mark(records).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            guard !changes.isEmpty else { continue }
            for segment in segments {
                if let changed = changes[segment.id] {
                    segment.apply(changed)
                }
            }
            try rebuildSearchText(meetingID: row.id)
            echoMarked.append(row.id)
        }
        try modelContext.save()
        for id in echoMarked {
            queueReindex(meetingID: id)
        }
        return recovery
    }

    /// Audio retention: the rows no longer have track files on disk.
    func setMeetingAudioRemoved(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let rows = try modelContext.fetch(
            FetchDescriptor<Meeting>(predicate: #Predicate { ids.contains($0.id) })
        )
        for row in rows {
            row.hasAudio = false
        }
        try modelContext.save()
    }

    // MARK: Meeting reads

    func meeting(id: UUID) throws -> MeetingRecord? {
        try fetchMeeting(id: id)?.record
    }

    /// Newest first. A non-empty query matches the title, the notes or any segment that is not
    /// echo, ignoring case and Polish diacritics (`MeetingSearch.fold`), inside SQLite.
    func meetings(query: String, limit: Int) throws -> [MeetingRecord] {
        guard limit > 0 else { return [] }
        let folded = MeetingSearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
        if !folded.isEmpty {
            descriptor.predicate = #Predicate<Meeting> {
                $0.titleNotesSearchText.contains(folded) || $0.searchText.contains(folded)
            }
        }
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = Self.listProperties
        return try modelContext.fetch(descriptor).map(\.record)
    }

    /// The list never needs the search columns: a 2 h transcript stays on disk.
    private static var listProperties: [PartialKeyPath<Meeting>] {
        [
            \.id, \.createdAt, \.title, \.status, \.duration, \.appName, \.notes, \.noteLinesJSON,
            \.summary, \.summaryTemplateID, \.summaryModel, \.summaryError, \.speakerNamesJSON,
            \.hasAudio, \.interruptionsJSON, \.transcriptModel, \.transcriptAIModel, \.transcriptError,
            \.calendarEventID, \.participantsJSON,
        ]
    }

    /// The meetings of a search index result, in the order of `ids`; ids the store does not have
    /// (deleted meanwhile) are left out. Like the list, never the search columns.
    func meetings(ids: [UUID]) throws -> [MeetingRecord] {
        guard !ids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = Self.listProperties
        let byID = Dictionary(try modelContext.fetch(descriptor).map { ($0.id, $0.record) },
                              uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Sorted by `start`; at the same start the mic ("Ja") comes first.
    func segments(meetingID: UUID) throws -> [MeetingSegmentRecord] {
        try fetchSegments(meetingID: meetingID).map(\.record).sorted(by: Self.transcriptOrder)
    }

    /// The segments of search hits, from any meetings (the snippets under the list rows), in
    /// time order; ids the store does not have are left out.
    func segments(ids: [UUID]) throws -> [MeetingSegmentRecord] {
        guard !ids.isEmpty else { return [] }
        return try modelContext.fetch(FetchDescriptor<MeetingSegment>(predicate: #Predicate { ids.contains($0.id) }))
            .map(\.record)
            .sorted(by: Self.transcriptOrder)
    }

    /// Meetings created before `cutoff` that still have track files.
    func meetingsWithAudio(olderThan cutoff: Date) throws -> [UUID] {
        let rows = try modelContext.fetch(FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.hasAudio == true && $0.createdAt < cutoff }
        ))
        return rows.map(\.id)
    }

    // MARK: Search index

    /// Every meeting id, newest first (the search index rebuild).
    func meetingIDs() throws -> [UUID] {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)]
        )
        descriptor.propertiesToFetch = [\.id, \.createdAt]
        return try modelContext.fetch(descriptor).map(\.id)
    }

    /// What a full search index build holds for this store: one title row per meeting and one
    /// row per segment that is not echo. The launch check compares it with the index file.
    func searchIndexCounts() throws -> MeetingSearchIndex.Counts {
        MeetingSearchIndex.Counts(
            meetings: try modelContext.fetchCount(FetchDescriptor<Meeting>()),
            segments: try modelContext.fetchCount(FetchDescriptor<MeetingSegment>(
                predicate: #Predicate { $0.isEcho == false }
            ))
        )
    }

    /// Reads one meeting and its segments and queues them on `index` in this same actor step, so
    /// any later save queues its own index change after this one (the rebuild runs next to live
    /// writes). A meeting deleted meanwhile is removed from the index.
    func reindexMeeting(id: UUID, into index: any MeetingIndexing) throws {
        guard let meeting = try fetchMeeting(id: id)?.record else {
            index.removeMeeting(id)
            return
        }
        index.indexMeeting(meeting, segments: try fetchSegments(meetingID: id).map(\.record))
    }

    // MARK: Meeting helpers

    private static func transcriptOrder(_ a: MeetingSegmentRecord, _ b: MeetingSegmentRecord) -> Bool {
        if a.start != b.start { return a.start < b.start }
        return a.track == .me && b.track == .them
    }

    private func fetchMeeting(id: UUID) throws -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSegments(meetingID: UUID) throws -> [MeetingSegment] {
        try modelContext.fetch(FetchDescriptor<MeetingSegment>(
            predicate: #Predicate { $0.meetingID == meetingID },
            sortBy: [SortDescriptor(\.start)]
        ))
    }

    /// After a save that rewrote many segments of one meeting: queues its full row set on the
    /// search index. A failed read is logged, never thrown (the save already succeeded).
    private func queueReindex(meetingID: UUID) {
        guard let searchIndex else { return }
        do {
            try reindexMeeting(id: meetingID, into: searchIndex)
        } catch {
            Log.data.error("Search index update skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recomputes `Meeting.searchText` from the segments in time order (echo left out).
    private func rebuildSearchText(meetingID: UUID) throws {
        guard let meeting = try fetchMeeting(id: meetingID) else { return }
        let texts = try fetchSegments(meetingID: meetingID)
            .filter { !$0.isEcho }
            .map(\.text)
        meeting.searchText = MeetingSearch.transcript(texts)
    }
}
