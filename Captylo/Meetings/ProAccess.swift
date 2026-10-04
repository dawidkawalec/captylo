import Foundation
import Observation

/// What Captylo Pro unlocks in the notetaker.
enum ProFeature: Sendable {
    case meetingAINotes
    case speakerLabels
    case meetingAsk
    case cloudMeetingTranscription
    case meetingTranscriptCorrection
}

/// The single Pro check: the Captylo account's subscription (`AccountStore.isPro`). Debug builds
/// also accept the "Tryb Pro (dev)" switch and `CAPTYLO_DEV_PRO=1`; release builds ignore both.
@MainActor
@Observable
final class ProAccess {
    nonisolated static let environmentKey = "CAPTYLO_DEV_PRO"

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let account: AccountStore?
    @ObservationIgnored private let pinned: Bool?
    @ObservationIgnored private let environmentPro: Bool

    /// `pinned` fixes the answer (design preview, tests); `environment` is read once.
    init(
        settings: AppSettings,
        account: AccountStore?,
        pinned: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settings = settings
        self.account = account
        self.pinned = pinned
        environmentPro = environment[Self.environmentKey] == "1"
    }

    /// Observable through the account's state (and `settings.devPro` in debug builds), so views
    /// follow a sign-in, a refresh or the dev switch live.
    var isPro: Bool {
        if let pinned { return pinned }
        #if DEBUG
        if environmentPro || settings.devPro { return true }
        #endif
        return account?.isPro ?? false
    }

    /// Every Pro feature follows `isPro`; the switch is per feature so plans can split them later.
    func allows(_ feature: ProFeature) -> Bool {
        isPro
    }
}
