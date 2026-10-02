import Foundation
import Observation

/// The transcript actions in a meeting's details: "Transkrybuj ponownie w chmurze", "Popraw
/// przez AI" and "Przywróć transkrypt sprzed poprawek AI". Owned by `AppState` like
/// `MeetingNotesRuns`, so a run that takes minutes keeps its spinner while the user looks
/// elsewhere, and `finishedCount` tells the meeting views to reload.
@MainActor
@Observable
final class MeetingTranscriptRuns {
    enum Kind: Sendable, Equatable {
        case cloud
        case aiFix
        case restore
    }

    /// Meetings with a run now, and which.
    private(set) var running: [UUID: Kind] = [:]
    /// Bumped after every run, whatever its outcome (the result or the error is on the row).
    private(set) var finishedCount = 0

    @ObservationIgnored private let perform: @Sendable (_ meetingID: UUID, _ kind: Kind) async -> Void

    init(perform: @escaping @Sendable (_ meetingID: UUID, _ kind: Kind) async -> Void) {
        self.perform = perform
    }

    func kind(_ meetingID: UUID) -> Kind? {
        running[meetingID]
    }

    /// Nil when a run already works on this meeting: one transcript change at a time.
    @discardableResult
    func start(_ kind: Kind, meetingID: UUID) -> Task<Void, Never>? {
        guard running[meetingID] == nil else { return nil }
        running[meetingID] = kind
        let perform = self.perform
        return Task {
            await perform(meetingID, kind)
            running[meetingID] = nil
            finishedCount += 1
        }
    }
}
