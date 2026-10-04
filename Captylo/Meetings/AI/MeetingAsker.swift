import Foundation
import os

/// "Zapytaj" about one meeting (Pro): one non-streaming call with the whole transcript and the
/// user's notes (`MeetingAskPrompt`), on `HTTP.meetingLLMSession` with the meetings model and the
/// user's AI key, or through the Pro relay, like the AI notes. The question and its answer, or the Polish reason it failed,
/// go onto the meeting row in one `modifyMeeting` step, newest last, the newest
/// `maxStoredQuestions` kept. Never logs the question or the answer.
actor MeetingAsker {
    /// Answer cap: a short, cited answer.
    static let maxTokens = 1_500
    /// Questions kept per meeting; the oldest go first.
    static let maxStoredQuestions = 50
    /// A pasted wall of text is cut to this many characters.
    static let maxQuestionLength = 1_000
    /// Fewer words than this in the transcript and notes together (echo excluded) is nothing to ask about.
    static let minimumWords = 5

    static var recordingMessage: String {
        String(localized: "Zapytaj działa po zakończeniu spotkania.")
    }

    static var nothingToAskMessage: String {
        String(localized: "W tym spotkaniu jest za mało rozmowy, żeby odpowiedzieć.")
    }

    private let database: Database
    private let chat: MeetingChat
    private let routeProvider: @Sendable () async -> AIRoute?

    /// - Parameter route: the Pro relay, or nil (`noKey`).
    init(
        database: Database,
        session: URLSession = HTTP.meetingLLMSession,
        route: @escaping @Sendable () async -> AIRoute?
    ) {
        self.database = database
        chat = MeetingChat(session: session)
        routeProvider = route
    }

    /// Asks `question` about the meeting and stores the exchange on its row. Nil (and nothing
    /// sent or stored) for a blank question or a meeting that is not there.
    func ask(meetingID: UUID, question: String) async -> MeetingQuestion? {
        let trimmed = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQuestionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return nil }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting ask could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        var asked = MeetingQuestion(question: trimmed)
        do {
            let (answer, model) = try await answer(trimmed, meeting: meeting, segments: segments)
            asked.answer = answer
            asked.model = model
        } catch {
            Log.enhancement.error("Meeting ask failed: \(error.localizedDescription, privacy: .public)")
            asked.error = error.localizedDescription
        }

        // The call can take a while: append to the row as it is now, in one step, so edits and
        // other answers saved meanwhile survive.
        let stored = asked
        do {
            try await database.modifyMeeting(id: meetingID) { latest in
                latest.questions.append(stored)
                if latest.questions.count > Self.maxStoredQuestions {
                    latest.questions.removeFirst(latest.questions.count - Self.maxStoredQuestions)
                }
            }
        } catch {
            Log.data.error("Meeting answer could not be saved: \(error.localizedDescription, privacy: .public)")
        }
        return asked
    }

    private func answer(_ question: String, meeting: MeetingRecord, segments: [MeetingSegmentRecord]) async throws -> (String, String) {
        guard meeting.status != .recording else { throw AskError(message: Self.recordingMessage) }
        let route = try await MeetingChat.resolve(routeProvider)
        let spoken = segments.filter { !$0.isEcho }
        let words = spoken.reduce(WordCounter.count(meeting.notes)) { $0 + WordCounter.count($1.text) }
        guard words >= Self.minimumWords else { throw AskError(message: Self.nothingToAskMessage) }

        let user = MeetingAskPrompt.user(meeting: meeting, segments: spoken, question: question, history: meeting.questions)
        let started = ContinuousClock.now
        let reply = try await chat.complete(route: route, task: CaptyloAITask(kind: .meetingAsk), user: user, maxTokens: Self.maxTokens)
        if reply.finishReason == "length" {
            Log.enhancement.notice("Meeting answer reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting ask ok in \(ms) ms with \(reply.model, privacy: .public)")
        return (reply.text, reply.model)
    }

    /// A reason not to call the AI, shown as it is.
    private struct AskError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
