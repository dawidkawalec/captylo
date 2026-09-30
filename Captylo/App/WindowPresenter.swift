import AppKit
import Observation
import SwiftUI

/// Opens the main window from AppKit code (menu bar, toasts, the controller) and keeps the Dock
/// policy in sync with "Ukryj ikonę w Docku" (gotchas 61, 62).
///
/// `openWindow` only exists inside SwiftUI, so every request bumps `openRequest`; an
/// `OpenWindowBridge` placed in the `MenuBarExtra` scene watches it and calls `openWindow(id:)`.
@MainActor
@Observable
final class WindowPresenter {
    /// Section the main window shows; `MainView` binds its sidebar selection to it.
    var selectedSection: MainSection = .pulpit
    /// Bumped on every open request; observed by `OpenWindowBridge`.
    private(set) var openRequest = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var closeObserver: ObserverToken?

    /// `NotificationCenter` tokens are not Sendable; the wrapper lets `deinit` remove one.
    private struct ObserverToken: @unchecked Sendable {
        let token: any NSObjectProtocol
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver.token)
        }
    }

    /// Starts watching window closes so the Dock icon can go away again. Idempotent.
    func start() {
        guard closeObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue; the object is read only inside the main-actor block.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let self, let window = object as? NSWindow, Self.isTitled(window) else { return }
                // The window is still on screen inside the notification; decide on the next turn.
                Task { @MainActor [weak self] in self?.applyDockPolicy() }
            }
        }
        closeObserver = ObserverToken(token: token)
    }

    // MARK: Opening

    /// Brings the main window forward on `section` (or the current one), creating it when needed.
    func openMain(section: MainSection? = nil) {
        if let section {
            selectedSection = section
        }
        // Policy first, then activate (gotcha 61): an accessory app cannot become frontmost.
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
        } else {
            openRequest += 1
        }
        NSApplication.shared.activate()
    }

    func openSettings() {
        openMain(section: .ustawienia)
    }

    /// The SwiftUI `Window(id: "main")` instance when it exists (deduped by identifier).
    func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { window in
            guard let identifier = window.identifier?.rawValue else { return false }
            return identifier == WindowID.main || identifier.hasPrefix(WindowID.main + "-")
        }
    }

    // MARK: Dock policy

    /// `.accessory` when the setting is on and no titled window is visible, `.regular` otherwise.
    func applyDockPolicy() {
        let app = NSApplication.shared
        let hasTitledWindow = app.windows.contains { $0.isVisible && Self.isTitled($0) }
        let wanted: NSApplication.ActivationPolicy = settings.menuBarOnly && !hasTitledWindow ? .accessory : .regular
        guard app.activationPolicy() != wanted else { return }
        app.setActivationPolicy(wanted)
        Log.ui.info("Activation policy -> \(wanted == .accessory ? "accessory" : "regular", privacy: .public)")
    }

    /// Titled `.normal`-level windows only: the recorder widget and the toast panel are excluded.
    private static func isTitled(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }
}

/// Hidden view that turns `WindowPresenter.openRequest` into `openWindow(id:)` (gotcha 62).
/// Place it inside a scene that is always alive (the `MenuBarExtra` label and content).
@MainActor
struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let presenter: WindowPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: presenter.openRequest) { _, _ in
                openWindow(id: WindowID.main)
                Task { @MainActor in
                    presenter.mainWindow()?.isReleasedWhenClosed = false
                    NSApplication.shared.activate()
                }
            }
    }
}
