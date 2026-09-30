import AppKit
import ApplicationServices
import Observation

/// Tracks the Accessibility grant the event tap and the paster need (gotcha 38, 54).
/// `start()` polls `AXIsProcessTrusted()` every second and on app activation; `onGranted`
/// fires once per false -> true flip so the caller can install the tap without a relaunch.
@MainActor
@Observable
final class AccessibilityWatcher {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let pollInterval: Duration = .seconds(1)

    private(set) var isTrusted: Bool

    /// Called on the main actor when `isTrusted` flips to true.
    @ObservationIgnored var onGranted: (@MainActor () -> Void)?
    /// Called on the main actor when `isTrusted` flips to false (the system kills the event tap).
    @ObservationIgnored var onRevoked: (@MainActor () -> Void)?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: ObserverToken?

    /// `NotificationCenter` tokens are not Sendable; the wrapper lets `deinit` remove one.
    private struct ObserverToken: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    /// Fixed answer instead of `AXIsProcessTrusted()` (the design preview); nil = the real grant.
    @ObservationIgnored private let pinnedTrust: Bool?

    init(pinnedTrust: Bool? = nil) {
        self.pinnedTrust = pinnedTrust
        isTrusted = pinnedTrust ?? AXIsProcessTrusted()
    }

    deinit {
        pollTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver.token)
        }
    }

    var isRunning: Bool { pollTask != nil }

    /// Starts the 1 s poll and the `didBecomeActive` hook. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        activationObserver = ObserverToken(token: token)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver.token)
            self.activationObserver = nil
        }
    }

    /// Re-reads the grant now; fires `onGranted` / `onRevoked` on a flip.
    func refresh() {
        apply(AXIsProcessTrusted())
    }

    private func apply(_ measured: Bool) {
        let trusted = pinnedTrust ?? measured
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        Log.hotkey.info("Accessibility trusted: \(trusted)")
        if trusted {
            onGranted?()
        } else {
            onRevoked?()
        }
    }

    /// Shows the system prompt (macOS shows it once per code identity, gotcha 54) and returns the
    /// current state. Pair it with `openSystemSettings()` so the user can always reach the pane.
    @discardableResult
    func requestPrompt() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a mutable C global (not concurrency-safe in Swift 6);
        // its value is the literal "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        apply(trusted)
        return trusted
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
