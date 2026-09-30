import Foundation

/// One `ZTRANSCRIPTION` row of the old store, raw: every column optional, nothing interpreted.
/// `LegacyMapper` turns it into a `DictationRecord`.
struct LegacyRow: Sendable, Equatable {
    var pk: Int64
    /// `ZID` (16-byte blob); nil when missing or malformed.
    var id: UUID?
    /// `ZTIMESTAMP`, seconds since 2001-01-01 (Core Data reference date).
    var timestamp: Double?
    /// `ZDURATION`, audio length in seconds.
    var duration: Double?
    /// `ZTRANSCRIPTIONDURATION`, seconds.
    var transcriptionDuration: Double?
    /// `ZENHANCEMENTDURATION`, seconds.
    var enhancementDuration: Double?
    var text: String?
    var enhancedText: String?
    /// `ZTRANSCRIPTIONSTATUS`: `completed`, `failed`, `pending`...
    var status: String?
    /// `ZAUDIOFILEURL`, a percent-encoded `file://` URL string.
    var audioFileURL: String?
    var transcriptionModelName: String?
    var enhancementModelName: String?
    var promptName: String?
    var powerModeName: String?

    init(
        pk: Int64,
        id: UUID? = nil,
        timestamp: Double? = nil,
        duration: Double? = nil,
        transcriptionDuration: Double? = nil,
        enhancementDuration: Double? = nil,
        text: String? = nil,
        enhancedText: String? = nil,
        status: String? = nil,
        audioFileURL: String? = nil,
        transcriptionModelName: String? = nil,
        enhancementModelName: String? = nil,
        promptName: String? = nil,
        powerModeName: String? = nil
    ) {
        self.pk = pk
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.text = text
        self.enhancedText = enhancedText
        self.status = status
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.enhancementModelName = enhancementModelName
        self.promptName = promptName
        self.powerModeName = powerModeName
    }
}

/// One `ZWORDREPLACEMENT` row: comma-separated triggers and their replacement.
struct LegacyReplacementRow: Sendable, Equatable {
    var original: String
    var replacement: String
    var isEnabled: Bool
}
