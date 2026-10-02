import Foundation
import Observation

/// Questions in the "Zapytaj" tab while the AI answers them (`MeetingAsker.ask` through `ask`),
/// and the "Zapytaj wszystkie spotkania" panel's session (`LibraryAsker.ask` through
/// `askLibrary`). Owned by `AppState` like `MeetingNotesRuns`, so a question keeps its spinner
/// when the user looks at another meeting (or closes the panel) meanwhile, and `finishedCount`
/// tells the meeting views to reload (the answer, or its error, is on the row). One question at
/// a time per meeting, and one library question at a time.
@MainActor
@Observable
final class MeetingAskRuns {
    /// Library answers kept while the app runs; the oldest go first. Never stored.
    static let librarySessionLimit = 5

    /// Meeting -> the question being answered now (trimmed), shown above the spinner.
    private(set) var pending: [UUID: String] = [:]
    /// Bumped after every question, whatever its outcome.
    private(set) var finishedCount = 0
    /// The library question being answered now (trimmed), nil when none.
    private(set) var libraryPending: String?
    /// The last `librarySessionLimit` library answers, oldest first.
    private(set) var libraryAnswers: [LibraryAnswer] = []

    @ObservationIgnored private let ask: @Sendable (_ meetingID: UUID, _ question: String) async -> Void
    @ObservationIgnored private let libraryAsk: @Sendable (_ question: String) async -> LibraryAnswer?

    init(
        ask: @escaping @Sendable (_ meetingID: UUID, _ question: String) async -> Void,
        askLibrary: @escaping @Sendable (_ question: String) async -> LibraryAnswer? = { _ in nil }
    ) {
        self.ask = ask
        libraryAsk = askLibrary
    }

    func isAsking(_ meetingID: UUID) -> Bool {
        pending[meetingID] != nil
    }

    func pendingQuestion(_ meetingID: UUID) -> String? {
        pending[meetingID]
    }

    /// Starts answering. Nil for a blank question or while this meeting already has one running.
    @discardableResult
    func ask(meetingID: UUID, question: String) -> Task<Void, Never>? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pending[meetingID] == nil else { return nil }
        pending[meetingID] = trimmed
        let ask = self.ask
        return Task {
            await ask(meetingID, trimmed)
            pending[meetingID] = nil
            finishedCount += 1
        }
    }

    /// Starts answering a question about all meetings. Nil for a blank question or while one runs.
    @discardableResult
    func askLibrary(question: String) -> Task<Void, Never>? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, libraryPending == nil else { return nil }
        libraryPending = trimmed
        let ask = libraryAsk
        return Task {
            if let answer = await ask(trimmed) {
                append(answer)
            }
            libraryPending = nil
        }
    }

    /// The design preview's seeded answers (never the network).
    func seedLibrary(_ answers: [LibraryAnswer]) {
        for answer in answers {
            append(answer)
        }
    }

    private func append(_ answer: LibraryAnswer) {
        libraryAnswers.append(answer)
        if libraryAnswers.count > Self.librarySessionLimit {
            libraryAnswers.removeFirst(libraryAnswers.count - Self.librarySessionLimit)
        }
    }
}
