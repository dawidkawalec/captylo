import Foundation

/// The Spotkania list search over `MeetingSearchIndex`: queries of 3+ characters with a word of
/// 3+ letters ask the index for hits ranked per meeting (`meetingHits`, so every matching meeting
/// counts however many hits another has), order them (best rank first, then newest), read those
/// meetings and the hit segments from the store and build up to two hit lines per row.
/// Shorter queries, or an index that is not ready, keep `Database.meetings(query:limit:)`.
enum MeetingSearchResults {
    /// Hit lines under one row.
    static let segmentHitsPerMeeting = 2
    /// Shorter queries never ask the index (the trigram tokenizer needs 3 characters).
    static let minimumQueryLength = 3

    /// What the list shows for an index search.
    struct Loaded: Sendable {
        /// In result order.
        var meetings: [MeetingRecord]
        /// Hit lines per meeting; a meeting matched only by its title has none.
        var lines: [UUID: [MeetingSearchHitLine]]
    }

    /// The index terms for `query`, or nil when the list keeps the old `contains` search.
    static func indexTerms(for query: String) -> [String]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength else { return nil }
        return SearchQuery.terms(trimmed)
    }

    /// Runs the index search and reads what the rows need, at most `limit` meetings. Nil when
    /// the query is too short or the index cannot answer (not ready, a failed query): the caller
    /// uses the old search. `@concurrent`: the grouping and the snippets run off the caller's
    /// actor (the list calls it on every keystroke from the main actor).
    @concurrent
    static func load(query: String, index: MeetingSearchIndex, database: Database, limit: Int) async throws -> Loaded? {
        guard let terms = indexTerms(for: query),
              let hits = await index.meetingHits(
                  terms: terms, all: true, meetings: limit, segmentsPerMeeting: segmentHitsPerMeeting
              ) else { return nil }
        let matches = group(hits)
        let fetched = try await database.meetings(ids: matches.map(\.meetingID))
        let meetings = ordered(matches, meetings: fetched, limit: limit)
        let matchByID = Dictionary(matches.map { ($0.meetingID, $0) }, uniquingKeysWith: { first, _ in first })
        let segmentIDs = meetings.flatMap { matchByID[$0.id]?.segmentHits.compactMap(\.segmentID) ?? [] }
        let segments = try await database.segments(ids: segmentIDs)
        let segmentByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [UUID: [MeetingSearchHitLine]] = [:]
        for meeting in meetings {
            guard let match = matchByID[meeting.id] else { continue }
            let rowLines = self.lines(for: match, meeting: meeting, segments: segmentByID, terms: terms)
            if !rowLines.isEmpty {
                lines[meeting.id] = rowLines
            }
        }
        return Loaded(meetings: meetings, lines: lines)
    }

    /// One match per meeting, best rank first (ties keep the index order). Each keeps its
    /// `segmentLimit` best segment hits, in time order, and whether its title or notes matched.
    static func group(_ hits: [SearchHit], segmentLimit: Int = segmentHitsPerMeeting) -> [MeetingSearchMatch] {
        let ranked = hits.enumerated().sorted { a, b in
            a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset
        }.map(\.element)
        var order: [UUID] = []
        var matches: [UUID: MeetingSearchMatch] = [:]
        for hit in ranked {
            if matches[hit.meetingID] == nil {
                order.append(hit.meetingID)
            }
            var match = matches[hit.meetingID] ?? MeetingSearchMatch(
                meetingID: hit.meetingID, bestRank: hit.rank, segmentHits: [], titleMatched: false, notesMatched: false
            )
            switch hit.kind {
            case .title:
                match.titleMatched = true
            case .notes:
                match.notesMatched = true
            case .segment:
                if hit.segmentID != nil, match.segmentHits.count < segmentLimit {
                    match.segmentHits.append(hit)
                }
            }
            matches[hit.meetingID] = match
        }
        return order.compactMap { id in
            guard var match = matches[id] else { return nil }
            match.segmentHits.sort { $0.start < $1.start }
            return match
        }
    }

    /// The fetched meetings in result order: best rank first, then the newest. Meetings the
    /// store no longer has (deleted meanwhile) are left out; at most `limit`.
    static func ordered(_ matches: [MeetingSearchMatch], meetings: [MeetingRecord], limit: Int) -> [MeetingRecord] {
        let meetingByID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = matches.compactMap { match in meetingByID[match.meetingID].map { (match.bestRank, $0) } }
        let sorted = rows.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.createdAt != b.1.createdAt { return a.1.createdAt > b.1.createdAt }
            return a.1.id.uuidString < b.1.id.uuidString
        }
        return sorted.prefix(max(limit, 0)).map(\.1)
    }

    /// The hit lines of one row: its segment hits (speaker label and snippet), then the notes
    /// when they matched and there is room. A title hit needs no line (the row shows the title);
    /// a segment gone from the store meanwhile has none.
    static func lines(
        for match: MeetingSearchMatch, meeting: MeetingRecord, segments: [UUID: MeetingSegmentRecord], terms: [String]
    ) -> [MeetingSearchHitLine] {
        var lines = match.segmentHits.compactMap { hit -> MeetingSearchHitLine? in
            guard let id = hit.segmentID, let segment = segments[id], !segment.isEcho else { return nil }
            return MeetingSearchHitLine(
                source: .segment(id, start: segment.start),
                label: meeting.label(for: segment),
                snippet: MeetingSearchSnippet.make(segment.text, terms: terms)
            )
        }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if match.notesMatched, lines.count < segmentHitsPerMeeting, !notes.isEmpty {
            lines.append(MeetingSearchHitLine(
                source: .notes,
                label: String(localized: "Notatki"),
                snippet: MeetingSearchSnippet.make(notes, terms: terms)
            ))
        }
        return lines
    }

    /// "1 spotkanie", "3 spotkania", "5 spotkań": the Polish forms in code (like
    /// `MeetingParticipantsLabel`), one catalog key per form.
    static func countText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 spotkanie")
        }
        let last = count % 10
        let lastTwo = count % 100
        if (2...4).contains(last), !(12...14).contains(lastTwo) {
            return String(localized: "\(count) spotkania")
        }
        return String(localized: "\(count) spotkań")
    }
}
