import AppKit
import SwiftUI

/// `--design-preview <target>`: shows one screen on the fake world of `DesignPreviewData`, prints
/// `WINDOW_ID=<windowNumber>` once it is on screen (for `screencapture -l`, see `scripts/snap.sh`)
/// and runs until killed. Never starts services, never activates the app (the user may be
/// dictating into another app while it runs) and never writes the real defaults or data folder.
@MainActor
final class DesignPreviewRunner {
    static let windowIdentifier = "design-preview"
    static let mainWindowSize = NSSize(width: 1120, height: 720)
    /// `CAPTYLO_PREVIEW_SIZE=<width>x<height>` overrides the main window size (tall captures of
    /// long pages); anything unparsable keeps the default.
    static var requestedMainWindowSize: NSSize {
        let parts = (ProcessInfo.processInfo.environment["CAPTYLO_PREVIEW_SIZE"] ?? "")
            .lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return mainWindowSize }
        return NSSize(width: parts[0], height: parts[1])
    }
    static let galleryWindowSize = NSSize(width: 1040, height: 780)
    /// Widget timer lands near the mockup's 00:18 after `snap.sh` waits its 2.5 s.
    static let widgetStartElapsed: TimeInterval = 15.6

    private let appState: AppState
    private var window: NSWindow?
    private var backdrop: NSWindow?
    private var widget: (model: RecorderModel, controller: RecorderPanelController, driver: RecorderDemoDriver)?
    private var onboarding: OnboardingModel?

    init(appState: AppState) {
        self.appState = appState
    }

    func run(_ raw: String) async -> Int32 {
        guard let target = DesignPreviewTarget(rawValue: raw) else {
            let message = raw.isEmpty ? "missing target" : "unknown target \(raw)"
            print("{\"error\":\"\(message); expected one of: \(DesignPreviewTarget.listing)\"}")
            fflush(stdout)
            return 64
        }

        await DesignPreviewData.populate(appState.database)
        appState.bumpStats()
        hideSceneWindows()

        let windowNumber: Int
        switch target.kind {
        case .widget(let expanded, let state):
            windowNumber = showWidget(state: state, expanded: expanded, aiModeID: target.widgetAIModeID)
        case .onboarding(let step):
            windowNumber = showOnboarding(step)
        case .main(let section):
            appState.windowPresenter.selectedSection = section
            windowNumber = showWindow(
                size: Self.requestedMainWindowSize,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                root: MainView().environment(appState)
            )
        case .gallery:
            windowNumber = showWindow(
                size: Self.galleryWindowSize,
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                root: GlassGallery()
                    .environment(\.windowBackgroundStyle, appState.settings.windowBackground)
                    .environment(\.windowTone, appState.settings.windowTone)
            )
        }

        // One layout pass and the first frames of the entry animation before reporting (the
        // widget panel takes its place on screen only then, so the backdrop follows it).
        try? await Task.sleep(for: .milliseconds(400))
        if showBackdrop(behind: windowNumber) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if let frame = Self.captureRect(of: windowNumber) {
            print("WINDOW_FRAME=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        }
        print("WINDOW_ID=\(windowNumber)")
        fflush(stdout)
        Log.ui.info("Design preview \(target.rawValue, privacy: .public) on window \(windowNumber)")

        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    // MARK: Targets

    private func showWidget(state: WidgetDebugState, expanded: Bool, aiModeID: UUID?) -> Int {
        let made = RecorderDemo.make(
            state: state,
            startElapsed: Self.widgetStartElapsed,
            prefilledWords: expanded ? Int.max : 0
        )
        made.model.isExpanded = expanded
        made.model.isExpansionPinned = expanded
        made.model.isWaveformStill = true
        if let aiModeID {
            made.model.controls?.selectAIMode(id: aiModeID)
        }
        widget = made
        made.controller.show()
        made.driver.start()
        return made.controller.windowNumber
    }

    private func showOnboarding(_ step: OnboardingStep) -> Int {
        let settings = appState.settings
        settings.onboardingDone = false
        settings.onboardingStep = step.rawValue
        let model = OnboardingModel(appState: appState)
        model.onFinished = {}
        onboarding = model

        let window = DesignPreviewWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingPresenter.windowSize),
            styleMask: OnboardingPresenter.windowStyle,
            backing: .buffered,
            defer: false
        )
        OnboardingPresenter.configure(window, rootView: OnboardingView(model: model))
        return present(window)
    }

    private func showWindow(size: NSSize, styleMask: NSWindow.StyleMask, root: some View) -> Int {
        let window = DesignPreviewWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: root.previewActive())
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.title = "Captylo"
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        return present(window)
    }

    /// Shows `window` without activating the app; no frame autosave, so nothing is persisted.
    private func present(_ window: NSWindow) -> Int {
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.setFrameAutosaveName("")
        window.isRestorable = false
        window.orderFrontRegardless()
        self.window = window
        return window.windowNumber
    }

    // MARK: Backdrop

    /// `CAPTYLO_PREVIEW_BACKDROP=white|dark|<image path>`: a plain borderless window right behind
    /// the target, so a region capture (`screencapture -R`, `scripts/snap.sh`) shows the window
    /// glass and the widget over a known backdrop instead of whatever is on the desktop.
    @discardableResult
    private func showBackdrop(behind windowNumber: Int) -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["CAPTYLO_PREVIEW_BACKDROP"], !spec.isEmpty,
              let target = NSApplication.shared.window(withWindowNumber: windowNumber)
        else { return false }

        let frame = target.frame.insetBy(dx: -80, dy: -80)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier + "-backdrop")
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Floating, with the target above it: the region capture must not catch other apps'
        // windows that come forward while the preview settles.
        window.level = .floating
        if target.level < .floating {
            target.level = .floating
        }
        switch spec {
        case "white":
            window.backgroundColor = .white
        case "dark":
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        default:
            window.backgroundColor = .black
            if let image = NSImage(contentsOfFile: spec) {
                let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
                view.image = image
                view.imageScaling = .scaleAxesIndependently
                view.autoresizingMask = [.width, .height]
                window.contentView = view
            }
        }
        window.orderFrontRegardless()
        target.orderFrontRegardless()
        backdrop = window
        return true
    }

    /// Frame of the window on screen in `screencapture -R` coordinates (points, origin at the
    /// top left of the main display).
    private static func captureRect(of windowNumber: Int) -> CGRect? {
        guard let window = NSApplication.shared.window(withWindowNumber: windowNumber),
              let main = NSScreen.screens.first
        else { return nil }
        let frame = window.frame
        return CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// SwiftUI opens the `Window("main")` scene at launch; keep it (and only it) off screen.
    private func hideSceneWindows() {
        let hide = {
            for window in NSApplication.shared.windows
            where !(window is NSPanel) && !(window.identifier?.rawValue.hasPrefix(Self.windowIdentifier) ?? false) {
                window.orderOut(nil)
            }
        }
        hide()
        Task { @MainActor in
            for delay in [100, 400, 1000] {
                try? await Task.sleep(for: .milliseconds(delay))
                hide()
            }
        }
    }
}

private extension View {
    /// Active-window rendering (blue switches, accent selection) although the app is inactive.
    func previewActive() -> some View {
        environment(\.controlActiveState, .key)
            .environment(\.appearsActive, true)
    }
}

/// Reports itself as key and main so controls render in their active state in screenshots,
/// even though the preview never activates the app (that would steal focus from the user).
final class DesignPreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
