import Foundation

/// A pair seen in corrections but not learned yet (needs `SelfLearning.threshold` sightings).
struct LearningCandidate: Codable, Hashable, Sendable {
    var pair: TermCorrection
    var count: Int
    var lastSeen: Date
}

/// Something Captylo learned and applies: the correct form is in the vocabulary, and either a
/// replacement rule fixes the misheard form (`ruleID`) or the pair is a hint for the AI prompt.
struct LearnedTerm: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var pair: TermCorrection
    var source: CorrectionSource
    var learnedAt: Date
    /// The replacement rule this created in the dictionary; nil = AI hint only.
    var ruleID: UUID?
    /// True when this added the correct form to the vocabulary (undo removes it again).
    var addedToVocabulary: Bool
    /// How many times the user changed the learned form back.
    var reverts: Int

    init(
        id: UUID = UUID(),
        pair: TermCorrection,
        source: CorrectionSource,
        learnedAt: Date = Date(),
        ruleID: UUID? = nil,
        addedToVocabulary: Bool,
        reverts: Int = 0
    ) {
        self.id = id
        self.pair = pair
        self.source = source
        self.learnedAt = learnedAt
        self.ruleID = ruleID
        self.addedToVocabulary = addedToVocabulary
        self.reverts = reverts
    }
}

/// A bigger edit (wording, punctuation, greeting) kept for the style profile (stage 4).
struct StyleSample: Codable, Hashable, Sendable {
    var delivered: String
    var corrected: String
    var appBundleID: String?
    var date: Date
}

/// One correction Captylo saw and what it decided (Słownik "Ostatnio zauważone"). Only the changed
/// fragment is kept, cut to `maxFragment` characters, and only on this Mac.
struct LearningObservation: Codable, Hashable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Learned as a replacement rule.
        case rule
        /// Learned as a hint for AI.
        case hint
        /// Not learned; `reason` says why.
        case skipped
    }

    static let maxFragment = 80

    var id: UUID
    var date: Date
    var appBundleID: String?
    var source: CorrectionSource
    /// What was there and what the user made of it; empty when the field could not be read.
    var before: String
    var after: String
    var outcome: Outcome
    var reason: LearningSkipReason?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        appBundleID: String?,
        source: CorrectionSource,
        before: String,
        after: String,
        outcome: Outcome,
        reason: LearningSkipReason? = nil
    ) {
        self.id = id
        self.date = date
        self.appBundleID = appBundleID
        self.source = source
        self.before = Self.fragment(before)
        self.after = Self.fragment(after)
        self.outcome = outcome
        self.reason = reason
    }

    /// One line, at most `maxFragment` characters with an ellipsis.
    static func fragment(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > maxFragment ? String(line.prefix(maxFragment - 1)) + "…" : line
    }
}

/// Words pasted into watched fields on one day and how many the user changed.
struct DailyEditStat: Codable, Hashable, Sendable {
    /// "yyyy-MM-dd" in the local calendar.
    var day: String
    var words: Int
    var changed: Int
}

/// Contents of `learning.json`. Missing keys decode to their defaults so a partial file loads.
struct LearningData: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var candidates: [LearningCandidate]
    var learned: [LearnedTerm]
    /// Pairs the user undid: never learned again.
    var blocked: [TermCorrection]
    var styleSamples: [StyleSample]
    /// Distilled style rules for every app (stage 4), editable in Słownik.
    var styleProfile: String
    /// Style rules per app bundle id (stage 4).
    var appStyles: [String: String]
    /// Style samples added since the last distillation.
    var samplesSinceDistill: Int
    /// Per-day words pasted into watched fields and words changed, newest last (60 days kept).
    var editStats: [DailyEditStat]
    /// Recent corrections and decisions, newest last (`SelfLearning.maxObservations` kept).
    var observations: [LearningObservation]

    init(
        version: Int = LearningData.currentVersion,
        candidates: [LearningCandidate] = [],
        learned: [LearnedTerm] = [],
        blocked: [TermCorrection] = [],
        styleSamples: [StyleSample] = [],
        styleProfile: String = "",
        appStyles: [String: String] = [:],
        samplesSinceDistill: Int = 0,
        editStats: [DailyEditStat] = [],
        observations: [LearningObservation] = []
    ) {
        self.version = version
        self.candidates = candidates
        self.learned = learned
        self.blocked = blocked
        self.styleSamples = styleSamples
        self.styleProfile = styleProfile
        self.appStyles = appStyles
        self.samplesSinceDistill = samplesSinceDistill
        self.editStats = editStats
        self.observations = observations
    }

    static let empty = LearningData()

    private enum CodingKeys: String, CodingKey {
        case version, candidates, learned, blocked, styleSamples, styleProfile, appStyles, samplesSinceDistill, editStats, observations
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        candidates = try c.decodeIfPresent([LearningCandidate].self, forKey: .candidates) ?? []
        learned = try c.decodeIfPresent([LearnedTerm].self, forKey: .learned) ?? []
        blocked = try c.decodeIfPresent([TermCorrection].self, forKey: .blocked) ?? []
        styleSamples = try c.decodeIfPresent([StyleSample].self, forKey: .styleSamples) ?? []
        styleProfile = try c.decodeIfPresent(String.self, forKey: .styleProfile) ?? ""
        appStyles = try c.decodeIfPresent([String: String].self, forKey: .appStyles) ?? [:]
        samplesSinceDistill = try c.decodeIfPresent(Int.self, forKey: .samplesSinceDistill) ?? 0
        editStats = try c.decodeIfPresent([DailyEditStat].self, forKey: .editStats) ?? []
        observations = try c.decodeIfPresent([LearningObservation].self, forKey: .observations) ?? []
    }
}
