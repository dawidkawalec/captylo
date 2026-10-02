import AppKit
import Observation
import SwiftUI

// MARK: - Toast

/// One queued toast.
struct Toast: Sendable {
    enum Kind: Sendable {
        case info
        case error
        case action(buttonTitle: String, action: @MainActor () -> Void)

        /// Name for the log. The message itself never goes to the log: calendar toasts carry
        /// the event title.
        var logName: String {
            switch self {
            case .info: return "info"
            case .error: return "error"
            case .action: return "action"
            }
        }
    }

    let message: String
    let kind: Kind
    /// Seconds on screen instead of the kind's default.
    var lifetime: TimeInterval? = nil

    static let infoDuration: TimeInterval = 3
    static let errorDuration: TimeInterval = 7
    /// Message column: widest a toast text gets before it wraps, and its font size.
    static let maxMessageWidth: CGFloat = 360
    static let messageFontSize: CGFloat = 13

    /// Definite width for the message text. The capsule is `fixedSize()`, and under it a
    /// `maxWidth` frame proposes no width, so the text stayed on one line and spilled out of the
    /// capsule. A measured width lets a short message hug its text and a long one wrap at 360 pt.
    static func messageWidth(for message: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: messageFontSize)
        let natural = (message as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(natural) + 1, maxMessageWidth)
    }

    var duration: TimeInterval {
        if let lifetime { return lifetime }
        switch kind {
        case .info: return Self.infoDuration
        case .error, .action: return Self.errorDuration
        }
    }
}

/// Observable content of the toast panel.
@MainActor
@Observable
final class ToastModel {
    var toast: Toast?
    @ObservationIgnored var onTap: () -> Void = {}
}

// MARK: - Center

/// One reusable borderless non-activating panel above the widget (gotcha 60); toasts queue so they
/// never overlap. Error toasts play `SoundCue.error`.
@MainActor
final class ToastCenter: ToastPresenting {
    private let sounds: any SoundPlaying
    private let anchor: () -> NSRect?
    private let panel: NSPanel
    private let hostingView: NSHostingView<ToastRootView>
    private let model = ToastModel()

    private var queue: [Toast] = []
    private var current: Toast?
    private var dismissTask: Task<Void, Never>?

    /// Gap between the widget top and the toast bottom.
    static let gapAboveWidget: CGFloat = VTSpacing.m

    /// - Parameter anchor: returns the widget frame in screen coordinates while it is visible.
    init(sounds: any SoundPlaying, anchor: @escaping () -> NSRect? = { nil }) {
        self.sounds = sounds
        self.anchor = anchor

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        hostingView = NSHostingView(rootView: ToastRootView(model: model))
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        model.onTap = { [weak self] in self?.dismissCurrent() }
    }

    // MARK: ToastPresenting

    func showInfo(_ message: String) {
        enqueue(Toast(message: message, kind: .info))
    }

    func showError(_ message: String) {
        sounds.play(.error)
        enqueue(Toast(message: message, kind: .error))
    }

    func showAction(message: String, buttonTitle: String, action: @escaping @MainActor () -> Void) {
        enqueue(Toast(message: message, kind: .action(buttonTitle: buttonTitle, action: action)))
    }

    func showAction(message: String, buttonTitle: String, lifetime: TimeInterval, action: @escaping @MainActor () -> Void) {
        enqueue(Toast(message: message, kind: .action(buttonTitle: buttonTitle, action: action), lifetime: lifetime))
    }

    /// Fades the visible toast out now; the next queued toast follows.
    func dismissCurrent() {
        guard current != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        fadeOutAndPresentNext()
    }

    // MARK: Queue

    private func enqueue(_ toast: Toast) {
        queue.append(toast)
        if current == nil {
            presentNext()
        }
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return }
        let toast = queue.removeFirst()
        current = toast
        model.toast = toast

        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = VTMotion.toastFadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            self?.fadeOutAndPresentNext()
        }
        Log.ui.debug("toast shown (\(toast.kind.logName, privacy: .public), \(toast.message.count, privacy: .public) chars)")
    }

    private func fadeOutAndPresentNext() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = VTMotion.toastFadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VTMotion.toastFadeOut))
            guard !Task.isCancelled, let self else { return }
            self.panel.orderOut(nil)
            self.current = nil
            self.model.toast = nil
            self.dismissTask = nil
            self.presentNext()
        }
    }

    // MARK: Placement

    /// Above the widget when it is visible, otherwise bottom center of the screen under the mouse.
    private func origin(for size: NSSize) -> NSPoint {
        if let widget = anchor() {
            return NSPoint(
                x: (widget.midX - size.width / 2).rounded(),
                y: (widget.maxY + Self.gapAboveWidget - ToastRootView.margin).rounded()
            )
        }
        let screen = RecorderPanelController.screenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + VTSpacing.xl - ToastRootView.margin).rounded()
        )
    }
}

// MARK: - View

/// Glass capsule with the message and an optional action button; tap anywhere hides it.
@MainActor
struct ToastRootView: View {
    let model: ToastModel

    /// Transparent margin around the capsule so the window shadow is not clipped.
    static let margin: CGFloat = VTSpacing.l

    var body: some View {
        Group {
            if let toast = model.toast {
                ToastCapsule(toast: toast, onTap: model.onTap)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(Self.margin)
        .environment(\.appearsActive, true)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

/// Small Dusk Glass capsule (same glass and dusk wash as the widget): a round icon badge, the
/// message in white and, for action toasts, a small glass capsule button. Errors carry a red
/// badge with a soft glow and a faint red wash.
@MainActor
private struct ToastCapsule: View {
    let toast: Toast
    let onTap: () -> Void

    static let badgeSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            badge
            Text(toast.message)
                .font(GlassFont.ui(Toast.messageFontSize, .medium))
                .foregroundStyle(GlassColor.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Toast.messageWidth(for: toast.message), alignment: .leading)
            if case .action(let title, let action) = toast.kind {
                Button {
                    action()
                    onTap()
                } label: {
                    Text(verbatim: title)
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, isAction ? 8 : 18)
        .padding(.vertical, 8)
        .fixedSize()
        .glassSurface(.panel, in: Capsule(style: .continuous), tint: tint, shadow: false)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var badge: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .background {
                Circle()
                    .fill(isError ? AnyShapeStyle(GlassColor.destructive.gradient) : AnyShapeStyle(Color.white.opacity(0.18)))
                    .shadow(color: isError ? GlassColor.destructive.opacity(0.6) : .clear, radius: 6)
            }
            .overlay { Circle().strokeBorder(GlassColor.rim(top: 0.45, bottom: 0.08), lineWidth: 1) }
            .accessibilityHidden(true)
    }

    private var isError: Bool {
        if case .error = toast.kind { return true }
        return false
    }

    private var isAction: Bool {
        if case .action = toast.kind { return true }
        return false
    }

    private var icon: String {
        switch toast.kind {
        case .info: return "info"
        case .error: return "exclamationmark"
        case .action: return "bell"
        }
    }

    private var tint: Color {
        isError ? GlassColor.destructive.opacity(0.22) : RecorderGlass<Capsule>.tint
    }
}
