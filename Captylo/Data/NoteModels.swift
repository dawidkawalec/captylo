import Foundation
import SwiftData

/// A note: typed, dictated or recorded (audio + transcript). Every property has a default
/// (additive migration, gotcha 80).
@Model
final class Note {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Last change and the device that made it (sync, M7); stamped by `apply`.
    var updatedAt: Date = Date()
    var deviceID: String = ""
    var title: String = ""
    var body: String = ""
    var originalBody: String? = nil
    var audioFileName: String? = nil
    var audioDuration: Double = 0
    var language: String? = nil
    var transcriptModel: String? = nil
    var transcriptError: String? = nil
    var aiMode: String? = nil
    /// Folded title and body (`MeetingSearch.titleNotes`): the store's `contains` search.
    var searchText: String = ""

    init(_ record: NoteRecord) {
        id = record.id
        createdAt = record.createdAt
        apply(record)
    }

    /// Overwrites every field except `id` and `createdAt`, and stamps the change.
    func apply(_ record: NoteRecord) {
        title = record.title
        body = record.body
        originalBody = record.originalBody
        audioFileName = record.audioFileName
        audioDuration = record.audioDuration
        language = record.language
        transcriptModel = record.transcriptModel
        transcriptError = record.transcriptError
        aiMode = record.aiMode
        searchText = MeetingSearch.titleNotes(title: record.title, notes: record.body)
        updatedAt = Date()
        deviceID = DeviceIdentity.current
    }

    var record: NoteRecord {
        NoteRecord(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: title,
            body: body,
            originalBody: originalBody,
            audioFileName: audioFileName,
            audioDuration: audioDuration,
            language: language,
            transcriptModel: transcriptModel,
            transcriptError: transcriptError,
            aiMode: aiMode
        )
    }
}

enum TombstoneEntity: String, Sendable {
    case note
    case meeting
    case dictation
}

struct TombstoneRecord: Sendable, Equatable {
    var entity: TombstoneEntity
    var entityID: UUID
    var deletedAt: Date
    var deviceID: String
}

/// A deleted note, meeting or dictation, kept so sync (M7) can delete it on other devices.
/// Written in the same save as the delete; deletes themselves stay hard.
@Model
final class Tombstone {
    /// `TombstoneEntity` raw value. Never name a stored property `entity`: it collides with
    /// `NSManagedObject.entity` underneath SwiftData and crashes on the first insert.
    var kind: String = ""
    var entityID: UUID = UUID()
    var deletedAt: Date = Date()
    var deviceID: String = ""

    init(_ entity: TombstoneEntity, id: UUID) {
        kind = entity.rawValue
        entityID = id
        deletedAt = Date()
        deviceID = DeviceIdentity.current
    }

    var record: TombstoneRecord? {
        guard let entity = TombstoneEntity(rawValue: kind) else { return nil }
        return TombstoneRecord(entity: entity, entityID: entityID, deletedAt: deletedAt, deviceID: deviceID)
    }
}
