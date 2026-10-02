import Foundation
import os

/// "Poprawiaj transkrypt przez AI" (Pro): the meeting's lines go to the AI in batches
/// (`MeetingCorrectionPrompt`), a few at a time, and the lines it fixed come back as changed
/// segments. A batch that fails keeps its lines; only when every batch fails does the call throw.
actor MeetingTranscriptCorrector {
    /// Batches in flight at once.
    static let parallelBatches = 3

    private let chat: MeetingChat
    private let keyProvider: @Sendable () async -> String?
    private let modelProvider: @Sendable () async -> String

    init(
        client: OpenRouterClient = OpenRouterClient(),
        session: URLSession = HTTP.meetingLLMSession,
        key: @escaping @Sendable () async -> String?,
        model: @escaping @Sendable () async -> String,
        reasoning: @escaping @Sendable (String) -> ReasoningPolicy = { _ in .disabled }
    ) {
        chat = MeetingChat(client: client, session: session, reasoning: reasoning)
        keyProvider = key
        modelProvider = model
    }

    /// The fixed segments (only those that changed) and the model that fixed them.
    func correct(meeting: MeetingRecord, segments: [MeetingSegmentRecord], glossary: [String]) async throws -> (changes: [MeetingSegmentRecord], model: String) {
        guard let key = await keyProvider(), !key.isEmpty else { throw MeetingSummaryError.noKey }
        let model = await modelProvider()
        let batches = MeetingCorrectionPrompt.batches(segments)
        guard !batches.isEmpty else { return ([], model) }
        let started = ContinuousClock.now
        let chat = self.chat
        let title = meeting.title

        var changes: [MeetingSegmentRecord] = []
        var failures: [any Error] = []
        await withTaskGroup(of: Result<[MeetingSegmentRecord], any Error>.self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    do {
                        let reply = try await chat.complete(
                            model: model,
                            key: key,
                            system: MeetingCorrectionPrompt.system,
                            user: MeetingCorrectionPrompt.user(title: title, glossary: glossary, batch: batch),
                            maxTokens: MeetingCorrectionPrompt.maxTokens(for: batch)
                        )
                        return .success(MeetingCorrectionPrompt.changes(in: batch, reply: reply.text))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for _ in 0..<Self.parallelBatches {
                addNext()
            }
            for await result in group {
                switch result {
                case .success(let fixed): changes += fixed
                case .failure(let error): failures.append(error)
                }
                addNext()
            }
        }

        if failures.count == batches.count, let first = failures.first {
            throw first
        }
        if !failures.isEmpty {
            Log.enhancement.error("Meeting transcript fix: \(failures.count, privacy: .public) of \(batches.count, privacy: .public) batches failed")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting transcript fix: \(changes.count, privacy: .public) line(s) in \(ms, privacy: .public) ms with \(model, privacy: .public)")
        return (changes, model)
    }
}

/// After a meeting (Pro and "Poprawiaj transkrypt przez AI"), and for "Popraw transkrypt przez
/// AI" in the details: stores the fixed lines (each keeps its earlier text for "Przywróć") and
/// names the model on the meeting. Runs after the cloud transcript and the speaker labels,
/// before the AI notes, so the notes read the fixed text.
struct MeetingCorrectionProcessor: MeetingPostProcessing {
    let database: Database
    let corrector: MeetingTranscriptCorrector
    let isEnabled: @Sendable () async -> Bool
    /// Dictionary terms; the speaker names typed on the meeting and the calendar's participants
    /// are added to them.
    let vocabulary: @Sendable () async -> [String]

    /// Prefix of the meeting's `transcriptError` when the AI fix failed.
    static var errorPrefix: String { String(localized: "Poprawki AI: ") }

    /// Dictionary terms, then the speaker names typed on the meeting, then the participants from
    /// the calendar event, each once: the names the AI should spell right.
    static func glossary(vocabulary: [String], meeting: MeetingRecord) -> [String] {
        var seen = Set<String>()
        return (vocabulary + meeting.speakerNames.values.sorted() + meeting.participants)
            .filter { seen.insert($0).inserted }
    }

    func process(meetingID: UUID) async {
        guard await isEnabled() else { return }
        await run(meetingID: meetingID)
    }

    @discardableResult
    func run(meetingID: UUID) async -> Bool {
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return false }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting transcript fix could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let glossary = Self.glossary(vocabulary: await vocabulary(), meeting: meeting)
        let prefix = Self.errorPrefix
        do {
            let (changes, model) = try await corrector.correct(meeting: meeting, segments: segments, glossary: glossary)
            try await database.updateSegments(changes)
            try await database.modifyMeeting(id: meetingID) { record in
                record.transcriptAIModel = model
                if record.transcriptError?.hasPrefix(prefix) == true {
                    record.transcriptError = nil
                }
            }
            return true
        } catch {
            Log.enhancement.error("Meeting transcript fix failed: \(error.localizedDescription, privacy: .public)")
            let message = prefix + error.localizedDescription
            try? await database.modifyMeeting(id: meetingID) { $0.transcriptError = message }
            return false
        }
    }
}
