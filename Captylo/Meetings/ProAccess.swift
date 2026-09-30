import Foundation
import Observation

/// What Captylo Pro unlocks in the notetaker.
enum ProFeature: Sendable {
    case meetingAINotes
    case speakerLabels
    case meetingAsk
    case cloudMeetingTranscription
}

/// The single Pro check. M1 has no accounts yet: Pro is the DEBUG "Tryb Pro (dev)" switch or
/// `CAPTYLO_DEV_PRO=1`; M4 replaces the source with the account's subscription.
@MainActor
@Observable
final class ProAccess {
    nonisolated static let environmentKey = "CAPTYLO_DEV_PRO"

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let pinned: Bool?
    @ObservationIgnored private let environmentPro: Bool

    /// `pinned` fixes the answer (design preview, tests); `environment` is read once.
    init(settings: AppSettings, pinned: Bool? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.settings = settings
        self.pinned = pinned
        environmentPro = environment[Self.environmentKey] == "1"
    }

    /// Observable through `settings.devPro`, so views follow the dev switch live.
    var isPro: Bool {
        if let pinned { return pinned }
        return environmentPro || settings.devPro
    }

    /// Every Pro feature follows `isPro` in M1; the switch is per feature so M4 can split them.
    func allows(_ feature: ProFeature) -> Bool {
        isPro
    }
}
