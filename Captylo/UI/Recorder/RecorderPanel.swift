import AppKit
import Observation
import SwiftUI

// MARK: - Panel

/// Borderless, non-activating floating panel that never takes key or main status (gotcha 51).
/// No window shadow: the widget draws its own soft glows and shadows, and a window shadow
/// would outline the free-floating bars and timer of the compact state.
final class RecorderPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: RecorderMetrics.canvas),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        canHide = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .utilityWindow
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Hosting

/// Root hosted in the panel: keeps glass "active" while the app is inactive (gotcha 55).
@MainActor
struct RecorderRootView: View {
    let model: RecorderModel

    var body: some View {
        RecorderView(model: model)
            .environment(\.appearsActive, true)
            .environment(\.controlActiveState, .key)
            .ignoresSafeArea()
    }
}

/// Fixed-canvas hosting view; the first click on any control works without activating the
/// app. A tracking area that is active even while the app is inactive reports the pointer so
/// the controller can expand the widget on hover (the panel is never key).
final class RecorderHostingView: NSHostingView<RecorderRootView> {
    /// Called on every enter / move / exit inside the canvas.
    var onPointer: (@MainActor () -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: RecorderRootView) {
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?()
    }
}

// MARK: - Controller

/// Creates the widget panel once at launch, positions it at the bottom center of the screen under
/// the mouse, animates the content in / out and expands it while the pointer is over it.
/// Never activates the app.
@MainActor
final class RecorderPanelController: RecorderWidgetPresenting {
    let model: RecorderModel
    private let panel: RecorderPanel
    private let hostingView: RecorderHostingView
    private var hideTask: Task<Void, Never>?
    private var pointerTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    /// Expansion state the pending `hoverTask` will apply.
    private var hoverTarget: Bool?

    private(set) var isVisible = false

    /// Window server id of the panel (`screencapture -l`, `--design-preview`).
    var windowNumber: Int { panel.windowNumber }

    init(model: RecorderModel) {
        self.model = model
        panel = RecorderPanel()
        hostingView = RecorderHostingView(rootView: RecorderRootView(model: model))
        panel.contentView = hostingView
        hostingView.onPointer = { [weak self] in
            self?.evaluateHover()
        }
    }

    /// Screen frame of the visible widget (compact row or expanded panel), nil when hidden.
    /// `ToastCenter` anchors toasts above it.
    var widgetFrame: NSRect? {
        guard isVisible else { return nil }
        return screenRect(RecorderMetrics.visibleRect(expanded: model.isExpanded))
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil

        if let screen = Self.screenUnderMouse() {
            panel.setFrameOrigin(RecorderMetrics.canvasOrigin(in: screen.visibleFrame))
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        isVisible = true

        if Self.reduceMotion {
            model.isPresented = true
        } else {
            withAnimation(VTMotion.widgetIn) {
                model.isPresented = true
            }
        }
        startPointerWatch()
        Log.ui.debug("recorder widget shown")
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        stopPointerWatch()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = VTMotion.widgetOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VTMotion.widgetOutDuration))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.model.isPresented = false
                // The next take starts compact.
                if !self.model.isExpansionPinned {
                    self.model.isExpanded = false
                }
                self.model.isMenuOpen = false
            }
            self.hideTask = nil
            Log.ui.debug("recorder widget hidden")
        }
    }

    // MARK: Hover

    /// Polls the pointer while the widget is up. The tracking area answers at once; the poll
    /// covers what it cannot see (a pointer resting over transparent canvas pixels, which go to
    /// the window below, or a menu closing outside the panel). A screen-point check per 150 ms.
    private func startPointerWatch() {
        pointerTask?.cancel()
        pointerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RecorderMetrics.pointerPoll)
                guard !Task.isCancelled, let self else { return }
                self.evaluateHover()
            }
        }
    }

    private func stopPointerWatch() {
        pointerTask?.cancel()
        pointerTask = nil
        hoverTask?.cancel()
        hoverTask = nil
        hoverTarget = nil
    }

    /// Expands while the pointer is over the widget (after a short dwell) and collapses after a
    /// grace period once it has left. An open row menu keeps it expanded.
    private func evaluateHover() {
        guard isVisible, !model.isExpansionPinned else { return }
        let wanted = wantsExpansion()
        guard wanted != model.isExpanded else {
            hoverTask?.cancel()
            hoverTask = nil
            hoverTarget = nil
            return
        }
        guard hoverTarget != wanted else { return }
        hoverTarget = wanted
        hoverTask?.cancel()
        let delay = wanted ? RecorderMetrics.expandDelay : RecorderMetrics.collapseDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            self.hoverTarget = nil
            guard self.isVisible, self.wantsExpansion() == wanted else { return }
            self.setExpanded(wanted)
        }
    }

    private func wantsExpansion() -> Bool {
        if model.isMenuOpen { return true }
        let area = screenRect(RecorderMetrics.hoverRect(expanded: model.isExpanded))
        return NSMouseInRect(NSEvent.mouseLocation, area, false)
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.isExpanded != expanded else { return }
        withAnimation(Self.reduceMotion ? .easeInOut(duration: 0.18) : GlassMotion.spring) {
            model.isExpanded = expanded
        }
        Log.ui.debug("recorder widget \(expanded ? "expanded" : "collapsed", privacy: .public)")
    }

    // MARK: Helpers

    /// Canvas rect (origin bottom left) to screen coordinates.
    private func screenRect(_ rect: CGRect) -> NSRect {
        rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// The screen containing the mouse (gotcha 58), falling back to `NSScreen.main`.
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
