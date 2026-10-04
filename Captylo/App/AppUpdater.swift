import Foundation
import Observation
import Sparkle

/// "Sprawdź aktualizacje": a thin wrapper over Sparkle's standard updater controller.
///
/// The controller exists only for a normal launch with a configured feed and public key
/// (`AppUpdaterConfiguration.isConfigured`); the design preview and the unit-test host pass
/// `enabled: false` and get no controller at all, so they never reach the network. Even then the
/// controller is created with `startingUpdater: false`: nothing checks until `start()`, which only
/// `AppState.startServices()` calls. Sparkle shows its own (localized) windows.
@MainActor
@Observable
final class AppUpdater {
    /// A real feed and key, and allowed to run here. False keeps every control off.
    let isConfigured: Bool
    /// "1.0.0 (142)" behind "Wersja", from the running bundle.
    let versionLine: String
    private(set) var isStarted = false
    /// Sparkle refuses a second check while a session runs (KVO of `canCheckForUpdates`).
    private(set) var canCheckNow = false
    private(set) var lastCheckAt: Date?

    /// Sparkle's own setting (default from `SUEnableAutomaticChecks`), mirrored so SwiftUI sees it.
    var automaticChecks: Bool {
        didSet {
            guard let controller, controller.updater.automaticallyChecksForUpdates != automaticChecks else { return }
            controller.updater.automaticallyChecksForUpdates = automaticChecks
        }
    }

    /// True while an update session (check, download, install prompt) is running.
    var isChecking: Bool { isStarted && !canCheckNow }

    /// For tests: whether a Sparkle controller was created at all.
    var hasController: Bool { controller != nil }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let feedDelegate: FeedDelegate?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:], enabled: Bool) {
        let environment = ProcessInfo.processInfo.environment
        let configured = enabled && AppUpdaterConfiguration.isConfigured(info: bundleInfo, environment: environment)
        isConfigured = configured
        versionLine = AppUpdaterConfiguration.versionLine(info: bundleInfo)
        guard configured else {
            controller = nil
            feedDelegate = nil
            automaticChecks = false
            return
        }
        // Debug builds may point at a local appcast (`CAPTYLO_APPCAST_URL`); otherwise the
        // delegate answers nil and Sparkle reads `SUFeedURL` itself.
        let resolved = AppUpdaterConfiguration.feedURL(info: bundleInfo, environment: environment)?.absoluteString
        let plist = bundleInfo[AppUpdaterConfiguration.feedKey] as? String
        let delegate = FeedDelegate(feedURLString: resolved == plist ? nil : resolved)
        feedDelegate = delegate
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
    }

    /// Starts Sparkle's scheduler (and its first automatic check when that is on). Idempotent;
    /// does nothing without a controller.
    func start() {
        guard let controller, !isStarted else { return }
        controller.startUpdater()
        isStarted = true
        Log.app.info("Updater started")
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canCheckNow = updater.canCheckForUpdates
                self.lastCheckAt = updater.lastUpdateCheckDate
                self.automaticChecks = updater.automaticallyChecksForUpdates
            }
        }
    }

    /// "Sprawdź teraz" / "Sprawdź aktualizacje…": Sparkle's user-initiated check with its windows.
    func checkNow() {
        guard let controller, isStarted else { return }
        controller.checkForUpdates(nil)
    }
}

/// Answers Sparkle's feed question only when a debug override is set.
@MainActor
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
    let feedURLString: String?

    init(feedURLString: String?) {
        self.feedURLString = feedURLString
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLString
    }
}
