import Foundation
import Observation

/// Questions in the "Zapytaj" tab while the AI answers them (`MeetingAsker.ask` through `ask`).
/// Owned by `AppState` like `MeetingNotesRuns`, so a question keeps its spinner when the user
/// looks at another meeting meanwhile, and `finishedCount` tells the meeting views to reload
/// (the answer, or its error, is on the row). One question at a time per meeting.
@MainActor
@Observable
final class MeetingAskRuns {
    /// Meeting -> the question being answered now (trimmed), shown above the spinner.
    private(set) var pending: [UUID: String] = [:]
    /// Bumped after every question, whatever its outcome.
    private(set) var finishedCount = 0

    @ObservationIgnored private let ask: @Sendable (_ meetingID: UUID, _ question: String) async -> Void

    init(ask: @escaping @Sendable (_ meetingID: UUID, _ question: String) async -> Void) {
        self.ask = ask
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
}
