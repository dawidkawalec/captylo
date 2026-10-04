import Foundation
import SwiftData

// Meeting rows. Every property has a default so later schema changes stay lightweight (gotcha 80).
// Segments point to their meeting by id instead of a relationship: appends stay cheap during a
// 2 h recording and deletes are explicit. Models never cross actors: use `MeetingRecord` and
// `MeetingSegmentRecord` (see `record` and `apply` below).

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    /// `MeetingStatus` raw value.
    var status: String = MeetingStatus.recording.rawValue
    var duration: Double = 0
    var appName: String? = nil
    var notes: String = ""
    /// JSON `[MeetingNoteLine]`.
    var noteLinesJSON: Data = Data()
    var summary: String? = nil
    var summaryTemplateID: String? = nil
    var summaryModel: String? = nil
    var summaryError: String? = nil
    /// JSON `[String: String]` (speaker label -> name).
    var speakerNamesJSON: Data = Data()
    var hasAudio: Bool = true
    /// JSON `[Double]` (meeting times of capture gaps).
    var interruptionsJSON: Data = Data()
    var transcriptModel: String? = nil
    var transcriptAIModel: String? = nil
    var transcriptError: String? = nil
    var calendarEventID: String? = nil
    /// JSON `[String]` (attendee names from the calendar event).
    var participantsJSON: Data = Data()
    /// JSON `[MeetingQuestion]` ("Zapytaj", Pro); empty when never asked.
    var questionsJSON: Data = Data()
    /// Folded text of every segment that is not echo (`MeetingSearch`), for search without a join.
    var searchText: String = ""
    /// Folded title and notes (`MeetingSearch.titleNotes`), kept in step by `apply`.
    var titleNotesSearchText: String = ""

    init(_ record: MeetingRecord) {
        id = record.id
        createdAt = record.createdAt
        apply(record)
    }

    /// Overwrites every field except `id`, `createdAt` and the transcript search text.
    func apply(_ record: MeetingRecord) {
        title = record.title
        status = record.status.rawValue
        duration = record.duration
        appName = record.appName
        notes = record.notes
        noteLinesJSON = Self.encode(record.noteLines)
        summary = record.summary
        summaryTemplateID = record.summaryTemplateID
        summaryModel = record.summaryModel
        summaryError = record.summaryError
        speakerNamesJSON = Self.encode(record.speakerNames)
        hasAudio = record.hasAudio
        interruptionsJSON = Self.encode(record.interruptions)
        transcriptModel = record.transcriptModel
        transcriptAIModel = record.transcriptAIModel
        transcriptError = record.transcriptError
        calendarEventID = record.calendarEventID
        participantsJSON = record.participants.isEmpty ? Data() : Self.encode(record.participants)
        questionsJSON = record.questions.isEmpty ? Data() : Self.encode(record.questions)
        titleNotesSearchText = MeetingSearch.titleNotes(title: record.title, notes: record.notes)
    }

    var record: MeetingRecord {
        MeetingRecord(
            id: id,
            createdAt: createdAt,
            title: title,
            status: MeetingStatus(rawValue: status) ?? .interrupted,
            duration: duration,
            appName: appName,
            notes: notes,
            noteLines: Self.decode([MeetingNoteLine].self, from: noteLinesJSON) ?? [],
            summary: summary,
            summaryTemplateID: summaryTemplateID,
            summaryModel: summaryModel,
            summaryError: summaryError,
            speakerNames: Self.decode([String: String].self, from: speakerNamesJSON) ?? [:],
            hasAudio: hasAudio,
            interruptions: Self.decode([Double].self, from: interruptionsJSON) ?? [],
            transcriptModel: transcriptModel,
            transcriptAIModel: transcriptAIModel,
            transcriptError: transcriptError,
            calendarEventID: calendarEventID,
            participants: Self.decode([String].self, from: participantsJSON) ?? [],
            questions: Self.decode([MeetingQuestion].self, from: questionsJSON) ?? []
        )
    }

    fileprivate static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    fileprivate static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@Model
final class MeetingSegment {
    @Attribute(.unique) var id: UUID = UUID()
    var meetingID: UUID = UUID()
    /// `MeetingTrack` raw value.
    var track: String = MeetingTrack.me.rawValue
    var start: Double = 0
    var end: Double = 0
    var text: String = ""
    /// JSON `[MeetingWord]`.
    var wordsJSON: Data = Data()
    var speaker: String? = nil
    var isEcho: Bool = false
    var originalText: String? = nil

    init(_ record: MeetingSegmentRecord) {
        id = record.id
        meetingID = record.meetingID
        apply(record)
    }

    /// Overwrites every field except `id` and `meetingID`.
    func apply(_ record: MeetingSegmentRecord) {
        track = record.track.rawValue
        start = record.start
        end = record.end
        text = record.text
        wordsJSON = Meeting.encode(record.words)
        speaker = record.speaker
        isEcho = record.isEcho
        originalText = record.originalText
    }

    var record: MeetingSegmentRecord {
        MeetingSegmentRecord(
            id: id,
            meetingID: meetingID,
            track: MeetingTrack(rawValue: track) ?? .them,
            start: start,
            end: end,
            text: text,
            words: Meeting.decode([MeetingWord].self, from: wordsJSON) ?? [],
            speaker: speaker,
            isEcho: isEcho,
            originalText: originalText
        )
    }
}
