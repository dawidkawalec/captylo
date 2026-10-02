import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private var debugRunner: DebugRunner?

    override init() {
        if case .designPreview = DebugCommand.parse(CommandLine.arguments) {
            // Fake world only: no real defaults, store, dictionary or Keychain.
            appState = DesignPreviewData.makeAppState()
        } else if AppStateOverrides.isTestHost {
            // Unit-test host: never the real store, defaults or dictionary.
            let host = AppStateOverrides.testHost()
            appState = AppState(settings: host.settings, overrides: host.overrides)
        } else {
            appState = AppState()
        }
        super.init()
    }

    /// The menu bar item would drive the fake services of a design preview: leave it out there.
    var showsMenuBarExtra: Bool {
        !appState.isDesignPreview
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // API bodies must never land in Cache.db (gotcha 11).
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        let command = DebugCommand.parse(CommandLine.arguments)
        appState.debugCommand = command
        if let command, command.isHeadless {
            // Headless commands never show a window; the widget demo and the design preview need
            // windows but no Dock icon (and never take the focus from the app being dictated into).
            switch command {
            case .showWidget, .designPreview:
                NSApplication.shared.setActivationPolicy(.accessory)
            default:
                NSApplication.shared.setActivationPolicy(.prohibited)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let command = appState.debugCommand, command.isHeadless {
            Log.app.info("Debug command: \(String(describing: command), privacy: .public)")
            runDebugCommand(command)
            return
        }
        // As the unit-test host the app must stay inert: no hotkey tap, audio or onboarding
        // next to the Captylo the developer may be dictating with.
        if AppStateOverrides.isTestHost {
            Log.app.info("Launched as test host, services off")
            return
        }
        Log.app.info("Launched")
        appState.startServices()
        appState.windowPresenter.mainWindow()?.isReleasedWhenClosed = false
        if case .openSection(let section) = appState.debugCommand {
            appState.windowPresenter.openMain(section: section)
        } else {
            OnboardingPresenter.showIfNeeded(appState)
        }
    }

    /// Headless debug runs never open windows or take Finder files.
    private var isHeadlessRun: Bool {
        appState.debugCommand?.isHeadless == true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.permissions.refresh()
        appState.launchAtLogin.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Queued in AppState (never a second window); headless debug runs ignore them.
        guard !isHeadlessRun else { return }
        appState.openFiles(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !isHeadlessRun {
            appState.windowPresenter.openMain()
        }
        return true
    }

    // MARK: Debug commands

    private func runDebugCommand(_ command: DebugCommand) {
        let runner = DebugRunner(appState: appState)
        debugRunner = runner
        // SwiftUI opens the main window right after launch; keep it off screen for headless runs.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            for window in NSApplication.shared.windows
            where !(window is NSPanel) && window.identifier?.rawValue != DesignPreviewRunner.windowIdentifier {
                window.orderOut(nil)
            }
        }
        Task { @MainActor in
            let code = await runner.run(command)
            exit(code)
        }
    }
}
