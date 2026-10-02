import Foundation

/// Open, versioned exports. The JSON is the portable format the future phone app, sync and
/// device share ("captylo.meeting.v1"): ids, tracks, segments with word times, notes, AI notes.
enum MeetingExport {
    static let formatID = "captylo.meeting.v1"

    /// Title, date and length, the user's notes, the AI notes and the transcript (echo left out).
    static func markdown(_ meeting: MeetingRecord, segments: [MeetingSegmentRecord]) -> String {
        var parts: [String] = ["# \(meeting.title)"]
        let date = meeting.createdAt.formatted(date: .long, time: .shortened)
        parts.append("\(date) · \(MeetingTime.clock(length(meeting, segments: segments)))")
        if !meeting.participants.isEmpty {
            let names = meeting.participants.joined(separator: ", ")
            parts.append(String(localized: "Uczestnicy: \(names)"))
        }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("## \(String(localized: "Moje notatki"))\n\n\(notes)")
        }
        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            parts.append("## \(String(localized: "Notatki AI"))\n\n\(demoted(summary))")
        }
        let lines = segments.filter { !$0.isEcho }.sorted { $0.start < $1.start }.map {
            "**\(MeetingTime.stamp($0.start)) \(meeting.label(for: $0)):** \($0.text)"
        }
        if !lines.isEmpty {
            parts.append("## \(String(localized: "Transkrypt"))\n\n" + lines.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Default name in the save panel: the title without the characters paths trip on ("/", ":",
    /// "\", line breaks) or leading dots (a hidden file), at most `maxNameLength` characters,
    /// "Spotkanie" when nothing is left.
    static func fileName(title: String, fileExtension: String) -> String {
        let replaced = String(title.map { $0 == "/" || $0 == ":" || $0 == "\\" || $0.isNewline ? "-" : $0 })
        var base = replaced.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if base.count > maxNameLength {
            base = String(base.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        }
        if base.isEmpty {
            base = String(localized: "Spotkanie")
        }
        return "\(base).\(fileExtension)"
    }

    static let maxNameLength = 80

    /// The meeting's length; a meeting cut short before it stored one (older interrupted rows)
    /// lasts at least until the end of its last segment.
    static func length(_ meeting: MeetingRecord, segments: [MeetingSegmentRecord]) -> Double {
        max(meeting.duration, segments.map(\.end).max() ?? 0)
    }

    /// Moves every heading one level down ("## Zadania" -> "### Zadania") so the AI notes nest
    /// under the export's own "##" heading. Fenced code and level-six headings stay as they are.
    static func demoted(_ markdown: String) -> String {
        var inFence = false
        return markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let body = line.drop { $0 == " " }
            if body.hasPrefix("```") || body.hasPrefix("~~~") {
                inFence.toggle()
                return String(line)
            }
            let level = body.prefix { $0 == "#" }.count
            guard !inFence, (1...5).contains(level), body.dropFirst(level).first == " " else {
                return String(line)
            }
            return String(line[..<body.startIndex]) + "#" + body
        }.joined(separator: "\n")
    }

    private struct Document: Encodable {
        let format: String
        let id: String
        let createdAt: Date
        let title: String
        let status: MeetingStatus
        let duration: Double
        let appName: String?
        /// The calendar event the recording was linked to, left out when there was none.
        let calendarEventID: String?
        /// Attendee names from that event (empty without one).
        let participants: [String]
        /// False once the audio was removed; `tracks` then names files that no longer exist.
        let hasAudio: Bool
        let tracks: [Track]
        /// Meeting times where capture had a gap.
        let interruptions: [Double]
        let notes: String
        let noteLines: [MeetingNoteLine]
        let speakerNames: [String: String]
        let ai: AI?
        let segments: [MeetingSegmentRecord]

        /// A recorded track and its file name inside the meeting folder.
        struct Track: Encodable {
            let id: MeetingTrack
            let file: String
        }

        struct AI: Encodable {
            let markdown: String
            let templateID: String?
            let model: String?
        }
    }

    /// The whole meeting as pretty, key-sorted JSON with ISO 8601 dates. Keeps echo segments
    /// (flagged `isEcho`) so nothing recorded is lost.
    static func json(_ meeting: MeetingRecord, segments: [MeetingSegmentRecord]) throws -> Data {
        let document = Document(
            format: formatID,
            id: meeting.id.uuidString,
            createdAt: meeting.createdAt,
            title: meeting.title,
            status: meeting.status,
            duration: length(meeting, segments: segments),
            appName: meeting.appName,
            calendarEventID: meeting.calendarEventID,
            participants: meeting.participants,
            hasAudio: meeting.hasAudio,
            tracks: MeetingTrack.allCases.map { Document.Track(id: $0, file: $0.fileName) },
            interruptions: meeting.interruptions,
            notes: meeting.notes,
            noteLines: meeting.noteLines,
            speakerNames: meeting.speakerNames,
            ai: meeting.summary.map { Document.AI(markdown: $0, templateID: meeting.summaryTemplateID, model: meeting.summaryModel) },
            segments: segments.sorted { $0.start < $1.start }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }
}
