import Foundation
import os

/// "Zapytaj wszystkie spotkania" (Pro): finds the meetings that talk about the question in the
/// search index (`context`), sends the excerpts of the best eight to the meetings model with the
/// user's AI key (`LibraryAskPrompt`, one non-streaming call on `HTTP.meetingLLMSession`, like
/// the one-meeting ask) and returns the answer with its sources. Nothing matched: the
/// `noHitsAnswer` without an AI call. Nothing is stored. Never logs the question or the answer.
actor LibraryAsker {
    /// Answer cap: a short, cited answer.
    static let maxTokens = 1_500
    /// A pasted wall of text is cut to this many characters.
    static let maxQuestionLength = 1_000

    /// The answer when no meeting matched (the UI language; the prompt's own sentence is
    /// `LibraryAskPrompt.notFound`).
    static var noHitsAnswer: String {
        String(localized: "Nie znalazłem tego w spotkaniach.")
    }

    private let database: Database
    private let index: MeetingSearchIndex
    private let chat: MeetingChat
    private let keyProvider: @Sendable () async -> String?
    private let modelProvider: @Sendable () async -> String
    private let now: @Sendable () -> Date

    /// - Parameter reasoning: model id -> how to send `reasoning` (mandatory-reasoning models
    ///   reject `enabled: false`).
    init(
        database: Database,
        index: MeetingSearchIndex,
        client: OpenRouterClient = OpenRouterClient(),
        session: URLSession = HTTP.meetingLLMSession,
        key: @escaping @Sendable () async -> String?,
        model: @escaping @Sendable () async -> String,
        reasoning: @escaping @Sendable (String) -> ReasoningPolicy = { _ in .disabled },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.index = index
        chat = MeetingChat(client: client, session: session, reasoning: reasoning)
        keyProvider = key
        modelProvider = model
        self.now = now
    }

    /// Answers `question` from the meetings. Nil (nothing searched or sent) for a blank question.
    func ask(question: String) async -> LibraryAnswer? {
        let trimmed = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQuestionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var result = LibraryAnswer(question: trimmed, askedAt: now())
        do {
            let context = try await context(question: trimmed)
            result.notesOnly = context.notesOnly
            result.sources = context.sources.map {
                LibraryAnswer.Source(meetingID: $0.meeting.id, title: $0.meeting.title, createdAt: $0.meeting.createdAt)
            }
            guard !context.sources.isEmpty else {
                result.answer = Self.noHitsAnswer
                return result
            }
            guard let key = await keyProvider(), !key.isEmpty else { throw MeetingSummaryError.noKey }
            let model = await modelProvider()
            let user = LibraryAskPrompt.user(context: context, question: trimmed, now: now())
            let started = ContinuousClock.now
            let reply = try await chat.complete(model: model, key: key, system: LibraryAskPrompt.system, user: user, maxTokens: Self.maxTokens)
            if reply.finishReason == "length" {
                Log.enhancement.notice("Library answer reached the \(Self.maxTokens) token cap")
            }
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            Log.enhancement.info("Library ask ok in \(ms) ms with \(model, privacy: .public), \(context.sources.count) meetings")
            result.answer = reply.text
            result.model = model
        } catch {
            Log.enhancement.error("Library ask failed: \(error.localizedDescription, privacy: .public)")
            result.error = error.localizedDescription
        }
        return result
    }

    /// The meetings to answer from: the question's terms (stopwords out) matched with OR in the
    /// index, ranked per meeting (`candidateMeetings`, each with its best `segmentsPerMeeting`
    /// lines plus title and notes), the best `maxMeetings` by the sum of their hits, each with
    /// its hit lines and their neighbors. No terms or no hits: no sources. While the index is
    /// not ready (or fails): the newest meetings that have AI notes, `notesOnly`.
    func context(question: String) async throws -> LibraryAskContext {
        guard index.isReady else { return try await notesOnlyContext() }
        guard let terms = LibraryAskRetrieval.terms(question) else {
            return LibraryAskContext(sources: [], notesOnly: false)
        }
        guard let hits = await index.meetingHits(
            terms: terms, all: false,
            meetings: LibraryAskRetrieval.candidateMeetings,
            segmentsPerMeeting: LibraryAskRetrieval.segmentsPerMeeting
        ) else {
            return try await notesOnlyContext()
        }
        guard !hits.isEmpty else { return LibraryAskContext(sources: [], notesOnly: false) }

        var candidates: [UUID] = []
        for hit in hits where !candidates.contains(hit.meetingID) {
            candidates.append(hit.meetingID)
        }
        let meetings = try await database.meetings(ids: candidates)
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picked = LibraryAskRetrieval.pickMeetings(hits, dates: byID.mapValues(\.createdAt), limit: LibraryAskRetrieval.maxMeetings)

        var sources: [LibraryAskSource] = []
        for id in picked {
            guard let meeting = byID[id] else { continue }
            let own = hits.filter { $0.meetingID == id }
            let hitIDs = own
                .filter { $0.kind == .segment }
                .sorted { $0.rank < $1.rank }
                .prefix(LibraryAskRetrieval.segmentsPerMeeting)
                .compactMap(\.segmentID)
            let segments = hitIDs.isEmpty ? [] : try await database.segments(meetingID: id)
            sources.append(LibraryAskSource(
                meeting: meeting,
                excerpts: LibraryAskRetrieval.excerpts(hitSegmentIDs: Set(hitIDs), in: segments),
                includesUserNotes: own.contains { $0.kind == .notes }
            ))
        }
        return LibraryAskContext(sources: sources, notesOnly: false)
    }

    /// The newest `maxMeetings` meetings with AI notes, notes only.
    private func notesOnlyContext() async throws -> LibraryAskContext {
        let recent = try await database.meetings(query: "", limit: LibraryAskRetrieval.notesOnlyScan)
        let sources = recent
            .filter { !($0.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(LibraryAskRetrieval.maxMeetings)
            .map { LibraryAskSource(meeting: $0, excerpts: [], includesUserNotes: false) }
        return LibraryAskContext(sources: Array(sources), notesOnly: true)
    }
}
