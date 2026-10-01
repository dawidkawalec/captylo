import Foundation
import Observation

/// "Wygeneruj ponownie" in the "Notatki AI" tab: writes a meeting's AI notes again with the
/// template the user picked (`MeetingNotesProcessor.regenerate` through `write`). Owned by
/// `AppState`, so a run that takes minutes keeps its spinner when the user looks at another
/// meeting or section meanwhile, and `finishedCount` tells the meeting views to reload.
@MainActor
@Observable
final class MeetingNotesRuns {
    /// Meetings whose notes are being written now.
    private(set) var running: Set<UUID> = []
    /// Bumped after every run, whatever its outcome (the notes or the error are on the row).
    private(set) var finishedCount = 0

    @ObservationIgnored private let write: @Sendable (_ meetingID: UUID, _ templateID: String?) async -> Void

    init(write: @escaping @Sendable (_ meetingID: UUID, _ templateID: String?) async -> Void) {
        self.write = write
    }

    func isRunning(_ meetingID: UUID) -> Bool {
        running.contains(meetingID)
    }

    /// Starts a run (nil template: picked from the title). Nil when one already runs for this
    /// meeting: a second click starts nothing.
    @discardableResult
    func regenerate(meetingID: UUID, templateID: String?) -> Task<Void, Never>? {
        guard running.insert(meetingID).inserted else { return nil }
        let write = self.write
        return Task {
            await write(meetingID, templateID)
            running.remove(meetingID)
            finishedCount += 1
        }
    }
}
