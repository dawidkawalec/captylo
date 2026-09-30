import AppKit
import Observation

/// Finds a running predecessor (gotcha 46): the old VocaType, its VoiceInk upstream or a dev build
/// of this app from before the Captylo rename. They listen on Right Option too, so two apps would
/// record and paste twice. Onboarding and the main-window banner offer "Zamknij starą wersję".
@MainActor
@Observable
final class OldAppDetector {
    static let bundleIdentifiers: [String] = [
        "com.dawidkawalec.vocatype",
        "pl.kawalec.VocaType",
        "pl.kawalec.VocaType2",
        "com.prakashjoshipax.VoiceInk",
    ]

    private(set) var running: [NSRunningApplication] = []

    @ObservationIgnored private var observers: [ObserverToken] = []

    /// `NotificationCenter` tokens are not Sendable; the wrapper lets `deinit` remove them.
    private struct ObserverToken: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    init() {
        refresh()
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer.token)
        }
    }

    var isOldAppRunning: Bool { !running.isEmpty }

    /// Display name of the first old instance ("VocaType", "VoiceInk").
    var oldAppName: String? { running.first?.localizedName }

    /// Watches launches and terminations so the banner updates live. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
            observers.append(ObserverToken(token: token))
        }
    }

    func refresh() {
        let ownIdentifier = Bundle.main.bundleIdentifier
        running = NSWorkspace.shared.runningApplications.filter { app in
            guard let identifier = app.bundleIdentifier, identifier != ownIdentifier else { return false }
            return Self.bundleIdentifiers.contains(identifier) && !app.isTerminated
        }
    }

    /// Asks every old instance to quit (graceful terminate, no force).
    func quitOldApps() {
        for app in running {
            Log.app.notice("Asking \(app.bundleIdentifier ?? "?", privacy: .public) to quit")
            app.terminate()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refresh()
        }
    }
}
