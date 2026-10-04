import AppKit
import SwiftUI

/// Opens the onboarding in its own titled window (720 x 560, centered, not resizable). The
/// window has no close button: it goes away when the flow finishes or the user taps "Pomiń".
/// While it is up the SwiftUI main window stays ordered out so the first launch shows one thing.
@MainActor
enum OnboardingPresenter {
    static let windowSize = NSSize(width: 720, height: 560)
    static let windowIdentifier = "onboarding"

    private static var window: NSWindow?
    private static var model: OnboardingModel?
    private static var windowDelegate: OnboardingWindowDelegate?

    static var isShowing: Bool { window != nil }

    /// Normal GUI launch: shows the flow unless it was completed (or skipped) before.
    static func showIfNeeded(_ appState: AppState) {
        guard !appState.settings.onboardingDone else { return }
        show(appState)
    }

    /// Shows the flow, resuming the persisted step. A completed flow (re-run from Settings)
    /// starts again from the welcome step.
    static func show(_ appState: AppState) {
        activateApp()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settings = appState.settings
        if settings.onboardingDone {
            settings.onboardingStep = AppSettings.defaultOnboardingStep
            settings.onboardingDone = false
        }

        let model = OnboardingModel(appState: appState)
        model.onFinished = {
            finish(appState)
        }
        self.model = model

        let window = makeWindow(rootView: OnboardingView(model: model))
        let delegate = OnboardingWindowDelegate()
        windowDelegate = delegate
        window.delegate = delegate
        self.window = window

        hideMainWindow(appState)
        window.makeKeyAndOrderFront(nil)
        Log.ui.info("Onboarding shown at step \(model.step.rawValue, privacy: .public)")
    }

    // MARK: Window

    static let windowStyle: NSWindow.StyleMask = [.titled, .fullSizeContentView]

    private static func makeWindow(rootView: OnboardingView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: windowStyle,
            backing: .buffered,
            defer: false
        )
        configure(window, rootView: rootView)
        return window
    }

    /// Hosts the flow in `window` (created with `windowStyle`). Also used by the design preview,
    /// which shows the same window without the presenter state.
    static func configure(_ window: NSWindow, rootView: OnboardingView) {
        let hosting = NSHostingController(rootView: rootView)
        // The root view has a fixed frame; never let SwiftUI resize the window.
        hosting.sizingOptions = []

        window.title = String(localized: "Wprowadzenie")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Must stay false: with a movable background, mouse-downs on custom-styled SwiftUI
        // buttons start a window drag instead of a click, so the buttons never fire.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.contentViewController = hosting
        window.setContentSize(windowSize)
        window.center()
    }

    /// Policy first, then activate (gotcha 61): an accessory app cannot become frontmost.
    private static func activateApp() {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate()
    }

    /// SwiftUI creates the `Window("main")` shortly after launch, so retry a few times.
    private static func hideMainWindow(_ appState: AppState) {
        let presenter = appState.windowPresenter
        presenter.mainWindow()?.orderOut(nil)
        Task { @MainActor in
            for delay in [100, 400, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard isShowing else { return }
                presenter.mainWindow()?.orderOut(nil)
            }
        }
    }

    private static func finish(_ appState: AppState) {
        closeWindow()
        appState.windowPresenter.openMain(section: .pulpit)
    }

    private static func closeWindow() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        self.window = nil
        model = nil
        windowDelegate = nil
    }

    /// Called by the delegate when the window went away on its own (should not happen, defensive).
    fileprivate static func windowDidClose() {
        window = nil
        model = nil
        windowDelegate = nil
    }
}

/// Refuses close requests (Cmd+W, scripting) while the flow is running; only the presenter closes it.
@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        OnboardingPresenter.windowDidClose()
    }
}
